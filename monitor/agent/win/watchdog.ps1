# 감시자: 작업 스케줄러가 5분마다 실행. 에이전트가 죽었거나 멈춰 있으면 다시 시작한다.
# (백신이 powershell 을 종료했거나, 작업 스케줄러 실행 시간 제한, WMI 멈춤 등 어떤 이유든 자동 복구)
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = "IMSMonitoringAgent"
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$StatusFile = Join-Path $DataDir "status.json"
$LogFile = Join-Path $DataDir "agent.log"
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [감시자] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }

$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '\\agent\.ps1' })
$reason = $null
if ($procs.Count -eq 0) { $reason = "에이전트 프로세스 없음" }
else {
  # 프로세스는 있는데 상태 파일이 3분 넘게 갱신되지 않으면 멈춘 것으로 판단
  $age = if (Test-Path $StatusFile) { ((Get-Date) - (Get-Item $StatusFile).LastWriteTime).TotalSeconds } else { 9999 }
  $starting = $false
  try { $st = Get-Content $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json; $starting = [bool]$st.starting } catch {}
  if ($age -gt 180 -and -not $starting) {
    $reason = "에이전트 응답 없음 ($([int]$age)초 동안 상태 갱신 없음)"
    foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Seconds 2
  }
}
if ($reason) {
  Log "$reason -> 다시 시작"
  try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch {
    try { & schtasks.exe /Run /TN $TaskName | Out-Null } catch { Log "재시작 실패: $($_.Exception.Message)" }
  }
}
