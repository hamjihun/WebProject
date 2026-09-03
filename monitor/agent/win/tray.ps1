# 작업 표시줄 트레이 아이콘: 에이전트 실행 상태 표시 (초록 = 정상 전송, 빨강 = 실패/미실행)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = New-Object System.Threading.Mutex($false, "Global\ServerMonitorAgentTray_" + $env:USERNAME)
if (-not $mutex.WaitOne(0, $false)) { exit 0 }   # 이미 떠 있으면 종료

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $env:ProgramData "ServerMonitorAgent"
$StatusFile = Join-Path $DataDir "status.json"
$LogFile = Join-Path $DataDir "agent.log"

$dashUrl = ""
$confPath = Join-Path $Dir "agent.conf"
if (Test-Path $confPath) {
  foreach ($line in Get-Content $confPath) { if ($line -match '^\s*URL\s*=\s*(.*?)\s*$') { $dashUrl = $matches[1] -replace '/api/metrics/?$', '/' } }
}

function New-DotIcon([System.Drawing.Color]$color) {
  $bmp = New-Object System.Drawing.Bitmap 16, 16
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 40, 40))), 1, 1, 14, 14)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 3, 3, 10, 10)
  $g.Dispose()
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$iconOk = New-DotIcon ([System.Drawing.Color]::FromArgb(34, 197, 94))
$iconBad = New-DotIcon ([System.Drawing.Color]::FromArgb(239, 68, 68))
$iconWarn = New-DotIcon ([System.Drawing.Color]::FromArgb(245, 158, 11))

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $iconWarn
$ni.Text = "서버 모니터 에이전트: 확인 중"
$ni.Visible = $true

$script:lastText = ""
function Read-Status {
  try {
    if (-not (Test-Path $StatusFile)) { return @{ state = 'bad'; text = "에이전트 상태 파일 없음 (미실행?)" } }
    $st = Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $age = [int]((Get-Date) - [datetime]$st.time).TotalSeconds
    if ($age -gt ([int]$st.interval * 6 + 30)) { return @{ state = 'bad'; text = "에이전트 응답 없음 ($age 초 전이 마지막)" } }
    if ($st.ok) { return @{ state = 'ok'; text = "정상 전송 중 ($age 초 전) CPU $($st.cpu)% MEM $($st.mem_pct)%" } }
    return @{ state = 'bad'; text = "전송 실패: $($st.error)" }
  } catch { return @{ state = 'warn'; text = "상태 읽기 오류: $($_.Exception.Message)" } }
}
function Update-Tray {
  $s = Read-Status
  $ni.Icon = switch ($s.state) { 'ok' { $iconOk } 'bad' { $iconBad } default { $iconWarn } }
  $t = "서버 모니터 에이전트: " + $s.text
  if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + "..." }
  $ni.Text = $t
  $script:lastText = $s.text
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$mStatus = $menu.Items.Add("상태 보기")
$mStatus.add_Click({ [System.Windows.Forms.MessageBox]::Show("호스트: $env:COMPUTERNAME`n상태: $script:lastText`n`n로그: $LogFile", "서버 모니터 에이전트") | Out-Null })
if ($dashUrl) { $mDash = $menu.Items.Add("모니터링 화면 열기"); $mDash.add_Click({ Start-Process $dashUrl }) }
$mLog = $menu.Items.Add("로그 보기")
$mLog.add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } })
$menu.Items.Add("-") | Out-Null
$mExit = $menu.Items.Add("트레이 아이콘 닫기 (에이전트는 계속 실행)")
$mExit.add_Click({ $ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$ni.ContextMenuStrip = $menu
$ni.add_DoubleClick({ if ($dashUrl) { Start-Process $dashUrl } })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({ Update-Tray })
$timer.Start()
Update-Tray

[System.Windows.Forms.Application]::Run()
$ni.Dispose()
