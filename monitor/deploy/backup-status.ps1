# 백업 결과를 monitor\data\backup-status.json 으로 남긴다 (모니터링 화면에서 보여 주기 위함).
# backup-data.cmd 가 백업을 마친 뒤 호출한다. 직접 실행해도 된다.
$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$list = Join-Path $PSScriptRoot 'backup-target.txt'
function Iso($d) { try { if ($d -and $d.Year -gt 2000) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}; return $null }

$targets = @()
if (Test-Path $list) {
  $targets = @(Get-Content $list -Encoding Default | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
if ($targets.Count -eq 0) { $targets = @('C:\ims\monitor-backup') }

$out = @{ time = Iso (Get-Date); targets = @() }
foreach ($t in $targets) {
  $r = @{ path = $t; reachable = $false; last_date = $null; last_time = $null; files = 0; size = 0; keep = 0; full_time = $null; message = '' }
  try {
    if (Test-Path -LiteralPath $t) {
      $r.reachable = $true
      $daily = Join-Path $t 'daily'
      if (Test-Path -LiteralPath $daily) {
        $dirs = @(Get-ChildItem -LiteralPath $daily -Directory | Sort-Object Name)
        $r.keep = $dirs.Count
        $d = $dirs | Select-Object -Last 1
        if ($d) {
          $r.last_date = $d.Name
          $r.last_time = Iso $d.LastWriteTime
          $f = @(Get-ChildItem -LiteralPath $d.FullName -File)
          $r.files = $f.Count
          $r.size = [int64](($f | Measure-Object Length -Sum).Sum)
        }
      }
      $full = Join-Path $t 'full'
      if (Test-Path -LiteralPath $full) { $r.full_time = Iso (Get-Item -LiteralPath $full).LastWriteTime }
      $log = Join-Path $t 'backup.log'
      if (Test-Path -LiteralPath $log) {
        $line = @(Get-Content -LiteralPath $log -Tail 8 | Where-Object { $_ -match '완료|실패' } | Select-Object -Last 1)
        if ($line.Count -gt 0) { $r.message = [string]$line[0] }
      }
    } else {
      $r.message = '폴더를 열 수 없습니다 (네트워크 또는 권한 확인)'
    }
  } catch { $r.message = $_.Exception.Message }
  $out.targets += $r
}
try {
  $json = $out | ConvertTo-Json -Depth 5 -Compress
  [System.IO.File]::WriteAllText((Join-Path $Root 'data\backup-status.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
} catch {}
