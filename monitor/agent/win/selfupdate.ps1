# 에이전트 스스로 업데이트 (agent.ps1 이 점 소싱해 쓴다)
# 수집기 화면에서 "배포 버전"을 정하면 /api/metrics 응답에 agent.update = { ver, sha, size, n, prev{ver,sha} } 가 온다.
#  1) 새 설치 파일(과 되돌릴 때 쓸 지금 버전 설치 파일)을 수집기에서 받아 SHA256 이 맞는지 확인
#  2) 별도 작업(IMSMonitoringAgentUpdate, SYSTEM)으로 update.ps1 을 실행 — 설치 프로그램이 에이전트를 끄므로 에이전트 안에서 직접 돌리지 않는다
#  3) update.ps1: agent.conf 를 보관 → 새 버전 조용히 설치(/S) → 지워진 설정 줄을 되살림 → 4분 안에 새 버전이 정상 전송하는지 확인
#     → 안 되면 이전 버전 설치 파일로 자동 되돌림. 결과는 update\result.json (다음 전송부터 화면에 표시)
# 같은 지시(버전+번호 n)는 한 번만 시도한다 (실패·되돌림 뒤 계속 되풀이하지 않게). 화면에서 다시 배포하면 번호가 바뀌어 다시 시도.
$UpdDir = Join-Path $DataDir 'update'
$UpdRes = Join-Path $UpdDir 'result.json'
$UpdTried = Join-Path $UpdDir 'tried.txt'
$UpdTask = 'IMSMonitoringAgentUpdate'

function Get-UpdateResult {
  try { if (Test-Path $UpdRes) { return (Get-Content $UpdRes -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch {}
  return $null
}

function Initialize-SelfUpdate {                    # 에이전트 시작 때: 끝난 업데이트 작업 정리, 중간에 끊긴 업데이트는 실패로
  try { New-Item -ItemType Directory -Force -Path $UpdDir | Out-Null } catch {}
  $r = Get-UpdateResult
  $running = $false
  try { $t = Get-ScheduledTask -TaskName $UpdTask -ErrorAction Stop; $running = $t.State -eq 'Running'; if (-not $running) { Unregister-ScheduledTask -TaskName $UpdTask -Confirm:$false -ErrorAction SilentlyContinue } } catch {}
  if ($r -and $r.state -eq 'running' -and -not $running) {
    try { if (((Get-Date) - (Get-Item $UpdRes).LastWriteTime).TotalMinutes -gt 20) { $r.state = 'failed'; $r.msg = '업데이트가 중간에 끊겼습니다 (재부팅 등)'; $r | ConvertTo-Json -Compress | Set-Content $UpdRes -Encoding UTF8 } } catch {}
  }
}

function Get-FileSha([string]$p) { $fs = $null; try { $fs = [IO.File]::OpenRead($p); return ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($fs)) -replace '-', '').ToLower() } catch { return '' } finally { if ($fs) { $fs.Close() } } }

function Get-Setup([string]$ver, [string]$sha) {    # 수집기에서 설치 파일 받기 (이미 받아 둔 것이 맞으면 그대로)
  $f = Join-Path $UpdDir "setup-$ver.exe"
  if ((Test-Path $f) -and (Get-FileSha $f) -eq $sha) { return $f }
  $u = ($Url -replace '/api/metrics/?$', '') + '/api/agent/setup?ver=' + [uri]::EscapeDataString($ver)
  try { Invoke-WebRequest -Uri $u -Headers @{ 'X-Token' = $Token } -OutFile $f -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop } catch { Log "업데이트: $ver 설치 파일을 받지 못함 ($($_.Exception.Message))"; return $null }
  if ((Get-FileSha $f) -ne $sha) { Log "업데이트: $ver 설치 파일 확인값(SHA256)이 맞지 않아 쓰지 않음"; Remove-Item $f -Force -ErrorAction SilentlyContinue; return $null }
  return $f
}

$UpdScript = @'
param([string]$New, [string]$Old, [string]$NewVer, [string]$OldVer, [string]$Inst)
$D = Join-Path $env:ProgramData 'IMSMonitoringAgent'; $U = Join-Path $D 'update'
$Res = Join-Path $U 'result.json'; $LogF = Join-Path $D 'agent.log'; $StatusF = Join-Path $D 'status.json'
$Conf = Join-Path $Inst 'agent.conf'; $Bak = Join-Path $U 'agent.conf.bak'
function Log($m) { try { Add-Content -Path $LogF -Value ("{0:yyyy-MM-dd HH:mm:ss} [업데이트] {1}" -f (Get-Date), $m) } catch {} }
function Save($state, $msg) { try { [ordered]@{ state = $state; from = $OldVer; to = $NewVer; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); msg = $msg } | ConvertTo-Json -Compress | Set-Content -Path $Res -Encoding UTF8 } catch {} }
function Restore-Conf {                            # 예전 설치 파일(1.8.1 이하)은 agent.conf 를 4줄로 덮어쓰므로 빠진 설정 줄을 되살린다
  try {
    if (-not (Test-Path $Bak)) { return }
    $cur = @(); if (Test-Path $Conf) { $cur = @(Get-Content $Conf) }
    $keys = @($cur | ForEach-Object { if ($_ -match '^\s*([A-Za-z_]+)\s*=') { $matches[1].ToUpper() } })
    $add = @(Get-Content $Bak | Where-Object { $_ -match '^\s*([A-Za-z_]+)\s*=' -and $keys -notcontains $matches[1].ToUpper() })
    if ($add.Count) { Add-Content -Path $Conf -Value $add; Log "설정 줄 되살림: $(($add | ForEach-Object { ($_ -split '=')[0] }) -join ', ')" }
  } catch { Log "설정 되살리기 실패: $($_.Exception.Message)" }
}
function Run-Setup([string]$exe) { try { $p = Start-Process -FilePath $exe -ArgumentList '/S' -Wait -PassThru -ErrorAction Stop; return $p.ExitCode } catch { Log "설치 실행 실패: $($_.Exception.Message)"; return -1 } }
function Wait-Ok([string]$ver, [datetime]$since) {   # 설치된 에이전트가 그 버전이고 4분 안에 정상 전송하면 성공
  $end = (Get-Date).AddMinutes(4)
  while ((Get-Date) -lt $end) {
    Start-Sleep -Seconds 10
    try {
      $txt = Get-Content (Join-Path $Inst 'agent.ps1') -Raw
      if ($txt -notmatch ('\$AgentVersion = "' + [regex]::Escape($ver) + '"')) { continue }
      $st = Get-Content $StatusF -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
      if ($st.ok -and ([datetime]$st.time) -gt $since) { return $true }
    } catch {}
  }
  return $false
}
Save 'running' ''
try { Copy-Item $Conf $Bak -Force } catch {}
Log "$OldVer → $NewVer 설치 시작"
$t0 = Get-Date
$code = Run-Setup $New; Restore-Conf
if ($code -eq 0 -and (Wait-Ok $NewVer $t0)) { Save 'ok' "$NewVer 설치 완료"; Log "$NewVer 설치 완료, 정상 전송 확인"; exit 0 }
$why = $(if ($code -ne 0) { "설치 프로그램 오류 (코드 $code)" } else { '설치 뒤 4분 동안 정상 전송이 없음' })
if ($Old -and (Test-Path $Old)) {
  Log "$NewVer 실패 ($why) → $OldVer 로 되돌림"
  $t1 = Get-Date; Run-Setup $Old | Out-Null; Restore-Conf
  if (Wait-Ok $OldVer $t1) { Save 'rolledback' "$NewVer 가 정상 동작하지 않아 $OldVer 로 자동 되돌림 ($why)" } else { Save 'failed' "$NewVer 실패 ($why), $OldVer 로 되돌렸지만 응답 확인 안 됨" }
} else { Save 'failed' "$NewVer 실패 ($why) — 되돌릴 설치 파일이 없음" }
'@

function Start-AgentUpdate($u) {
  if (-not $u -or -not $u.ver -or -not $u.sha -or $u.ver -eq $AgentVersion) { return }
  $key = "$($u.ver)|$($u.n)"
  $tried = ''; try { if (Test-Path $UpdTried) { $tried = (Get-Content $UpdTried -Raw).Trim() } } catch {}
  if ($tried -eq $key) { return }
  try { $t = Get-ScheduledTask -TaskName $UpdTask -ErrorAction Stop; if ($t.State -eq 'Running') { return } } catch {}
  try { New-Item -ItemType Directory -Force -Path $UpdDir | Out-Null; Set-Content -Path $UpdTried -Value $key -Encoding ASCII } catch {}
  Log "업데이트 지시: $AgentVersion → $($u.ver)"
  $new = Get-Setup $u.ver $u.sha
  if (-not $new) {
    try { [ordered]@{ state = 'failed'; from = $AgentVersion; to = $u.ver; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); msg = '설치 파일을 받지 못했거나 확인값이 다름' } | ConvertTo-Json -Compress | Set-Content $UpdRes -Encoding UTF8 } catch {}
    return
  }
  $old = ''; if ($u.prev -and $u.prev.ver -and $u.prev.sha) { $o = Get-Setup $u.prev.ver $u.prev.sha; if ($o) { $old = $o } }
  if (-not $old) { Log "업데이트: 되돌릴 때 쓸 $AgentVersion 설치 파일이 수집기에 없음 (문제가 생기면 직접 설치 필요)" }
  $ps1 = Join-Path $UpdDir 'update.ps1'
  try {
    Set-Content -Path $ps1 -Value $UpdScript -Encoding UTF8
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" -New `"$new`" -Old `"$old`" -NewVer `"$($u.ver)`" -OldVer `"$AgentVersion`" -Inst `"$Dir`""
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $se = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $UpdTask -Action $act -Principal $pr -Settings $se -Description 'IMS 에이전트 업데이트 (한 번 실행)' -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $UpdTask -ErrorAction Stop
    Log "업데이트 작업 시작: $($u.ver) (되돌림 파일 $(if ($old) { '있음' } else { '없음' }))"
  } catch {
    Log "업데이트 작업 시작 실패: $($_.Exception.Message)"
    try { [ordered]@{ state = 'failed'; from = $AgentVersion; to = $u.ver; at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); msg = '업데이트 작업을 만들지 못함: ' + $_.Exception.Message } | ConvertTo-Json -Compress | Set-Content $UpdRes -Encoding UTF8 } catch {}
  }
}
