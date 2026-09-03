# IMS Monitoring Agent 트레이 아이콘
# 초록 = 정상 전송, 빨강 = 전송 실패, 회색 = 에이전트 중지됨, 노랑 = 확인 중
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = New-Object System.Threading.Mutex($false, "Global\IMSMonitoringAgentTray_" + $env:USERNAME)
if (-not $mutex.WaitOne(0, $false)) { exit 0 }   # 이미 떠 있으면 종료

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "IMSMonitoringAgent"
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$StatusFile = Join-Path $DataDir "status.json"
$LogFile = Join-Path $DataDir "agent.log"

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
$script:lastText = ""
function Read-Status {
  $script:taskState = Get-TaskState
  if ($script:taskState -eq 'missing') { return @{ state = 'bad'; text = "에이전트가 설치되어 있지 않습니다" } }
  if ($script:taskState -eq 'stopped') { return @{ state = 'off'; text = "에이전트 중지됨 (메뉴에서 시작)" } }
  try {
    if (-not (Test-Path $StatusFile)) { return @{ state = 'warn'; text = "에이전트 시작 중..." } }
    $st = Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $age = [int]((Get-Date) - [datetime]$st.time).TotalSeconds
    if ($age -gt ([int]$st.interval * 6 + 30)) { return @{ state = 'bad'; text = "에이전트 응답 없음 ($age 초 전이 마지막)" } }
    if ($st.ok) { return @{ state = 'ok'; text = "정상 전송 중 ($age 초 전) CPU $($st.cpu)% MEM $($st.mem_pct)%" } }
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
$mStatus.add_Click({ [System.Windows.Forms.MessageBox]::Show("호스트: $env:COMPUTERNAME`n상태: $script:lastText`n`n로그: $LogFile", "IMS Monitoring Agent") | Out-Null })
if ($dashUrl) { $mDash = $menu.Items.Add("모니터링 화면 열기"); $mDash.add_Click({ Start-Process $dashUrl }) }
$mLog = $menu.Items.Add("로그 보기")
$mLog.add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } else { [System.Windows.Forms.MessageBox]::Show("아직 로그가 없습니다.", "IMS Monitoring Agent") | Out-Null } })
$menu.Items.Add("-") | Out-Null
$mStart = $menu.Items.Add("에이전트 시작")
$mStart.add_Click({ Invoke-TaskCommand '/Run' })
$mStop = $menu.Items.Add("에이전트 종료 (전송 중지)")
$mStop.add_Click({
  $r = [System.Windows.Forms.MessageBox]::Show("에이전트를 종료하면 이 서버의 정보가 모니터링 화면에 오프라인으로 표시됩니다.`n종료할까요?", "IMS Monitoring Agent", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
  if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-TaskCommand '/End' }
})
$menu.Items.Add("-") | Out-Null
$mHide = $menu.Items.Add("트레이 아이콘 닫기 (에이전트는 계속 실행)")
$mHide.add_Click({ $ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$menu.add_Opening({
  $mStart.Enabled = ($script:taskState -eq 'stopped')
  $mStop.Enabled = ($script:taskState -eq 'running')
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
