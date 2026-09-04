# 설치 프로그램이 호출: 에이전트를 시스템 시작 시 자동 실행(작업 스케줄러, SYSTEM)으로 등록하고
# 트레이 아이콘을 로그온 시 자동 실행(Run 키)으로 등록합니다.
param([switch]$Install, [switch]$Uninstall)

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "IMSMonitoringAgent"
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

if ($Uninstall) {
  # 수집기에 "이 서버를 목록에서 빼달라"고 알림 (실패해도 제거는 계속)
  try {
    $conf = @{}
    $confPath = Join-Path $Dir "agent.conf"
    if (Test-Path $confPath) { foreach ($line in Get-Content $confPath) { if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $conf[$matches[1].ToUpper()] = $matches[2] } } }
    if ($conf['URL']) {
      $unregUrl = $conf['URL'] -replace '/api/metrics/?$', '/api/unregister'
      if ($conf['SKIPCERT'] -eq '1') { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
      try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
      $body = @{ host = $env:COMPUTERNAME; token = $conf['TOKEN'] } | ConvertTo-Json -Compress
      Invoke-RestMethod -Uri $unregUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5 | Out-Null
      Write-Host "수집기 목록에서 제거 요청 완료: $unregUrl"
    }
  } catch { Write-Host "수집기 알림 실패 (무시): $($_.Exception.Message)" }

  foreach ($t in @($TaskName) + $LegacyTasks) {
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
  # 트레이(일반 사용자)가 표시 이름을 저장할 수 있도록 Users 그룹에 수정 권한 (S-1-5-32-545 = Users)
  try { & icacls.exe "$DataDir" /grant "*S-1-5-32-545:(OI)(CI)M" /Q | Out-Null } catch {}
  # 이전 이름/수동 설치로 등록된 것이 있으면 정리
  foreach ($t in @($TaskName) + $LegacyTasks) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
  foreach ($n in $LegacyRunNames) { Remove-ItemProperty -Path $RunKey -Name $n -ErrorAction SilentlyContinue }
  Stop-AgentProcesses

  $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\agent.ps1`""
  $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $args -WorkingDirectory $Dir
  $trigger   = New-ScheduledTaskTrigger -AtStartup
  $trigger.Delay = 'PT30S'    # 부팅 후 30초 뒤 시작 (네트워크/WMI 준비 시간)
  $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "IMS Monitoring Agent (CPU/메모리/디스크 전송)" | Out-Null
  Start-ScheduledTask -TaskName $TaskName

  Set-ItemProperty -Path $RunKey -Name $RunName -Value "wscript.exe `"$Dir\tray.vbs`""
  Write-Host "등록 완료: 작업 '$TaskName' 및 트레이 자동 실행"
  exit 0
}
Write-Host "사용법: service.ps1 -Install | -Uninstall"
