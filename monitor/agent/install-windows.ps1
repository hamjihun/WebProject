# Windows 서버: 에이전트를 C:\monitor 에 복사하고 "작업 스케줄러"에 시스템 시작 시 실행으로 등록합니다.
# 관리자 PowerShell 에서 agent.ps1 과 같은 폴더에 두고 실행:
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\install-windows.ps1 -Url http://ims.회사도메인/monitor/api/metrics -Token 비밀값
#   .\install-windows.ps1 -Url https://... -Token 비밀값 -SkipCertCheck   # 사설 인증서일 때
# 제거:  .\install-windows.ps1 -Uninstall

param(
  [string]$Url = "",
  [int]$Interval = 5,
  [string]$Token = "",
  [switch]$SkipCertCheck,
  [switch]$Uninstall
)

$TaskName = "ServerMonitorAgent"
$Dir = "C:\monitor"

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'agent\.ps1' } | Stop-Process -Force -ErrorAction SilentlyContinue
  Write-Host "제거 완료: 작업 '$TaskName'"
  exit 0
}

if (-not $Url) { Write-Error "-Url 을 지정하세요. 예: -Url http://192.168.10.25:8787/api/metrics"; exit 1 }

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot "agent.ps1") (Join-Path $Dir "agent.ps1")

$args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\agent.ps1`" -Url `"$Url`" -Interval $Interval"
if ($Token) { $args += " -Token `"$Token`"" }
if ($SkipCertCheck) { $args += " -SkipCertCheck" }

$action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $args
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "서버 모니터 에이전트 ($Url)" | Out-Null
Start-ScheduledTask -TaskName $TaskName

Start-Sleep -Seconds 3
$st = (Get-ScheduledTask -TaskName $TaskName).State
Write-Host "설치 완료: 작업 '$TaskName' 상태 = $st"
Write-Host "전송 주소: $Url  (간격 ${Interval}초)"
Write-Host "확인: 수집기 화면에 $env:COMPUTERNAME 카드가 나타나는지 보세요."
