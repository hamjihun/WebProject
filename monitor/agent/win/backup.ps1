# 1차(SQL 백업 파일·msdb 기록) / 3차(USB 복사) 상태 수집 → %ProgramData%\IMSMonitoringAgent\backup.json
# 에이전트가 5분마다 별도 프로세스로 실행. agent.conf 의 BACKUP_PATH / SQL / USB 로 조정 가능 (없으면 자동 감지).
param([string]$ConfPath)
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$Out = Join-Path $DataDir "backup.json"
$UsbState = Join-Path $DataDir "usb-state.json"
$LogFile = Join-Path $DataDir "agent.log"
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [백업] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
function Iso($d) { try { if ($d -and ($d -is [datetime]) -and $d.Year -gt 2000) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}; return $null }
$conf = @{}
try { if ($ConfPath -and (Test-Path $ConfPath)) { foreach ($line in Get-Content $ConfPath) { if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $conf[$matches[1].ToUpper()] = $matches[2] } } } } catch {}

# ---- 백업 폴더 (SQL 유지 관리 계획이 .bak 을 쓰는 곳) ----
$paths = @()
if ($conf['BACKUP_PATH']) { $paths = @($conf['BACKUP_PATH'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
else { foreach ($p in @('D:\DBBackup', 'D:\DB_BACKUP', 'E:\DBBackup', 'C:\DBBackup')) { if (Test-Path $p) { $paths += $p } } }
function ScanFolder($root, $depth) {
  # 폴더 아래 백업 파일(.bak/.trn/.dif/.zip/.7z) 중 최신 파일과 개수·용량
  $r = @{ path = $root; exists = (Test-Path $root); newest_file = $null; newest_time = $null; count = 0; size = 0; error = '' }
  if (-not $r.exists) { return $r }
  try {
    $gci = @{ Path = $root; Recurse = $true; File = $true; ErrorAction = 'SilentlyContinue' }; if ($depth -gt 0) { $gci.Depth = $depth }   # USB 전체를 훑을 땐 3단계까지만
    $files = @(Get-ChildItem @gci | Where-Object { $_.Extension -match '^\.(bak|trn|dif|zip|7z|rar|bkf|sql)$' })
    $r.count = $files.Count; $r.size = [int64](($files | Measure-Object Length -Sum).Sum)
    $n = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($n) { $r.newest_file = $n.FullName.Substring($root.Length).TrimStart('\'); $r.newest_time = Iso $n.LastWriteTime; $r.newest_size = [int64]$n.Length }
  } catch { $r.error = $_.Exception.Message }
  return $r
}
$files = @(); foreach ($p in $paths) { $files += ScanFolder $p 0 }

# ---- SQL Server msdb 백업 기록 (DB별 마지막 전체/차등/로그 백업) ----
$sql = $null
if ($conf['SQL'] -ne '0') {
  $instances = @()
  try { $names = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop; foreach ($pn in $names.PSObject.Properties) { if ($pn.Name -notmatch '^PS') { $instances += $(if ($pn.Name -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$($pn.Name)" }) } } } catch {}
  if ($conf['SQL'] -and $conf['SQL'] -ne 'auto') { $instances = @($conf['SQL']) }
  if ($instances.Count -gt 0) {
    $sql = @{ instance = ''; error = ''; dbs = @() }
    $q = @"
SELECT d.name AS db,
  (SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset b WHERE b.database_name = d.name AND b.type = 'D') AS full_last,
  (SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset b WHERE b.database_name = d.name AND b.type = 'I') AS diff_last,
  (SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset b WHERE b.database_name = d.name AND b.type = 'L') AS log_last,
  (SELECT TOP 1 CAST(b.backup_size AS bigint) FROM msdb.dbo.backupset b WHERE b.database_name = d.name AND b.type = 'D' ORDER BY b.backup_finish_date DESC) AS full_size,
  (SELECT TOP 1 f.physical_device_name FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = b.media_set_id WHERE b.database_name = d.name AND b.type = 'D' ORDER BY b.backup_finish_date DESC) AS full_path,
  d.recovery_model_desc AS recovery
FROM sys.databases d WHERE d.database_id > 4 AND d.state = 0 AND d.name NOT IN ('distribution') ORDER BY d.name
"@
    $done = $false
    foreach ($inst in $instances) {
      try {
        $cn = New-Object System.Data.SqlClient.SqlConnection ("Server=$inst;Database=msdb;Integrated Security=True;Connection Timeout=8")
        $cn.Open(); $cmd = $cn.CreateCommand(); $cmd.CommandText = $q; $cmd.CommandTimeout = 30
        $rd = $cmd.ExecuteReader()
        while ($rd.Read()) {
          $g = { param($i) if ($rd.IsDBNull($i)) { $null } else { $rd.GetValue($i) } }
          $sql.dbs += @{ db = [string]$rd.GetValue(0); full = Iso (& $g 1); diff = Iso (& $g 2); log = Iso (& $g 3); size = [int64]$(if ($rd.IsDBNull(4)) { 0 } else { $rd.GetValue(4) }); path = [string](& $g 5); recovery = [string](& $g 6) }
        }
        $rd.Close(); $cn.Close(); $sql.instance = $inst; $done = $true; break
      } catch { $sql.error = "$inst : $($_.Exception.Message)" }
    }
    if ($done) { $sql.error = '' }
  }
}

# ---- USB (꽂혀 있는 동안만 볼 수 있으므로 마지막으로 본 결과를 usb-state.json 에 보관) ----
$usb = $null
if ($conf['USB'] -ne '0') {
  $prev = @{}; try { if (Test-Path $UsbState) { $prev = Get-Content $UsbState -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
  $usb = @{ connected = $false; drive = ''; label = ''; path = ''; newest_file = $null; newest_time = $null; count = 0; size = 0; free = 0; total = 0; last_seen = $null; error = '' }
  foreach ($k in @('drive', 'label', 'path', 'newest_file', 'newest_time', 'count', 'size', 'free', 'total', 'last_seen')) { try { if ($prev.$k -ne $null) { $usb[$k] = $prev.$k } } catch {} }
  # USB 로 연결된 디스크의 드라이브 문자 찾기
  $letters = @()
  if ($conf['USB'] -and $conf['USB'] -ne 'auto') { $letters = @($conf['USB'] -split ',' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ }) }
  else {
    try {
      foreach ($dd in @(Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' })) {
        foreach ($part in @(Get-CimAssociatedInstance -InputObject $dd -ResultClassName Win32_DiskPartition)) {
          foreach ($ld in @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk)) { $letters += $ld.DeviceID }
        }
      }
      foreach ($ld in @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2")) { if ($letters -notcontains $ld.DeviceID -and $ld.Size -gt 4GB) { $letters += $ld.DeviceID } }
    } catch { $usb.error = $_.Exception.Message }
  }
  $letters = @($letters | Sort-Object -Unique | Where-Object { Test-Path "$_\" })
  if ($letters.Count -gt 0) {
    # 여러 개면 백업 폴더가 있는 것 우선
    $pick = $null; $pickPath = ''
    foreach ($L in $letters) {
      $cands = @()
      try { $cands = @(Get-ChildItem -Path "$L\" -Directory -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'backup|bak|db' }) } catch {}
      if ($cands.Count -gt 0) { $pick = $L; $pickPath = ($cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; break }
      if (-not $pick) { $pick = $L; $pickPath = "$L\" }
    }
    $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$pick'"
    $scan = ScanFolder $pickPath $(if ($pickPath -match '^[A-Z]:\\$') { 3 } else { 0 })
    $usb.connected = $true; $usb.drive = $pick; $usb.label = [string]$ld.VolumeName; $usb.path = $pickPath
    $usb.newest_file = $scan.newest_file; $usb.newest_time = $scan.newest_time; $usb.count = $scan.count; $usb.size = $scan.size
    $usb.free = [int64]$ld.FreeSpace; $usb.total = [int64]$ld.Size; $usb.last_seen = Iso (Get-Date)
    if ($scan.error) { $usb.error = $scan.error }
    try { $usb | ConvertTo-Json -Compress | Set-Content -Path $UsbState -Encoding UTF8 } catch {}
  }
}

$out = @{ time = Iso (Get-Date); files = @($files); sql = $sql; usb = $usb }
try { $out | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $Out -Encoding UTF8 } catch { Log "저장 실패: $($_.Exception.Message)" }
