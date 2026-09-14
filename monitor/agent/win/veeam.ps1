# Veeam Backup & Replication 작업 상태 수집 (v11 이상 모듈, 구버전 스냅인 둘 다 시도)
# 에이전트가 10분마다 별도 프로세스로 실행하고, 결과를 %ProgramData%\IMSMonitoringAgent\veeam.json 에 남긴다.
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$Out = Join-Path $DataDir "veeam.json"
$LogFile = Join-Path $DataDir "agent.log"
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [Veeam] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
function Save($obj) { try { $obj | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $Out -Encoding UTF8 } catch { Log "저장 실패: $($_.Exception.Message)" } }
function Iso($d) { try { if ($d -and ($d -is [datetime]) -and $d.Year -gt 2000) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}; return $null }
$now = Iso (Get-Date)

$loaded = $false
try { Import-Module Veeam.Backup.PowerShell -ErrorAction Stop -WarningAction SilentlyContinue; $loaded = $true } catch {}
if (-not $loaded) { try { Add-PSSnapin VeeamPSSnapin -ErrorAction Stop; $loaded = $true } catch {} }
if (-not $loaded) { Save @{ time = $now; error = 'Veeam PowerShell 모듈을 찾을 수 없습니다'; jobs = @(); repos = @() }; Log "Veeam PowerShell 모듈 없음"; exit 1 }

try {
  $jobs = @()
  $sessions = @(Get-VBRBackupSession -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
  foreach ($j in @(Get-VBRJob -WarningAction SilentlyContinue)) {
    $js = @($sessions | Where-Object { $_.JobId -eq $j.Id } | Sort-Object CreationTime -Descending)
    $last = $null; if ($js.Count -gt 0) { $last = $js[0] }
    $ok = $js | Where-Object { $_.Result -eq 'Success' -or $_.Result -eq 'Warning' } | Select-Object -First 1
    $type = ''; try { $type = [string]$j.TypeToString } catch {}; if (-not $type) { $type = [string]$j.JobType }
    $next = $null; try { if ($j.IsScheduleEnabled -and $j.ScheduleOptions.NextRun) { $next = Iso ([datetime]$j.ScheduleOptions.NextRun) } } catch {}
    $size = 0; try { if ($last) { $size = [int64]$last.BackupStats.BackupSize } } catch {}
    $result = 'None'; $state = ''; $prog = $null; $dur = 0
    if ($last) {
      $result = [string]$last.Result; $state = [string]$last.State
      if ($state -ne 'Stopped') { $result = 'Running'; try { $prog = [int]$last.Progress.Percents } catch {} }
      try { if ($last.EndTime -and $last.EndTime.Year -gt 2000) { $dur = [int]($last.EndTime - $last.CreationTime).TotalSeconds } } catch {}
    }
    $jobs += @{
      name = [string]$j.Name; type = $type; enabled = [bool]$j.IsScheduleEnabled
      result = $result; state = $state; progress = $prog
      start = $(if ($last) { Iso $last.CreationTime } else { $null }); end = $(if ($last) { Iso $last.EndTime } else { $null })
      ok_end = $(if ($ok) { Iso $ok.EndTime } else { $null }); duration = $dur; size = $size; next = $next
    }
  }
  # Veeam Agent(컴퓨터 백업) 작업이 있으면 같이
  try {
    foreach ($j in @(Get-VBRComputerBackupJob -WarningAction SilentlyContinue -ErrorAction Stop)) {
      $js = @(Get-VBRComputerBackupJobSession -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.JobId -eq $j.Id } | Sort-Object CreationTime -Descending)
      $last = $null; if ($js.Count -gt 0) { $last = $js[0] }
      $ok = $js | Where-Object { $_.Result -eq 'Success' -or $_.Result -eq 'Warning' } | Select-Object -First 1
      $jobs += @{ name = [string]$j.Name; type = 'Agent Backup'; enabled = [bool]$j.ScheduleEnabled; result = $(if ($last) { [string]$last.Result } else { 'None' }); state = $(if ($last) { [string]$last.State } else { '' }); progress = $null
        start = $(if ($last) { Iso $last.CreationTime } else { $null }); end = $(if ($last) { Iso $last.EndTime } else { $null }); ok_end = $(if ($ok) { Iso $ok.EndTime } else { $null }); duration = 0; size = 0; next = $null }
    }
  } catch {}
  $repos = @()
  foreach ($r in @(Get-VBRBackupRepository -WarningAction SilentlyContinue)) {
    $item = @{ name = [string]$r.Name; total = 0; free = 0 }
    try { $c = $r.GetContainer(); $item.total = [int64]$c.CachedTotalSpace.InBytes; $item.free = [int64]$c.CachedFreeSpace.InBytes } catch {}
    $repos += $item
  }
  Save @{ time = $now; error = ''; jobs = @($jobs); repos = @($repos) }
} catch {
  Save @{ time = $now; error = $_.Exception.Message; jobs = @(); repos = @() }
  Log "수집 실패: $($_.Exception.Message)"
}
