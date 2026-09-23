# IMS 알림 (윈도우 팝업)
# 메모 보드 알림판에 등록한 알림을 시간이 되면 바탕화면에 띄운다.
# 브라우저를 열어 두지 않아도 되고, 로그인할 때 자동으로 실행된다.
#   설치:  powershell -ExecutionPolicy Bypass -File ims-alarm.ps1 -Setup
#   제거:  powershell -ExecutionPolicy Bypass -File ims-alarm.ps1 -Remove
param(
  [string]$Server = 'http://192.168.0.9:15138',
  [switch]$Setup,
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AppName  = 'IMS 알림'
$HomeDir  = Join-Path $env:LOCALAPPDATA 'IMS-Alarm'
$ConfFile = Join-Path $HomeDir 'conf.xml'
$LogFile  = Join-Path $HomeDir 'alarm.log'
$MyPath   = $MyInvocation.MyCommand.Path
$StartUp  = Join-Path ([Environment]::GetFolderPath('Startup')) 'IMS-Alarm.vbs'

function Log([string]$m) {
  try {
    if (-not (Test-Path $HomeDir)) { New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null }
    Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m) -Encoding UTF8
    $f = Get-Item $LogFile -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 300KB) { Set-Content -Path $LogFile -Value '' -Encoding UTF8 }
  } catch { }
}

# ---------- 설정 ----------
function Save-Conf($srv, $id, $secPw) {
  if (-not (Test-Path $HomeDir)) { New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null }
  # 비밀번호는 윈도우 계정으로 암호화되어 저장된다 (다른 계정/PC 에서는 풀 수 없음)
  [pscustomobject]@{ server = $srv; id = $id; pw = $secPw } | Export-Clixml -Path $ConfFile -Force
}
function Load-Conf {
  if (-not (Test-Path $ConfFile)) { return $null }
  try { return Import-Clixml -Path $ConfFile } catch { return $null }
}
function Plain([System.Security.SecureString]$s) {
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# ---------- 서버 ----------
$script:Sess = $null
function Do-Login($conf) {
  $body = @{ id = $conf.id; pw = (Plain $conf.pw); keep = $true } | ConvertTo-Json -Compress
  $null = Invoke-RestMethod -Uri ("{0}/api/login" -f $conf.server) -Method Post -Body $body `
    -ContentType 'application/json; charset=utf-8' -SessionVariable s -TimeoutSec 15
  $script:Sess = $s
  Log "로그인: $($conf.id)"
}
function Read-Alarms($conf) {
  return Invoke-RestMethod -Uri ("{0}/api/alarms" -f $conf.server) -WebSession $script:Sess -TimeoutSec 15
}
function Get-Alarms($conf) {
  if (-not $script:Sess) { Do-Login $conf }
  try { $r = Read-Alarms $conf }
  catch { Do-Login $conf; $r = Read-Alarms $conf }          # 로그인이 풀렸으면 다시 로그인
  if (-not $r.login) { Do-Login $conf; $r = Read-Alarms $conf }
  return $r
}
function Ack-Alarm($conf, $id, $action) {
  $body = @{ id = $id; action = $action } | ConvertTo-Json -Compress
  $post = {
    $null = Invoke-RestMethod -Uri ("{0}/api/alarms" -f $conf.server) -Method Post -WebSession $script:Sess `
      -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 15
  }
  try { & $post } catch { Do-Login $conf; & $post }
}

# ---------- 설치 / 제거 ----------
function Make-Vbs($ps1) {
  # 콘솔 창이 깜빡이지 않게 wscript 로 숨겨서 실행한다
  $line = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ps1 + '""", 0, False'
  Set-Content -Path $StartUp -Value $line -Encoding Default
}
function Do-Setup {
  Write-Host ''
  Write-Host "  $AppName 설치" -ForegroundColor Cyan
  Write-Host '  ----------------------------------------'
  Write-Host '  메모 보드에 등록한 알림을 시간이 되면 바탕화면에 띄웁니다.'
  Write-Host '  브라우저를 열어 두지 않아도 되고, 로그인할 때 자동으로 실행됩니다.'
  Write-Host ''
  $srv = Read-Host "  서버 주소 (그냥 Enter = $Server)"
  if ([string]::IsNullOrWhiteSpace($srv)) { $srv = $Server }
  $srv = $srv.TrimEnd('/')
  if ($srv -notmatch '^https?://') { $srv = 'http://' + $srv }

  $ok = $false
  for ($i = 0; $i -lt 3 -and -not $ok; $i++) {
    $id = Read-Host '  아이디'
    $pw = Read-Host '  비밀번호' -AsSecureString
    $conf = [pscustomobject]@{ server = $srv; id = $id; pw = $pw }
    try { Do-Login $conf; $ok = $true }
    catch { Write-Host "  로그인 실패: $($_.Exception.Message)" -ForegroundColor Red }
  }
  if (-not $ok) { Write-Host '  설치를 멈춥니다.' -ForegroundColor Red; Read-Host '  Enter 를 누르면 닫힙니다'; return }

  if (-not (Test-Path $HomeDir)) { New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null }
  $dest = Join-Path $HomeDir 'ims-alarm.ps1'
  if ($MyPath -and ((Resolve-Path $MyPath).Path -ne $dest)) { Copy-Item -Path $MyPath -Destination $dest -Force }
  Save-Conf $srv $id $pw
  Make-Vbs $dest

  Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $StartUp + '"') -WindowStyle Hidden
  Write-Host ''
  Write-Host '  설치했습니다. 작업표시줄 오른쪽 아래(시계 옆)에 종 모양이 생깁니다.' -ForegroundColor Green
  Write-Host '  지울 때는 이 파일을 다시 받아 -Remove 로 실행하거나,'
  Write-Host "  시작프로그램 폴더의 IMS-Alarm.vbs 를 지우면 됩니다."
  Write-Host ''
  Read-Host '  Enter 를 누르면 닫힙니다'
}
function Do-Remove {
  if (Test-Path $StartUp) { Remove-Item $StartUp -Force }
  if (Test-Path $ConfFile) { Remove-Item $ConfFile -Force }
  Write-Host '  지웠습니다. 실행 중인 알림은 종 모양 아이콘에서 오른쪽 클릭 → 끝내기 로 닫아 주세요.' -ForegroundColor Green
  Read-Host '  Enter 를 누르면 닫힙니다'
}

# ---------- 팝업 ----------
$script:Busy = $false
function Show-Alarm($conf, $list) {
  $script:Busy = $true
  try {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $AppName
    $f.StartPosition = 'CenterScreen'
    $f.ClientSize = New-Object System.Drawing.Size(430, 230)
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.TopMost = $true
    $f.BackColor = [System.Drawing.Color]::White
    $f.Font = New-Object System.Drawing.Font('Malgun Gothic', 10)

    $hd = New-Object System.Windows.Forms.Label
    $hd.Text = '알림'
    $hd.Font = New-Object System.Drawing.Font('Malgun Gothic', 15, [System.Drawing.FontStyle]::Bold)
    $hd.ForeColor = [System.Drawing.Color]::FromArgb(13, 148, 136)
    $hd.Location = New-Object System.Drawing.Point(18, 14)
    $hd.AutoSize = $true
    $f.Controls.Add($hd)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.BorderStyle = 'FixedSingle'
    $tb.ScrollBars = 'Vertical'
    $tb.Location = New-Object System.Drawing.Point(18, 50)
    $tb.Size = New-Object System.Drawing.Size(394, 118)
    $tb.Font = New-Object System.Drawing.Font('Malgun Gothic', 11)
    $txt = ''
    foreach ($a in $list) {
      $when = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$a.at).LocalDateTime.ToString('M/d HH:mm')
      $txt += "[$when]  $($a.txt)`r`n`r`n"
    }
    $tb.Text = $txt.TrimEnd()
    $f.Controls.Add($tb)

    $b1 = New-Object System.Windows.Forms.Button
    $b1.Text = '10분 뒤 다시'
    $b1.Location = New-Object System.Drawing.Point(18, 182)
    $b1.Size = New-Object System.Drawing.Size(190, 34)
    $b1.Add_Click({ $f.Tag = 'snooze'; $f.Close() })
    $f.Controls.Add($b1)

    $b2 = New-Object System.Windows.Forms.Button
    $b2.Text = '확인'
    $b2.Location = New-Object System.Drawing.Point(222, 182)
    $b2.Size = New-Object System.Drawing.Size(190, 34)
    $b2.BackColor = [System.Drawing.Color]::FromArgb(13, 148, 136)
    $b2.ForeColor = [System.Drawing.Color]::White
    $b2.FlatStyle = 'Flat'
    $b2.Add_Click({ $f.Tag = 'ok'; $f.Close() })
    $f.Controls.Add($b2)
    $f.AcceptButton = $b2

    $f.Add_Shown({ $f.Activate() })
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    $null = $f.ShowDialog()
    $act = if ($f.Tag) { [string]$f.Tag } else { 'ok' }
    foreach ($a in $list) { try { Ack-Alarm $conf $a.id $act } catch { Log "확인 실패: $($_.Exception.Message)" } }
    Log "알림 $($list.Count)건 $act"
    $f.Dispose()
  } finally { $script:Busy = $false }
}

# ---------- 상주 실행 ----------
function Do-Run {
  $conf = Load-Conf
  if (-not $conf) {
    [System.Windows.Forms.MessageBox]::Show('먼저 설치(-Setup)를 해 주세요.', $AppName) | Out-Null
    return
  }
  $mx = New-Object System.Threading.Mutex($false, 'Local\IMS-Alarm-Notifier')
  if (-not $mx.WaitOne(0)) { Log '이미 실행 중'; return }

  $ni = New-Object System.Windows.Forms.NotifyIcon
  $ni.Icon = [System.Drawing.SystemIcons]::Information
  $ni.Text = "$AppName ($($conf.server))"
  $ni.Visible = $true

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $m1 = $menu.Items.Add('메모 보드 열기')
  $m1.Add_Click({ Start-Process ("{0}/memo.html" -f $conf.server) })
  $m2 = $menu.Items.Add('지금 확인')
  $m3 = $menu.Items.Add('끝내기')
  $m3.Add_Click({ $ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
  $ni.ContextMenuStrip = $menu

  $check = {
    if ($script:Busy) { return }
    try {
      $r = Get-Alarms $conf
      $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      $due = @($r.alarms | Where-Object { -not $_.done -and [int64]$_.at -le $now })
      if ($due.Count -gt 0) {
        $head = $due[0].txt
        try { $ni.ShowBalloonTip(10000, '알림', $head, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
        Show-Alarm $conf $due
      }
    } catch {
      Log "확인 오류: $($_.Exception.Message)"
      $script:Sess = $null
    }
  }
  $m2.Add_Click($check)
  $ni.Add_BalloonTipClicked($check)

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 20000
  $timer.Add_Tick($check)
  $timer.Start()
  Log '시작'
  & $check
  [System.Windows.Forms.Application]::Run()
  $timer.Stop(); $ni.Dispose(); $mx.ReleaseMutex()
  Log '끝'
}

if ($Remove) { Do-Remove }
elseif ($Setup) { Do-Setup }
else { Do-Run }
