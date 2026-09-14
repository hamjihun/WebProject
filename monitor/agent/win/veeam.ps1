# Veeam Backup & Replication 작업 상태 수집 (v11 이상 모듈, 구버전 스냅인 둘 다 시도)
# 에이전트가 10분마다 별도 프로세스로 실행하고, 결과를 %ProgramData%\IMSMonitoringAgent\veeam.json 에 남긴다.
# 작업 목록은 "세션 기록"을 기준으로 모은다: VM 백업(Get-VBRBackupSession)과 에이전트 백업(Get-VBRComputerBackupJobSession)
# 둘 다 읽어 작업 이름별로 묶으므로, 어떤 종류의 작업이든 한 번이라도 실행됐으면 나온다.
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$Out = Join-Path $DataDir "veeam.json"
$LogFile = Join-Path $DataDir "agent.log"
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [Veeam] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
function Save($obj) { try { $obj | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $Out -Encoding UTF8 } catch { Log "저장 실패: $($_.Exception.Message)" } }
function Iso($d) { try { if ($d -and ($d -is [datetime]) -and $d.Year -gt 2000) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}; return $null }
function Str($v) { try { if ($null -eq $v) { return '' }; $s = [string]$v; if ($v -is [array]) { $s = [string]$v[0] }; return ($s -split '\s+')[0] } catch { return '' } }
function Prop($o, $names) { foreach ($n in $names) { try { $v = $o.$n; if ($null -ne $v -and "$v" -ne '') { return $v } } catch {} }; return $null }
$now = Iso (Get-Date)

$loaded = $false
try { Import-Module Veeam.Backup.PowerShell -ErrorAction Stop -WarningAction SilentlyContinue; $loaded = $true } catch {}
if (-not $loaded) { try { Add-PSSnapin VeeamPSSnapin -ErrorAction Stop; $loaded = $true } catch {} }
if (-not $loaded) { Save @{ time = $now; error = 'Veeam PowerShell 모듈을 찾을 수 없습니다'; jobs = @(); repos = @() }; Log "Veeam PowerShell 모듈 없음"; exit 1 }

try {
  $diag = @()
  # 1) 작업 정의 (이름 → 종류/사용 여부/다음 실행)
  $defs = @{}
  $vmJobs = @(); try { $vmJobs = @(Get-VBRJob -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $diag += "VBRJob 오류: $($_.Exception.Message)" }
  foreach ($j in $vmJobs) {
    $type = ''; try { $type = [string]$j.TypeToString } catch {}; if (-not $type) { $type = [string]$j.JobType }
    $next = $null; try { if ($j.IsScheduleEnabled -and $j.ScheduleOptions.NextRun) { $next = Iso ([datetime]$j.ScheduleOptions.NextRun) } } catch {}
    $defs[[string]$j.Name] = @{ type = $type; enabled = [bool]$j.IsScheduleEnabled; next = $next; id = [string]$j.Id }
  }
  $agJobs = @(); try { $agJobs = @(Get-VBRComputerBackupJob -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $diag += "ComputerBackupJob 오류: $($_.Exception.Message)" }
  foreach ($j in $agJobs) {
    $plat = Str (Prop $j @('OSPlatform')); $mode = Str (Prop $j @('Mode'))
    $type = "$plat Agent " + $(if ($mode -match 'Agent') { 'Policy' } else { 'Backup' })
    $en = Prop $j @('ScheduleEnabled', 'JobEnabled', 'IsScheduleEnabled', 'IsEnabled'); if ($null -eq $en) { $en = $true }
    $next = $null; try { $nr = Prop $j @('NextRun'); if (-not $nr -and $j.ScheduleOptions) { $nr = $j.ScheduleOptions.NextRun }; if ($nr) { $next = Iso ([datetime]$nr) } } catch {}
    $defs[[string]$j.Name] = @{ type = $type.Trim(); enabled = [bool]$en; next = $next; id = [string]$j.Id }
  }
  # 2) 세션 기록 (작업 이름별로 묶기)
  $byName = @{}
  function AddSess($s) {
    $n = [string](Prop $s @('JobName', 'Name')); if (-not $n) { return }
    if (-not $byName.ContainsKey($n)) { $byName[$n] = New-Object System.Collections.ArrayList }
    [void]$byName[$n].Add($s)
  }
  $vmSess = @(); try { $vmSess = @(Get-VBRBackupSession -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $diag += "BackupSession 오류: $($_.Exception.Message)" }
  $agSess = @(); try { $agSess = @(Get-VBRComputerBackupJobSession -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $diag += "ComputerBackupJobSession 오류: $($_.Exception.Message)" }
  foreach ($s in $vmSess) { AddSess $s }
  foreach ($s in $agSess) { AddSess $s }
  # 추가 경로: 내부 API(모든 종류의 세션/작업), 구버전 엔드포인트 세션, 저장소의 백업 체인 이름
  $allSess = @(); try { $allSess = @([Veeam.Backup.Core.CBackupSession]::GetAll()) } catch { $diag += "CBackupSession.GetAll 오류: $($_.Exception.Message)" }
  foreach ($s in $allSess) { AddSess $s }
  $allJobs = @(); try { $allJobs = @([Veeam.Backup.Core.CBackupJob]::GetAll()) } catch { $diag += "CBackupJob.GetAll 오류: $($_.Exception.Message)" }
  foreach ($j in $allJobs) { $n = [string]$j.Name; if ($n -and -not $defs.ContainsKey($n)) { $t = ''; try { $t = [string]$j.TypeToString } catch {}; if (-not $t) { $t = [string]$j.JobType }; $en = $true; try { $en = [bool]$j.IsScheduleEnabled } catch {}; $defs[$n] = @{ type = $t; enabled = $en; next = $null; id = [string]$j.Id } } }
  $epSess = @(); try { $epSess = @(Get-VBREPSession -WarningAction SilentlyContinue -ErrorAction Stop) } catch {}
  foreach ($s in $epSess) { AddSess $s }
  $chains = @(); try { $chains = @(Get-VBRBackup -WarningAction SilentlyContinue -ErrorAction Stop) } catch { $diag += "VBRBackup 오류: $($_.Exception.Message)" }
  foreach ($b in $chains) { $n = [string]$b.JobName; if ($n -and -not $defs.ContainsKey($n) -and -not $byName.ContainsKey($n)) { $defs[$n] = @{ type = [string]$b.JobType; enabled = $true; next = $null; id = '' } } }
  $diagLine = "작업 정의 VM=$($vmJobs.Count) 에이전트=$($agJobs.Count) 전체API=$($allJobs.Count) 체인=$($chains.Count), 세션 VM=$($vmSess.Count) 에이전트=$($agSess.Count) 전체API=$($allSess.Count) EP=$($epSess.Count), 작업 이름 $($byName.Count)개" + $(if ($diag.Count) { ' / ' + ($diag -join '; ') } else { '' })
  Log $diagLine

  # 3) 작업별 마지막 결과
  $names = @($defs.Keys) + @($byName.Keys) | Sort-Object -Unique
  $jobs = @()
  foreach ($n in $names) {
    $d = $defs[$n]; if (-not $d) { $d = @{ type = ''; enabled = $true; next = $null } }
    $sess = @(); if ($byName.ContainsKey($n)) { $sess = @($byName[$n] | Sort-Object { try { [datetime]$_.CreationTime } catch { [datetime]::MinValue } } -Descending) }
    $last = $null; if ($sess.Count -gt 0) { $last = $sess[0] }
    $ok = $null; foreach ($s in $sess) { $r = Str $s.Result; if ($r -eq 'Success' -or $r -eq 'Warning') { $ok = $s; break } }
    $result = 'None'; $state = ''; $prog = $null; $dur = 0; $size = 0; $start = $null; $end = $null
    if ($last) {
      $result = Str $last.Result; if (-not $result) { $result = 'None' }
      $state = Str $last.State
      if ($state -and $state -ne 'Stopped') { $result = 'Running'; try { $prog = [int]$last.Progress.Percents } catch {} }
      $start = Iso $last.CreationTime; $end = Iso $last.EndTime
      try { if ($last.EndTime -and $last.EndTime.Year -gt 2000) { $dur = [int]($last.EndTime - $last.CreationTime).TotalSeconds } } catch {}
      try { $size = [int64]$last.BackupStats.BackupSize } catch {}
      if (-not $size) { try { $size = [int64]$last.Progress.ProcessedUsedSize } catch {} }
    }
    $jobs += @{ name = $n; type = [string]$d.type; enabled = [bool]$d.enabled; result = $result; state = $state; progress = $prog
      start = $start; end = $end; ok_end = $(if ($ok) { Iso $ok.EndTime } else { $null }); duration = $dur; size = $size; next = $d.next }
  }
  # 4) 저장소
  $repos = @()
  foreach ($r in @(Get-VBRBackupRepository -WarningAction SilentlyContinue)) {
    $item = @{ name = [string]$r.Name; total = 0; free = 0 }
    try { $c = $r.GetContainer(); $item.total = [int64]$c.CachedTotalSpace.InBytes; $item.free = [int64]$c.CachedFreeSpace.InBytes } catch {}
    $repos += $item
  }
  Save @{ time = $now; error = ''; jobs = @($jobs); repos = @($repos); diag = $diagLine }
} catch {
  Save @{ time = $now; error = $_.Exception.Message; jobs = @(); repos = @() }
  Log "수집 실패: $($_.Exception.Message)"
}
