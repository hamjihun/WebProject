# IMS Monitoring Agent 트레이 아이콘
# 초록 = 정상 전송, 빨강 = 전송 실패, 회색 = 에이전트 중지됨, 노랑 = 확인 중
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = New-Object System.Threading.Mutex($false, ("Global\IMSMonitoringAgentTray_" + $env:USERNAME))   # 괄호 필수: 없으면 인수가 3개로 쪼개져 만들기 실패(예전부터 중복 실행 막기가 안 됐음)
if (-not $mutex.WaitOne(0, $false)) { exit 0 }   # 이미 떠 있으면 종료

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "IMSMonitoringAgent"
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$StatusFile = Join-Path $DataDir "status.json"
$LogFile = Join-Path $DataDir "agent.log"
$DisplayFile = Join-Path $DataDir "display.conf"

function Get-DisplayName {
  try { if (Test-Path $DisplayFile) { foreach ($l in Get-Content $DisplayFile -Encoding UTF8) { if ($l -match '^\s*NAME\s*=\s*(.*?)\s*$') { return $matches[1] } } } } catch {}
  return ""
}
function Show-NameDialog([string]$current) {
  $f = New-Object System.Windows.Forms.Form
  $f.Text = "IMS Monitoring Agent - 표시 이름"
  $f.Size = New-Object System.Drawing.Size(380, 170)
  $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
  $lb = New-Object System.Windows.Forms.Label; $lb.Text = "모니터링 화면에 표시할 이름 (예: ERP 서버, 생산 MES, 파일서버)"; $lb.AutoSize = $true; $lb.Location = New-Object System.Drawing.Point(12, 14)
  $tb = New-Object System.Windows.Forms.TextBox; $tb.Location = New-Object System.Drawing.Point(12, 40); $tb.Size = New-Object System.Drawing.Size(340, 24); $tb.Text = $current; $tb.MaxLength = 40
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = "저장"; $ok.Location = New-Object System.Drawing.Point(196, 84); $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = "취소"; $cancel.Location = New-Object System.Drawing.Point(277, 84); $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $f.Controls.AddRange(@($lb, $tb, $ok, $cancel)); $f.AcceptButton = $ok; $f.CancelButton = $cancel
  if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $tb.Text.Trim() }
  return $null
}

$dashUrl = ""
$confPath = Join-Path $Dir "agent.conf"
if (Test-Path $confPath) {
  foreach ($line in Get-Content $confPath) { if ($line -match '^\s*URL\s*=\s*(.*?)\s*$') { $dashUrl = $matches[1] -replace '/api/metrics/?$', '/' } }
}

# ---- 아이콘: app.ico 위에 오른쪽 아래 큰 상태 점 ----
$baseIcon = $null
try { $baseIcon = New-Object System.Drawing.Icon((Join-Path $Dir "app.ico"), 32, 32) } catch {}
function New-StatusIcon([System.Drawing.Color]$color) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.Clear([System.Drawing.Color]::Transparent)
  if ($baseIcon) { $g.DrawIcon($baseIcon, (New-Object System.Drawing.Rectangle 0, 0, 32, 32)) }
  else {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, 12, 12, 180, 90); $path.AddArc(20, 0, 12, 12, 270, 90); $path.AddArc(20, 20, 12, 12, 0, 90); $path.AddArc(0, 20, 12, 12, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(160, 20, 60))), $path)
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)), 6, 7, 20, 13)
  }
  $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)), 13, 13, 19, 19)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 15, 15, 15, 15)
  $g.Dispose()
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$iconOk   = New-StatusIcon ([System.Drawing.Color]::FromArgb(34, 197, 94))
$iconBad  = New-StatusIcon ([System.Drawing.Color]::FromArgb(239, 68, 68))
$iconWarn = New-StatusIcon ([System.Drawing.Color]::FromArgb(245, 158, 11))
$iconOff  = New-StatusIcon ([System.Drawing.Color]::FromArgb(156, 163, 175))

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $iconWarn
$ni.Text = "IMS Monitoring Agent: 확인 중"
$ni.Visible = $true

# ---- 상태 ----
function Get-TaskState {
  try {
    $out = & schtasks.exe /Query /TN $TaskName /FO CSV /NH 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return 'missing' }
    $row = ($out | Select-Object -Last 1) | ConvertFrom-Csv -Header TaskName, NextRun, Status
    if ($row.Status -match 'Running|실행') { return 'running' } else { return 'stopped' }
  } catch { return 'unknown' }
}
$script:taskState = 'unknown'
$script:lastGood = $null
$script:lastText = ""
function Read-Status {
  $script:taskState = Get-TaskState
  # 일반 사용자 권한으로는 SYSTEM 작업이 안 보일 수 있다 → 상태 파일이 1분 안에 갱신됐으면 실행 중으로 본다
  if ($script:taskState -eq 'missing' -or $script:taskState -eq 'unknown') {
    try { if ((Test-Path $StatusFile) -and ((Get-Date) - (Get-Item $StatusFile).LastWriteTime).TotalSeconds -lt 60) { $script:taskState = 'running' } } catch {}
  }
  if ($script:taskState -eq 'missing') {
    if (Test-Path (Join-Path $DataDir "stopped.json")) { $script:taskState = 'stopped'; return @{ state = 'off'; text = "관리자가 종료함 (메뉴에서 시작)" } }
    return @{ state = 'bad'; text = "에이전트가 실행되고 있지 않습니다 (작업을 찾을 수 없음)" }
  }
  if ($script:taskState -eq 'stopped') { return @{ state = 'off'; text = "에이전트 중지됨 (메뉴에서 시작)" } }
  try {
    if (-not (Test-Path $StatusFile)) { return @{ state = 'warn'; text = "에이전트 시작 중..." } }
    $st = $null
    for ($i = 0; $i -lt 3 -and -not ($st -and $st.time); $i++) {         # 에이전트가 쓰는 순간이면 잠깐 뒤 다시 읽기
      try { $st = Get-Content $StatusFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { $st = $null }
      if (-not ($st -and $st.time)) { Start-Sleep -Milliseconds 300 }
    }
    if (-not ($st -and $st.time)) { if ($script:lastGood) { return $script:lastGood }; return @{ state = 'warn'; text = "상태 확인 중..." } }
    $age = [int]((Get-Date) - [datetime]$st.time).TotalSeconds
    if ($st.starting -and $age -lt 180) { return @{ state = 'warn'; text = "에이전트 시작 중 ($age 초)" } }
    if ($age -gt ([int]$st.interval * 6 + 30)) { return @{ state = 'bad'; text = "에이전트 응답 없음 ($age 초 전이 마지막)" } }
    if ($st.ok) { $script:lastGood = @{ state = 'ok'; text = "정상 전송 중 ($age 초 전) CPU $($st.cpu)% MEM $($st.mem_pct)%" }; return $script:lastGood }
    return @{ state = 'bad'; text = "전송 실패: $($st.error)" }
  } catch { return @{ state = 'warn'; text = "상태 읽기 오류: $($_.Exception.Message)" } }
}
function Update-Tray {
  $s = Read-Status
  $ni.Icon = switch ($s.state) { 'ok' { $iconOk } 'bad' { $iconBad } 'off' { $iconOff } default { $iconWarn } }
  $t = "IMS Monitoring Agent: " + $s.text
  if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + "..." }
  $ni.Text = $t
  $script:lastText = $s.text
}

# 관리자 권한이 필요한 작업(schtasks /Run, /End)은 UAC 창을 띄워 실행
function Invoke-Service([string]$argStr) {        # service.ps1 을 관리자 권한으로 (UAC). 돌려줌: 종료 코드, 취소하면 -1
  try {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\service.ps1`" $argStr" -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    Start-Sleep -Milliseconds 800; Update-Tray; return $p.ExitCode
  } catch { return -1 }
}
function Show-PwDialog {                            # 종료 비밀번호 입력 창 (가린 글자). 취소하면 $null
  $f = New-Object System.Windows.Forms.Form
  $f.Text = "에이전트 종료"; $f.Size = New-Object System.Drawing.Size(380, 175); $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
  $l = New-Object System.Windows.Forms.Label; $l.Text = "보안 감시가 멈춥니다. 서버 모니터링 화면에서 정한`r`n'종료·삭제 비밀번호'를 넣으세요."; $l.SetBounds(14, 12, 350, 36); $f.Controls.Add($l)
  $t = New-Object System.Windows.Forms.TextBox; $t.UseSystemPasswordChar = $true; $t.SetBounds(14, 52, 340, 24); $f.Controls.Add($t)
  $ok = New-Object System.Windows.Forms.Button; $ok.Text = "종료"; $ok.SetBounds(196, 90, 75, 28); $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
  $cc = New-Object System.Windows.Forms.Button; $cc.Text = "취소"; $cc.SetBounds(279, 90, 75, 28); $cc.DialogResult = 'Cancel'; $f.Controls.Add($cc); $f.CancelButton = $cc
  $r = $f.ShowDialog(); $v = $t.Text; $f.Dispose()
  if ($r -eq 'OK') { return $v } else { return $null }
}
function Invoke-TaskCommand([string]$verb) {
  try {
    Start-Process -FilePath "schtasks.exe" -ArgumentList @($verb, '/TN', $TaskName) -Verb RunAs -WindowStyle Hidden -Wait
    Start-Sleep -Milliseconds 800
  } catch { }   # UAC 취소 시 무시
  Update-Tray
}

# ---- 메뉴 ----
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$mStatus = $menu.Items.Add("상태 보기")
$mStatus.add_Click({
  $nm = Get-DisplayName; if (-not $nm) { $nm = "(설정 안 함)" }
  [System.Windows.Forms.MessageBox]::Show("표시 이름: $nm`n호스트: $env:COMPUTERNAME`n상태: $script:lastText`n`n로그: $LogFile", "IMS Monitoring Agent") | Out-Null
})
$mName = $menu.Items.Add("이름 설정...")
$mName.add_Click({
  $new = Show-NameDialog (Get-DisplayName)
  if ($new -ne $null) {
    try {
      if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }
      Set-Content -Path $DisplayFile -Value "NAME=$new" -Encoding UTF8
      $ni.ShowBalloonTip(3000, "IMS Monitoring Agent", $(if ($new) { "표시 이름을 '$new' 으로 저장했습니다. 잠시 후 화면에 반영됩니다." } else { "표시 이름을 지웠습니다. 호스트명으로 표시됩니다." }), [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {
      [System.Windows.Forms.MessageBox]::Show("이름을 저장하지 못했습니다: $($_.Exception.Message)", "IMS Monitoring Agent") | Out-Null
    }
  }
})
if ($dashUrl) { $mDash = $menu.Items.Add("모니터링 화면 열기"); $mDash.add_Click({ Start-Process $dashUrl }) }
$mLog = $menu.Items.Add("로그 보기")
$mLog.add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } else { [System.Windows.Forms.MessageBox]::Show("아직 로그가 없습니다.", "IMS Monitoring Agent") | Out-Null } })
$menu.Items.Add("-") | Out-Null
$mStart = $menu.Items.Add("에이전트 시작")
$mStart.add_Click({ Invoke-Service '-Start' | Out-Null })
$mRestart = $menu.Items.Add("에이전트 재시작")
$mRestart.add_Click({ Invoke-TaskCommand '/End'; Start-Sleep -Seconds 2; Invoke-TaskCommand '/Run' })
# 종료는 '종료·삭제 비밀번호'(서버 모니터링 화면에서 관리자가 정함)를 넣어야 한다. 비밀번호 없이 끄면 감시자가 5분 안에 다시 켠다.
$mStop = $menu.Items.Add("에이전트 종료 (종료 비밀번호 필요)")
$mStop.add_Click({
  $pw = Show-PwDialog; if ($null -eq $pw) { return }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pw))
  $code = Invoke-Service "-Stop -PwB64 $b64"
  if ($code -eq 1) { [System.Windows.Forms.MessageBox]::Show("종료 비밀번호가 틀렸습니다.", "IMS Monitoring Agent", 'OK', 'Warning') | Out-Null }
  elseif ($code -eq 0) { $ni.ShowBalloonTip(3000, "IMS Monitoring Agent", "에이전트를 종료했습니다. 메뉴의 '에이전트 시작' 또는 재부팅하면 다시 켜집니다.", [System.Windows.Forms.ToolTipIcon]::Info) }
})
$menu.Items.Add("-") | Out-Null
$mHide = $menu.Items.Add("트레이 아이콘 닫기 (에이전트는 계속 실행)")
$mHide.add_Click({ $ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$menu.add_Opening({
  $mStart.Enabled = ($script:taskState -eq 'stopped')
  $mStop.Enabled = ($script:taskState -eq 'running')
  $mRestart.Enabled = ($script:taskState -ne 'missing')
})
$ni.ContextMenuStrip = $menu
$ni.add_DoubleClick({ if ($dashUrl) { Start-Process $dashUrl } })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({ Update-Tray })
$timer.Start()
Update-Tray

[System.Windows.Forms.Application]::Run()
$ni.Dispose()
