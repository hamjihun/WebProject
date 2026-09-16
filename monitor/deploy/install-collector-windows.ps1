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
  [string]$BackupDir = "",          # 데이터 백업 위치를 새로 지정 (비우면 deploy\backup-target.txt 를 그대로 사용)
  [string]$BackupUser = "",         # 공유 폴더(\\...)에 백업할 때 쓸 계정 (예: ILSAN\admin 또는 .\administrator)
  [string]$BackupPass = "",         # 그 계정의 비밀번호 (작업 스케줄러가 암호화해서 보관합니다)
  [switch]$Public,
  [switch]$Uninstall
)
$Bind = if ($Public) { "0.0.0.0" } else { "127.0.0.1" }

$TaskName = "ServerMonitorCollector"
$BackupTask = "ServerMonitorBackup"
$Root = Split-Path -Parent $PSScriptRoot          # monitor 폴더
$Node = (Get-Command node -ErrorAction SilentlyContinue).Source

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $BackupTask -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "제거 완료: 작업 '$TaskName', '$BackupTask' (data 폴더와 백업본은 지우지 않았습니다)"
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

# 기존 수집기 종료: 작업 중지 + 이 폴더의 server.js 를 실행 중인 node.exe 종료 (포트를 넘겨받기 위해)
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'server\.js' } |
  ForEach-Object { Write-Host "기존 수집기 종료 (PID $($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "서버 모니터 수집기 (:$Port)" | Out-Null
Start-ScheduledTask -TaskName $TaskName

if ($Public -and -not (Get-NetFirewallRule -DisplayName "ServerMonitor" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "ServerMonitor" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
  Write-Host "방화벽 규칙 추가: TCP $Port 인바운드 허용"
}

# ---- 데이터 백업 작업 (매일 새벽 1시): data 폴더를 날짜별로, 프로그램 전체를 한 벌 복사 ----
$bkScript = Join-Path $PSScriptRoot "backup-data.cmd"
$bkList   = Join-Path $PSScriptRoot "backup-target.txt"
if (Test-Path $bkScript) {
  if ($BackupDir) { Set-Content -Path $bkList -Value $BackupDir -Encoding Default }
  $targets = if (Test-Path $bkList) { @(Get-Content $bkList -Encoding Default | Where-Object { $_ -and -not $_.StartsWith('#') }) } else { @("C:\ims\monitor-backup") }
  Unregister-ScheduledTask -TaskName $BackupTask -Confirm:$false -ErrorAction SilentlyContinue
  $ba = New-ScheduledTaskAction -Execute $bkScript
  $bt = New-ScheduledTaskTrigger -Daily -At "01:00"
  $bs = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable
  # 공유 폴더(\\...)가 있으면 SYSTEM 계정으로는 접근이 안 되므로 지정한 계정으로 등록한다
  $needsUser = @($targets | Where-Object { $_.StartsWith('\\') }).Count -gt 0
  if ($BackupUser -and $BackupPass) {
    Register-ScheduledTask -TaskName $BackupTask -Action $ba -Trigger $bt -Settings $bs -User $BackupUser -Password $BackupPass -RunLevel Highest -Description "서버 모니터 데이터 백업 (매일 01:00)" | Out-Null
    Write-Host "데이터 백업 작업 등록: 매일 01:00, 실행 계정 $BackupUser"
  } else {
    Register-ScheduledTask -TaskName $BackupTask -Action $ba -Trigger $bt -Settings $bs -Principal $principal -Description "서버 모니터 데이터 백업 (매일 01:00)" | Out-Null
    Write-Host "데이터 백업 작업 등록: 매일 01:00 (SYSTEM 계정)"
    if ($needsUser) {
      Write-Warning "백업 위치에 공유 폴더가 있습니다. SYSTEM 계정은 공유 폴더에 접근하지 못합니다."
      Write-Warning "  -> 설치 명령에 -BackupUser ""계정"" -BackupPass ""비밀번호"" 를 붙여 다시 실행하거나,"
      Write-Warning "     작업 스케줄러에서 'ServerMonitorBackup' 작업의 실행 계정을 바꾸세요."
    }
  }
  foreach ($t in $targets) { Write-Host "  백업 위치: $t" }
  Write-Host "지금 한 번 실행합니다. 결과는 각 백업 위치의 backup.log 에 남습니다."
  Start-ScheduledTask -TaskName $BackupTask
} else {
  Write-Warning "backup-data.cmd 를 찾을 수 없어 백업 작업은 등록하지 않았습니다."
}

Start-Sleep -Seconds 3
try {
  $h = Invoke-RestMethod "http://127.0.0.1:$Port/api/health" -TimeoutSec 5
  Write-Host "설치 완료: 수집기 v$($h.version) 응답 확인 (서버 $($h.servers)대 등록됨)"
} catch {
  Write-Warning "작업은 등록됐지만 아직 응답이 없습니다. 로그 확인: $Root\collector.log"
}
if ($Public) { Write-Host "화면: http://<이 서버 IP>:$Port/   로그: $Root\collector.log" }
else { Write-Host "내부 전용(127.0.0.1:$Port). IMS 웹서버에 /monitor/ 프록시를 설정하세요. 로그: $Root\collector.log" }
