# 1차(SQL 백업 파일·msdb 기록) / 3차(USB 복사) 상태 수집 → %ProgramData%\IMSMonitoringAgent\backup.json
# 에이전트가 5분마다 별도 프로세스로 실행. agent.conf 의 BACKUP_PATH / SQL / USB 로 조정 가능 (없으면 자동 감지).
param([string]$ConfPath, [switch]$ForceUsb)
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$Out = Join-Path $DataDir "backup.json"
$UsbState = Join-Path $DataDir "usb-state.json"
$UsbDone = Join-Path $DataDir "usb-done.json"     # usb-done.ps1 (bat 파일에서 호출) 이 남기는 복사 완료 기록
$LogFile = Join-Path $DataDir "agent.log"
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [백업] {1}" -f (Get-Date), $m) } catch {} }
function Iso($d) { try { if ($d -and ($d -is [datetime]) -and $d.Year -gt 2000) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}; return $null }
$conf = @{}
try { if ($ConfPath -and (Test-Path $ConfPath)) { foreach ($line in Get-Content $ConfPath) { if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $conf[$matches[1].ToUpper()] = $matches[2] } } } } catch {}

# ---- 백업 폴더 (SQL 유지 관리 계획이 .bak 을 쓰는 곳) ----
$paths = @()
if ($conf['BACKUP_PATH']) { $paths = @($conf['BACKUP_PATH'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
else { foreach ($p in @('D:\DBBackup', 'D:\DB_BACKUP', 'C:\DBBackup', 'C:\DB_BACKUP')) { if (Test-Path $p) { $paths += $p } } }
function ScanFolder($root, $depth) {
  # 폴더 아래 백업 파일(.bak/.trn/.dif/.zip/.7z) 중 최신 파일과 개수·용량
  $r = @{ path = $root; exists = (Test-Path $root); newest_file = $null; newest_time = $null; count = 0; size = 0; error = '' }
  if (-not $r.exists) { return $r }
  try {
    $gci = @{ Path = $root; Recurse = $true; File = $true; ErrorAction = 'SilentlyContinue' }; if ($depth -gt 0) { $gci.Depth = $depth }   # USB 전체를 훑을 땐 3단계까지만
    $files = @(Get-ChildItem @gci | Where-Object { $_.Extension -match '^\.(bak|trn|dif|zip|7z|rar|bkf|sql)$' })
    $r.count = $files.Count; $r.size = [int64](($files | Measure-Object Length -Sum).Sum)
    $n = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($n) { $r.newest_file = $n.FullName.Substring($root.Length).TrimStart('\', '/'); $r.newest_time = Iso $n.LastWriteTime; $r.newest_size = [int64]$n.Length }
    # 복사된 시각: USB 로 복사하면 수정 시각은 원본 그대로지만 생성 시각은 복사한 때가 된다
    $c = $files | Sort-Object CreationTime -Descending | Select-Object -First 1
    if ($c) { $r.copied_time = Iso $c.CreationTime; $r.copied_file = $c.FullName.Substring($root.Length).TrimStart('\', '/') }
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
# 확인 시간대: agent.conf USB_HOURS > 수집기에서 내려온 remote.conf > 기본 07:00-10:00. 시간대 밖이면 USB 를 살피지 않고 마지막 값만 보낸다.
# 경로: agent.conf USB= > 수집기 화면(서버 클릭 → 3차 백업 경로)에서 내려온 remote.conf USB_PATHS= > 자동 감지. 여러 개는 ; 로 구분.
#   형식: E:\DBBackup  또는  이름=E:\DBBackup  또는  라벨:\DBBackup (라벨 = USB 볼륨 이름, 드라이브 문자가 바뀌어도 찾음)  또는  E: (드라이브 전체)
$remote = @{}
try { $rc = Join-Path $DataDir "remote.conf"; if (Test-Path $rc) { foreach ($line in Get-Content $rc) { if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { $remote[$matches[1]] = $matches[2] } } } } catch {}
$win = $conf['USB_HOURS']; if (-not $win) { $win = $remote['USB_HOURS'] }
if ($null -eq $win) { $win = '07:00-10:00' }
$inWindow = $true
if ($win -match '^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$') {
  $cur = (Get-Date).Hour * 60 + (Get-Date).Minute; $from = [int]$matches[1] * 60 + [int]$matches[2]; $to = [int]$matches[3] * 60 + [int]$matches[4]
  $inWindow = $(if ($from -le $to) { $cur -ge $from -and $cur -lt $to } else { $cur -ge $from -or $cur -lt $to })
}
function NewUsb($name) { return @{ name = $name; connected = $false; drive = ''; label = ''; path = ''; newest_file = $null; newest_time = $null; copied_time = $null; copied_file = $null; count = 0; size = 0; free = 0; total = 0; last_seen = $null; last_scan = $null; error = '' } }
function SamePath($a, $b) { if (-not $a -or -not $b) { return $false }; $a = ([string]$a).TrimEnd('\').ToLower(); $b = ([string]$b).TrimEnd('\').ToLower(); return ($a -eq $b) -or $a.StartsWith("$b\") -or $b.StartsWith("$a\") }
$usbs = @(); $usb = $null
if ($conf['USB'] -ne '0') {
  $prevList = @(); try { if (Test-Path $UsbState) { $pj = Get-Content $UsbState -Raw -Encoding UTF8 | ConvertFrom-Json; if ($pj.items) { $prevList = @($pj.items) } elseif ($pj.drive -ne $null -or $pj.last_seen -ne $null) { $prevList = @($pj) } } } catch {}
  $spec = $conf['USB']; if (-not $spec -or $spec -eq 'auto') { $spec = $remote['USB_PATHS'] }
  $logical = @(); try { $logical = @(Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 -or $_.DriveType -eq 3 }) } catch {}
  $sysLetters = @('C:', 'D:'); foreach ($p in $paths) { if ($p -match '^([A-Za-z]:)') { $sysLetters += $matches[1].ToUpper() } }
  # 확인할 대상 목록: @{ name; drive; path }
  $targets = @()
  if ($spec -and $spec -ne 'auto') {
    foreach ($ent in @($spec -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
      $name = ''; $loc = $ent
      if ($ent -match '^([^=]+?)\s*=\s*(.+)$') { $name = $matches[1].Trim(); $loc = $matches[2].Trim() }
      $loc = $loc.TrimEnd('\'); $drive = $null; $sub = ''
      if ($loc -match '^([A-Za-z]):(\\.*)?$') { $drive = ($matches[1] + ':').ToUpper(); $sub = [string]$matches[2] }
      elseif ($loc -match '^([^\\:]+):(\\.*)?$') { $lab = $matches[1]; $sub = [string]$matches[2]; $ld = $logical | Where-Object { $_.VolumeName -and $_.VolumeName.ToLower() -eq $lab.ToLower() } | Select-Object -First 1; if ($ld) { $drive = $ld.DeviceID } }
      elseif ($loc -match '^\\\\') { $drive = ''; $sub = $loc }   # UNC 경로도 허용
      if (-not $name) { $name = $(if ($sub -and $sub -ne '\') { Split-Path $sub -Leaf } elseif ($loc -match '^([^\\:]{2,}):') { $matches[1] } else { $loc }) }
      $targets += @{ name = $name; spec = $loc; drive = $drive; path = $(if ($drive -eq $null) { '' } elseif ($sub -and $sub -ne '\') { "$drive$sub" } else { "$drive\" }) }
    }
  } else {
    # 자동 감지: USB 인터페이스 디스크 > 이동식 > C:/D: 가 아니면서 backup/bak/db 폴더가 있는 드라이브
    $letters = @()
    try {
      foreach ($dd in @(Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' -or $_.PNPDeviceID -match 'USBSTOR|USB' })) {
        foreach ($part in @(Get-CimAssociatedInstance -InputObject $dd -ResultClassName Win32_DiskPartition)) {
          foreach ($ld in @(Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk)) { $letters += $ld.DeviceID }
        }
      }
      foreach ($ld in $logical) {
        $L = $ld.DeviceID
        if ($letters -contains $L -or $sysLetters -contains $L) { continue }
        if ($ld.DriveType -eq 2 -and $ld.Size -gt 4GB) { $letters += $L; continue }
        try { if (@(Get-ChildItem -Path "$L\" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'backup|bak|db' }).Count -gt 0) { $letters += $L } } catch {}
      }
    } catch { Log "USB 감지 오류: $($_.Exception.Message)" }
    $letters = @($letters | Sort-Object -Unique | Where-Object { Test-Path "$_\" })
    $pick = $null; $pickPath = ''
    foreach ($L in $letters) {
      $cands = @(); try { $cands = @(Get-ChildItem -Path "$L\" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'backup|bak|db' }) } catch {}
      if ($cands.Count -gt 0) { $pick = $L; $pickPath = ($cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; break }
      if (-not $pick) { $pick = $L; $pickPath = "$L\" }
    }
    $targets += @{ name = ''; spec = 'auto'; drive = $pick; path = $pickPath }
  }
  # bat 파일이 복사 직후 usb-done.ps1 을 호출했으면 그 기록(완료 시각, 복사 결과)을 읽어 둔다 (경로별 여러 건)
  $dones = @(); try { if (Test-Path $UsbDone) { $dj = Get-Content $UsbDone -Raw -Encoding UTF8 | ConvertFrom-Json; if ($dj.items) { $dones = @($dj.items) } elseif ($dj.time) { $dones = @($dj) } } } catch {}
  foreach ($tg in $targets) {
    $u = NewUsb $tg.name
    $prev = $prevList | Where-Object { $_.name -eq $tg.name } | Select-Object -First 1
    if (-not $prev -and $tg.spec -eq 'auto' -and $prevList.Count -gt 0) { $prev = $prevList[0] }
    if (-not $prev) { $prev = $prevList | Where-Object { $tg.path -and (SamePath $_.path $tg.path) } | Select-Object -First 1 }
    if ($prev) { foreach ($k in @('drive', 'label', 'path', 'newest_file', 'newest_time', 'copied_time', 'copied_file', 'count', 'size', 'free', 'total', 'last_seen', 'last_scan')) { try { if ($prev.$k -ne $null) { $u[$k] = $prev.$k } } catch {} } }
    $u.spec = $tg.spec
    $present = $false
    if ($tg.drive -and (Test-Path "$($tg.drive)\")) { $present = $true } elseif ($tg.drive -eq '' -and $tg.path) { try { $present = Test-Path $tg.path } catch {} }
    if ($present) {
      $u.connected = $true; $u.drive = $tg.drive; $u.path = $tg.path; $u.last_seen = Iso (Get-Date)
      $ld = $logical | Where-Object { $_.DeviceID -eq $tg.drive } | Select-Object -First 1
      if ($ld) { $u.label = [string]$ld.VolumeName; $u.free = [int64]$ld.FreeSpace; $u.total = [int64]$ld.Size }
      if ($tg.path -and -not (Test-Path $tg.path)) { $u.error = "폴더 없음: $($tg.path)"; $u.count = 0; $u.newest_file = $null; $u.newest_time = $null; $u.copied_time = $null }
      else {
        # 폴더 훑기(무거움)는 확인 시간대 안이거나, 새 드라이브가 꽂혔거나, 마지막 훑은 지 1시간이 넘었을 때만
        $lastScan = $null; try { if ($u.last_scan) { $lastScan = [datetime]::Parse($u.last_scan) } } catch {}
        $newDrive = (-not $prev) -or ($prev.drive -ne $tg.drive) -or ($prev.path -ne $tg.path)
        if ($ForceUsb -or $inWindow -or $newDrive -or (-not $lastScan) -or (((Get-Date) - $lastScan).TotalMinutes -ge 60)) {
          $scan = ScanFolder $tg.path $(if ($tg.path -match '^[A-Z]:\\$') { 3 } else { 0 })
          $u.newest_file = $scan.newest_file; $u.newest_time = $scan.newest_time; $u.copied_time = $scan.copied_time; $u.copied_file = $scan.copied_file; $u.count = $scan.count; $u.size = $scan.size; $u.last_scan = Iso (Get-Date)
          if ($scan.error) { $u.error = $scan.error }
        }
      }
    } elseif ($tg.spec -ne 'auto' -and -not $tg.drive -and -not $tg.path) { $u.error = "USB 를 찾지 못함: $($tg.spec)" }
    # 완료 기록 합치기: 경로가 같은(포함 관계) 기록, 자동 감지면 가장 최근 기록
    $dn = $null
    if ($tg.spec -eq 'auto') { $dn = $dones | Sort-Object time -Descending | Select-Object -First 1 }
    else { $dn = $dones | Where-Object { (SamePath $_.path $tg.path) -or ($tg.spec -and (SamePath $_.path $tg.spec)) } | Sort-Object time -Descending | Select-Object -First 1 }
    if ($dn) {
      try {
        $u.done_time = $dn.time; $u.done_code = $dn.code; $u.done_ok = $dn.ok
        if ($dn.newest_time -and -not $u.newest_time) { $u.newest_time = $dn.newest_time }
        if ($dn.newest_time -and $dn.time -gt $u.last_seen) { $u.newest_time = $dn.newest_time; $u.newest_file = $dn.newest_file; $u.count = $dn.count; $u.free = $dn.free; $u.total = $dn.total; $u.drive = $dn.drive; $u.path = $dn.path; $u.last_seen = $dn.time }
        if ($dn.copied_time -and ($dn.copied_time -gt $u.copied_time)) { $u.copied_time = $dn.copied_time }
      } catch {}
    }
    $usbs += $u
  }
  try { @{ items = @($usbs | ForEach-Object { $x = @{}; foreach ($k in @('name', 'drive', 'label', 'path', 'newest_file', 'newest_time', 'copied_time', 'copied_file', 'count', 'size', 'free', 'total', 'last_seen', 'last_scan')) { $x[$k] = $_[$k] }; $x }) } | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $UsbState -Encoding UTF8 } catch {}
  if ($usbs.Count -gt 0) { $usb = $usbs[0] }   # 구버전 수집기 호환 (첫 번째 USB)
}

$result = @{ time = Iso (Get-Date); files = @($files); sql = $sql; usb = $usb; usbs = @($usbs) }
try { $result | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $Out -Encoding UTF8 } catch { Log "저장 실패: $($_.Exception.Message)" }
