# IMS 서버(Windows)에 수집기(server.js)를 작업 스케줄러에 등록해서 부팅 시 자동 실행합니다.
# 관리자 PowerShell 에서 monitor 폴더를 원하는 위치(예: C:\ims\monitor)에 둔 뒤 실행:
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\deploy\install-collector-windows.ps1
#   .\deploy\install-collector-windows.ps1 -Token 비밀값
#   기본은 내부 전용(127.0.0.1)이라 IMS 웹서버(IIS 등)의 /monitor/ 프록시를 통해서만 접근됩니다.
#   프록시 없이 포트를 직접 열려면 -Public 을 붙이세요 (방화벽 규칙도 함께 추가).
# 제거:  .\deploy\install-collector-windows.ps1 -Uninstall

param(
  [int]$Port = 8787,
  [string]$Token = "",
  [switch]$Public,
  [switch]$Uninstall
)
$Bind = if ($Public) { "0.0.0.0" } else { "127.0.0.1" }

$TaskName = "ServerMonitorCollector"
$Root = Split-Path -Parent $PSScriptRoot          # monitor 폴더
$Node = (Get-Command node -ErrorAction SilentlyContinue).Source

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "제거 완료: 작업 '$TaskName'"
  exit 0
}
if (-not $Node) { Write-Error "node.exe 를 찾을 수 없습니다. Node.js 를 설치한 뒤 PowerShell 을 다시 여세요."; exit 1 }

# 환경 변수는 작업 스케줄러에 직접 못 넣으므로 실행용 cmd 파일을 만듭니다.
$runner = Join-Path $Root "run-collector.cmd"
@"
@echo off
cd /d "$Root"
set PORT=$Port
set BIND=$Bind
set TOKEN=$Token
"$Node" server.js >> "$Root\collector.log" 2>&1
"@ | Set-Content -Encoding ASCII $runner

$action    = New-ScheduledTaskAction -Execute $runner
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "서버 모니터 수집기 (:$Port)" | Out-Null
Start-ScheduledTask -TaskName $TaskName

if ($Public -and -not (Get-NetFirewallRule -DisplayName "ServerMonitor" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "ServerMonitor" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
  Write-Host "방화벽 규칙 추가: TCP $Port 인바운드 허용"
}

Start-Sleep -Seconds 3
try {
  $h = Invoke-RestMethod "http://127.0.0.1:$Port/api/health" -TimeoutSec 5
  Write-Host "설치 완료: 수집기 응답 확인 (서버 $($h.servers)대 등록됨)"
} catch {
  Write-Warning "작업은 등록됐지만 아직 응답이 없습니다. 로그 확인: $Root\collector.log"
}
if ($Public) { Write-Host "화면: http://<이 서버 IP>:$Port/   로그: $Root\collector.log" }
else { Write-Host "내부 전용(127.0.0.1:$Port). IMS 웹서버에 /monitor/ 프록시를 설정하세요. 로그: $Root\collector.log" }
