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
  $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "IMS Monitoring Agent (CPU/메모리/디스크 전송)" | Out-Null
  Start-ScheduledTask -TaskName $TaskName

  Set-ItemProperty -Path $RunKey -Name $RunName -Value "wscript.exe `"$Dir\tray.vbs`""
  Write-Host "등록 완료: 작업 '$TaskName' 및 트레이 자동 실행"
  exit 0
}
Write-Host "사용법: service.ps1 -Install | -Uninstall"
