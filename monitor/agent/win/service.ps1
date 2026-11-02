# 설치 프로그램이 호출: 에이전트를 시스템 시작 시 자동 실행(작업 스케줄러, SYSTEM)으로 등록하고
# 트레이 아이콘을 로그온 시 자동 실행(Run 키)으로 등록합니다.
param([switch]$Install, [switch]$Uninstall, [switch]$CheckPw, [switch]$Stop, [switch]$Start, [string]$PwB64 = '')

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "IMSMonitoringAgent"
$WatchTask = "IMSMonitoringAgentWatchdog"
$TrayTask = "IMSMonitoringAgentTray"           # 로그온해 있는 사용자 화면에 트레이를 띄우는 작업 (조용한 설치·자동 업데이트 뒤)
$LegacyTasks = @("ServerMonitorAgent")
$RunKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
$RunName = "IMSMonitoringAgentTray"
$LegacyRunNames = @("ServerMonitorAgentTray")
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"

function Stop-AgentProcesses {
  # 어느 경로에서 띄웠든 (예전 수동 설치 포함) agent.ps1 / tray.ps1 실행 중인 PowerShell 을 모두 종료
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '\\(agent|tray)\.ps1' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
}

# ---- 종료·삭제 비밀번호 ----
# 서버 모니터링 화면(⬆ 에이전트)에서 관리자가 정하면 에이전트가 해시만 unlock.json 에 받아 둔다 (PBKDF2-SHA1, 10만 번).
# 트레이의 '에이전트 종료', 제어판의 프로그램 제거가 이 비밀번호를 묻는다. 비밀번호를 정하지 않았으면 예전처럼 그냥 된다.
$UnlockFile = Join-Path $DataDir "unlock.json"
function Get-GivenPw { if ($PwB64) { try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PwB64)) } catch { return '' } }; return [string]$env:IMS_UNPW }
function Test-UnlockPw {                             # 0 = 맞음, 1 = 틀림, 2 = 비밀번호를 정하지 않음
  if (-not (Test-Path $UnlockFile)) { return 2 }
  try { $u = Get-Content $UnlockFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return 2 }
  if (-not $u.hash -or -not $u.salt) { return 2 }
  $pw = Get-GivenPw; if (-not $pw) { return 1 }
  try {
    $salt = [byte[]]@(for ($i = 0; $i -lt $u.salt.Length; $i += 2) { [Convert]::ToByte($u.salt.Substring($i, 2), 16) })
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, [int]$u.iter)
    $hex = ([BitConverter]::ToString($kdf.GetBytes(32)) -replace '-', '').ToLower()
    if ($hex -eq ([string]$u.hash).ToLower()) { return 0 }
  } catch {}
  return 1
}
function Send-AgentEvent([string]$kind) {          # 수집기에 알림 (관리자 종료 등)
  try {
    $conf = @{}; $confPath = Join-Path $Dir "agent.conf"
    if (Test-Path $confPath) { foreach ($line in Get-Content $confPath) { if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $conf[$matches[1].ToUpper()] = $matches[2] } } }
    if (-not $conf['URL']) { return }
    if ($conf['SKIPCERT'] -eq '1') { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    $u = $conf['URL'] -replace '/api/metrics/?$', '/api/agent/event'
    $body = @{ host = $env:COMPUTERNAME; token = $conf['TOKEN']; kind = $kind; by = "$env:USERDOMAIN\$env:USERNAME" } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $u -Method Post -ContentType 'application/json; charset=utf-8' -Headers @{ 'X-Token' = $conf['TOKEN'] } -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
  } catch {}
}
function Write-AgentLog($m) { try { Add-Content -Path (Join-Path $DataDir "agent.log") -Value ("{0:yyyy-MM-dd HH:mm:ss} [관리] {1}" -f (Get-Date), $m) } catch {} }

if ($CheckPw) { exit (Test-UnlockPw) }

if ($Stop) {                                         # 트레이에서 '에이전트 종료' (관리자 권한으로 실행됨)
  $r = Test-UnlockPw
  if ($r -eq 1) { Write-AgentLog "에이전트 종료 시도 — 종료 비밀번호가 틀림 ($env:USERNAME)"; exit 1 }
  try { @{ at = (Get-Date).ToString('o'); by = "$env:USERDOMAIN\$env:USERNAME" } | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $DataDir "stopped.json") -Encoding UTF8 } catch {}   # 감시자·되살리기가 다시 켜지 않게
  Send-AgentEvent 'stop'
  try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '\\agent\.ps1' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
  Write-AgentLog "관리자가 종료 비밀번호로 에이전트를 종료함 ($env:USERNAME)"
  exit 0
}
if ($Start) {                                        # 트레이에서 '에이전트 시작'
  Remove-Item (Join-Path $DataDir "stopped.json") -Force -ErrorAction SilentlyContinue
  try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { & schtasks.exe /Run /TN $TaskName | Out-Null }
  Write-AgentLog "에이전트 시작 ($env:USERNAME)"
  exit 0
}

if ($Uninstall) {
  # 제거 프로그램이 비밀번호를 확인했다(IMS_UNPW). 에이전트가 작업을 되살리지 못하게 프로세스부터 끈다
  $pwok = (Test-UnlockPw) -eq 0
  Stop-AgentProcesses
  # 수집기에 "이 서버를 목록에서 빼달라"고 알림 (실패해도 제거는 계속)
  try {
    $conf = @{}
    $confPath = Join-Path $Dir "agent.conf"
    if (Test-Path $confPath) { foreach ($line in Get-Content $confPath) { if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $conf[$matches[1].ToUpper()] = $matches[2] } } }
    if ($conf['URL']) {
      $unregUrl = $conf['URL'] -replace '/api/metrics/?$', '/api/unregister'
      if ($conf['SKIPCERT'] -eq '1') { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
      try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
      $body = @{ host = $env:COMPUTERNAME; token = $conf['TOKEN']; pwok = [bool]$pwok } | ConvertTo-Json -Compress
      Invoke-RestMethod -Uri $unregUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5 | Out-Null
      Write-Host "수집기 목록에서 제거 요청 완료: $unregUrl"
    }
  } catch { Write-Host "수집기 알림 실패 (무시): $($_.Exception.Message)" }

  try { Set-Content -Path (Join-Path $DataDir "install.marker") -Value (Get-Date).ToString('o') -Encoding UTF8 } catch {}
  foreach ($t in @($WatchTask, $TaskName, $TrayTask) + $LegacyTasks) {
    try { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue } catch {}
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
  }
  foreach ($n in @($RunName) + $LegacyRunNames) { Remove-ItemProperty -Path $RunKey -Name $n -ErrorAction SilentlyContinue }
  Stop-AgentProcesses
  Write-Host "제거 완료"
  exit 0
}

if ($Install) {
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  # 데이터 폴더는 SYSTEM·관리자만 고칠 수 있게 잠근다 (일반 사용자가 remote.conf·보안 상태를 바꿔 감시를 끄지 못하게).
  # 일반 사용자는 읽기만 (트레이가 상태를 읽음), 표시 이름 파일(display.conf)만 고칠 수 있다. S-1-5-18 SYSTEM, -32-544 Administrators, -32-545 Users
  try {
    & icacls.exe "$DataDir" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" /T /C /Q | Out-Null
    $disp = Join-Path $DataDir "display.conf"; if (-not (Test-Path $disp)) { Set-Content -Path $disp -Value "" -Encoding UTF8 }
    & icacls.exe "$disp" /grant "*S-1-5-32-545:M" /Q | Out-Null
  } catch {}
  try { Set-Content -Path (Join-Path $DataDir "install.marker") -Value (Get-Date).ToString('o') -Encoding UTF8 } catch {}   # 설치 중 작업을 지웠다 만드는 것은 보안 경고에서 뺀다
  # 이전 이름/수동 설치로 등록된 것이 있으면 정리
  foreach ($t in @($WatchTask, $TaskName, $TrayTask) + $LegacyTasks) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
  foreach ($n in $LegacyRunNames) { Remove-ItemProperty -Path $RunKey -Name $n -ErrorAction SilentlyContinue }
  Stop-AgentProcesses

  $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\agent.ps1`""
  $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $args -WorkingDirectory $Dir
  $trigger   = New-ScheduledTaskTrigger -AtStartup
  $trigger.Delay = 'PT30S'    # 부팅 후 30초 뒤 시작 (네트워크/WMI 준비 시간)
  $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "IMS Monitoring Agent (CPU/메모리/디스크 전송)" | Out-Null

  # Windows Server 2012/2012 R2 에서는 위 -ExecutionTimeLimit 0 이 무시되어 "3일 이상 실행되면 중지"가 남는 버그가 있다.
  # 작업 XML 을 직접 고쳐 실행 시간 제한을 확실히 없앤다 (PT0S = 제한 없음).
  try {
    $xml = [string](Export-ScheduledTask -TaskName $TaskName)
    if ($xml -notmatch '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>') {
      if ($xml -match '<ExecutionTimeLimit>') { $xml = $xml -replace '<ExecutionTimeLimit>[^<]*</ExecutionTimeLimit>', '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>' }
      else { $xml = $xml -replace '</Settings>', '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit></Settings>' }
      Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
      Write-Host "실행 시간 제한 해제 (XML 재등록)"
    }
  } catch { Write-Host "실행 시간 제한 확인 실패 (무시): $($_.Exception.Message)" }
  Start-ScheduledTask -TaskName $TaskName

  # 감시자: 5분마다 에이전트가 살아있는지 확인하고 죽었으면 다시 시작. XML 로 등록 (2012 포함 모든 버전에서 동일, 따옴표 문제 없음)
  try {
    $wdPath = [System.Security.SecurityElement]::Escape((Join-Path $Dir "watchdog.ps1"))
    $wdXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>IMS Monitoring Agent 감시자 (5분마다 에이전트 생존 확인, 죽었으면 재시작)</Description></RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition><Interval>PT5M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$wdPath"</Arguments></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $WatchTask -Xml $wdXml -Force | Out-Null
    Write-Host "감시자 작업 등록: $WatchTask (5분마다)"
  } catch { Write-Host "감시자 작업 등록 실패 (무시, 에이전트는 정상 등록됨): $($_.Exception.Message)" }

  Set-ItemProperty -Path $RunKey -Name $RunName -Value "wscript.exe `"$Dir\tray.vbs`""
  # 트레이 다시 띄우기: 설치 중에 사용자 트레이를 껐으므로, SYSTEM 이 설치한 경우(자동 업데이트·/S) 로그온한 사용자 화면에 다시 띄운다.
  # Users 그룹으로 등록한 작업은 로그온해 있는 사용자 세션에서 실행된다 (그룹 이름은 SID 로 찾아 한글 윈도우에서도 같음).
  try {
    $users = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([System.Security.Principal.NTAccount]).Value
    $ta = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$Dir\tray.vbs`""
    $tp = New-ScheduledTaskPrincipal -GroupId $users -RunLevel Limited
    $ts = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances Parallel
    Register-ScheduledTask -TaskName $TrayTask -Action $ta -Principal $tp -Settings $ts -Description "IMS Monitoring Agent 트레이 아이콘 띄우기 (설치·업데이트 뒤)" -Force | Out-Null
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($me -eq 'S-1-5-18') { Start-ScheduledTask -TaskName $TrayTask; Write-Host "로그온한 사용자 화면에 트레이 다시 띄움" }
  } catch { Write-Host "트레이 작업 등록 실패 (다음 로그온 때 뜸): $($_.Exception.Message)" }
  Write-Host "등록 완료: 작업 '$TaskName' 및 트레이 자동 실행"
  exit 0
}
Write-Host "사용법: service.ps1 -Install | -Uninstall"
