# 보안 감시 (agent.ps1 이 1분마다 별도 프로세스로 실행). 결과는 %ProgramData%\IMSMonitoringAgent\security.json
#  - 이벤트 로그: 보안 로그 삭제, 계정 생성·관리자 그룹 추가, 로그인 실패 폭주, 원격 데스크톱 접속(처음 보는 PC·외부 IP),
#    새 서비스·예약 작업, 위험 명령(섀도 복사본 삭제·BitLocker 켜기·로그 지우기 등 — 4688), Defender 탐지·꺼짐
#  - 미끼 파일(드라이브마다 !IMS-canary 폴더), BitLocker 상태 변화, 섀도 복사본 개수
#  - 하루 한 번 감사 정책(프로세스 생성·예약 작업 등)과 보안 로그 크기를 맞춘다 (agent.conf SEC_AUDIT=0 이면 안 함)
# agent.conf: SEC_CANARY=D:\공유;E:\자료 (미끼 폴더를 만들 곳, 0 = 안 만듦) · SEC_FAIL=20 (1분에 이만큼 로그인 실패하면 알림)
param([string]$ConfPath = '')
$ErrorActionPreference = 'SilentlyContinue'
$Ver = '1.9.0'
$DataDir = Join-Path $env:ProgramData 'IMSMonitoringAgent'
$Out = Join-Path $DataDir 'security.json'
$StFile = Join-Path $DataDir 'security-state.json'
$LogFile = Join-Path $DataDir 'agent.log'
try { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null } catch {}
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [보안] {1}" -f (Get-Date), $m) } catch {} }
function Iso($d) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Cut([string]$s, [int]$n) { if (-not $s) { return '' }; $s = ($s -replace '\s+', ' ').Trim(); if ($s.Length -gt $n) { return $s.Substring(0, $n) + '…' }; return $s }

$conf = @{}
if ($ConfPath -and (Test-Path $ConfPath)) { foreach ($line in Get-Content $ConfPath) { if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $conf[$matches[1].ToUpper()] = $matches[2] } } }
$FailWarn = 20; if ($conf['SEC_FAIL'] -match '^\d+$') { $FailWarn = [math]::Max(3, [int]$conf['SEC_FAIL']) }

# ---- 지난번 상태 ----
$st = $null
try { if (Test-Path $StFile) { $st = Get-Content $StFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
function P($o, $k) { if ($o -and ($o.PSObject.Properties.Name -contains $k)) { return $o.$k }; return $null }
$first = -not $st
$S = @{ ids = @(P $st 'ids'); rdp = @(P $st 'rdp' | Where-Object { $_ }); events = @(P $st 'events' | Where-Object { $_ }); fails = @(P $st 'fails' | Where-Object { $_ })
        auditDay = [string](P $st 'auditDay'); auditOk = (P $st 'auditOk'); blAvail = (P $st 'blAvail'); vss = (P $st 'vss'); failAt = [string](P $st 'failAt'); guardAt = [string](P $st 'guardAt'); canary = @{}; bl = @{}; guard = @{} }
$c = P $st 'canary'; if ($c) { foreach ($p in $c.PSObject.Properties) { $S.canary[$p.Name] = [string]$p.Value } }
$c = P $st 'bl'; if ($c) { foreach ($p in $c.PSObject.Properties) { $S.bl[$p.Name] = [string]$p.Value } }
$c = P $st 'guard'; if ($c) { foreach ($p in $c.PSObject.Properties) { $S.guard[$p.Name] = [string]$p.Value } }

$now = Get-Date
$lastExact = $now.AddMinutes(-3)                       # 처음이면 3분 전부터
try { $l = [datetime]::Parse([string](P $st 'last')); if ($l -gt $now.AddHours(-6) -and $l -lt $now) { $lastExact = $l } } catch {}
$since = $lastExact.AddSeconds(-20)                    # 늦게 기록된 이벤트를 놓치지 않게 조금 겹쳐 읽고, 같은 이벤트는 번호로 거른다

$New = New-Object System.Collections.ArrayList
$idSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($i in $S.ids) { if ($i) { [void]$idSet.Add([string]$i) } }
function Add-Ev([string]$id, [string]$sev, [string]$kind, [string]$msg, $time) {
  if (-not $id -or $idSet.Contains($id)) { return }
  [void]$idSet.Add($id)
  if (-not $time) { $time = Get-Date }
  [void]$New.Add([ordered]@{ id = $id; t = (Iso $time); sev = $sev; kind = $kind; msg = (Cut $msg 400) })
}
function EvData($e) { $d = @{}; try { $x = [xml]$e.ToXml(); foreach ($n in @($x.Event.EventData.Data)) { if ($n -and $n.Name) { $d[[string]$n.Name] = [string]$n.'#text' } } } catch {}; return $d }
function Q([string]$log, $ids, [int]$max) {
  try { return @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = $ids; StartTime = $since } -MaxEvents $max -ErrorAction Stop) } catch { return @() }
}
function SidName([string]$sid) { try { return (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return $sid } }
function IsPrivate([string]$ip) {
  $ip = ($ip -replace '^::ffff:', '')
  if (-not $ip -or $ip -eq '-' -or $ip -eq '::1' -or $ip -like '127.*' -or $ip -like 'fe80*') { return $true }
  return ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.)')
}

# ---- 감사 정책 (하루 한 번) ----
$today = $now.ToString('yyyy-MM-dd')
if ($conf['SEC_AUDIT'] -ne '0' -and $S.auditDay -ne $today) {
  $bad = 0
  # 하위 범주 GUID (한글 윈도우에서도 같음): 프로세스 생성, 기타 개체 액세스(예약 작업), 로그온, 사용자 계정 관리, 보안 그룹 관리
  foreach ($g in @('{0CCE922B-69AE-11D9-BED3-505054503030}', '{0CCE9227-69AE-11D9-BED3-505054503030}')) { & auditpol.exe /set "/subcategory:$g" /success:enable 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { $bad++ } }
  foreach ($g in @('{0CCE9215-69AE-11D9-BED3-505054503030}', '{0CCE9235-69AE-11D9-BED3-505054503030}', '{0CCE9237-69AE-11D9-BED3-505054503030}')) { & auditpol.exe /set "/subcategory:$g" /success:enable /failure:enable 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { $bad++ } }
  try {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    Set-ItemProperty -Path $k -Name 'ProcessCreationIncludeCmdLine_Enabled' -Value 1 -Type DWord -ErrorAction Stop   # 4688 에 명령줄까지 남기기
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'SCENoApplyLegacyAuditPolicy' -Value 1 -Type DWord -ErrorAction Stop
  } catch { $bad++ }
  try { $sl = Get-WinEvent -ListLog Security -ErrorAction Stop; if ($sl.MaximumSizeInBytes -lt 256MB) { & wevtutil.exe sl Security /ms:268435456 2>&1 | Out-Null } } catch {}
  $S.auditOk = ($bad -eq 0); $S.auditDay = $today
  Log "감사 정책 확인: $(if ($bad -eq 0) { '정상' } else { "$bad 항목 실패 (도메인 정책이 막고 있을 수 있음)" })"
}

# ---- 보안 로그 ----
$secReadable = $true
try { Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop | Out-Null } catch { $secReadable = $false }
foreach ($e in @(Q 'Security' @(1102, 4720, 4728, 4732, 4756, 4698) 500)) {
  $id = "S:$($e.RecordId)"; $t = $e.TimeCreated; $d = EvData $e
  if ($e.Id -eq 1102) {
    $u = ''; try { $u = ([xml]$e.ToXml()).Event.UserData.LogFileCleared.SubjectUserName } catch {}
    Add-Ev $id 'crit' 'tamper' "보안 로그가 지워졌습니다 (계정 $u) — 흔적 지우기 의심" $t
  } elseif ($e.Id -eq 4720) {
    Add-Ev $id 'warn' 'account' "새 계정 생성: $($d.TargetUserName) (만든 계정 $($d.SubjectUserName))" $t
  } elseif ($e.Id -eq 4698) {
    $tn = [string]$d.TaskName
    if ($tn -notmatch '^\\Microsoft\\' -and $tn -notmatch 'IMSMonitoring|ServerMonitor') {
      $cmd = ''; if ([string]$d.TaskContent -match '<Command>([^<]+)</Command>') { $cmd = " → $($matches[1])" }
      Add-Ev $id 'warn' 'persist' "새 예약 작업 등록: $tn$cmd (계정 $($d.SubjectUserName))" $t
    }
  } else {
    $sid = [string]$d.TargetSid
    $adm = ($sid -eq 'S-1-5-32-544') -or ($sid -match '-(512|518|519)$')
    if ($adm -or $sid -eq 'S-1-5-32-555') {
      $m = [string]$d.MemberName; if (-not $m -or $m -eq '-') { $m = SidName ([string]$d.MemberSid) }
      Add-Ev $id $(if ($adm) { 'crit' } else { 'warn' }) 'account' "$(if ($adm) { '관리자' } else { '원격 데스크톱' }) 그룹에 추가: $m → $($d.TargetUserName) (한 계정 $($d.SubjectUserName))" $t
    }
  }
}

# 로그인 실패 (무작위 대입): 1분 안에 SEC_FAIL 회 이상, 또는 10분 합계가 그 3배 이상. 같은 알림은 30분에 한 번
$fl = @(Q 'Security' @(4625) 5000 | Where-Object { $_.TimeCreated -gt $lastExact })
$byIp = @{}; $byUser = @{}
foreach ($e in $fl) {
  $ip = ''; $u = ''
  try { if ($e.Properties.Count -gt 19) { $u = [string]$e.Properties[5].Value; $ip = [string]$e.Properties[19].Value } } catch {}
  if (-not $ip -or $ip -eq '-') { $ip = '로컬' }
  $byIp[$ip] = 1 + [int]$byIp[$ip]; if ($u) { $byUser[$u] = 1 + [int]$byUser[$u] }
}
$fails = @($S.fails | Where-Object { try { [datetime]::Parse(($_ -split '\|')[0]) -gt $now.AddMinutes(-10) } catch { $false } })
if ($fl.Count) { $fails += "$(Iso $now)|$($fl.Count)" }
$S.fails = $fails
$sum10 = 0; foreach ($f in $fails) { $sum10 += [int](($f -split '\|')[1]) }
if ($fl.Count -ge $FailWarn -or $sum10 -ge $FailWarn * 3) {
  $quiet = $false; try { $quiet = [datetime]::Parse($S.failAt) -gt $now.AddMinutes(-30) } catch {}
  if (-not $quiet) {
    $top = ($byIp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', '
    $tu = ($byUser.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', '
    $ext = @($byIp.Keys | Where-Object { -not (IsPrivate $_) }).Count -gt 0
    Add-Ev "F:$($now.ToString('yyyyMMddHHmm'))" $(if ($fl.Count -ge 100 -or $ext) { 'crit' } else { 'warn' }) 'login' "로그인 실패 $($fl.Count)회 (최근 1분, 10분 합계 $sum10회) — 비밀번호 대입 공격 의심 · 보낸 곳: $top · 계정: $tu"
    $S.failAt = Iso $now
  }
}

# 원격 데스크톱 로그인 (로그온 유형 10): 외부 IP 면 위험, 처음 보는 PC 면 주의, 나머지는 기록만
$rdpFrom = $since; if ($first) { $rdpFrom = $now.AddDays(-30) }   # 처음에는 지난 30일 접속 PC 를 "아는 PC" 로 익혀 둔다
$xp = "*[System[(EventID=4624) and TimeCreated[@SystemTime>='$($rdpFrom.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))']]] and *[EventData[Data[@Name='LogonType']='10']]"
$rl = @(); try { $rl = @(Get-WinEvent -LogName Security -FilterXPath $xp -MaxEvents 2000 -ErrorAction Stop) } catch {}
[array]::Reverse($rl)                                  # 오래된 것부터
foreach ($e in $rl) {
  $d = EvData $e; $ip = ([string]$d.IpAddress -replace '^::ffff:', ''); $u = "$($d.TargetDomainName)\$($d.TargetUserName)"
  if ($first) { if ($ip -and $S.rdp -notcontains $ip) { $S.rdp += $ip }; continue }
  $id = "S:$($e.RecordId)"
  if (-not (IsPrivate $ip)) { Add-Ev $id 'crit' 'login' "외부 IP 에서 원격 데스크톱 접속: $u ($ip)" $e.TimeCreated }
  elseif ($ip -and $S.rdp -notcontains $ip) { Add-Ev $id 'warn' 'login' "처음 보는 PC 에서 원격 데스크톱 접속: $u ($ip)" $e.TimeCreated; $S.rdp += $ip }
  else { Add-Ev $id 'info' 'login' "원격 데스크톱 접속: $u ($ip)" $e.TimeCreated }
}
$S.rdp = @($S.rdp | Select-Object -Last 200)

# 위험 명령 (프로세스 생성 4688 — 감사 정책에서 켜고 명령줄까지 남김)
$Bad = @(
  @('vssadmin.*(delete\s+shadows|resize\s+shadowstorage)', 'crit', 'ransom', '섀도 복사본 삭제 명령'),
  @('shadowcopy.*delete|win32_shadowcopy.*(delete|remove)', 'crit', 'ransom', '섀도 복사본 삭제 명령'),
  @('wbadmin.*delete\s+(catalog|systemstatebackup|backup)', 'crit', 'ransom', '윈도우 백업 삭제 명령'),
  @('bcdedit.*(recoveryenabled\s+(no|off)|ignoreallfailures)', 'crit', 'ransom', '복구 모드 끄기 명령'),
  @('manage-bde.*(\s-on\b|-protectors\s+-add|\s-lock\b|-changepassword|-forcerecovery)|enable-bitlocker|add-bitlockerkeyprotector', 'crit', 'bitlocker', 'BitLocker 켜기·암호 추가 명령'),
  @('(install-windowsfeature|add-windowsfeature|enable-windowsoptionalfeature|dism).*bitlocker', 'crit', 'bitlocker', 'BitLocker 기능 설치 명령'),
  @('wevtutil(\.exe)?"?\s+(cl|clear-log)\s', 'crit', 'tamper', '이벤트 로그 지우기 명령'),
  @('set-mppreference.*-disable(realtimemonitoring|behaviormonitoring|ioavprotection|scriptscanning)', 'crit', 'tamper', 'Defender 끄기 명령'),
  @('cipher(\.exe)?"?\s+/w', 'warn', 'ransom', '빈 공간 덮어쓰기(cipher /w) 명령'),
  @('net1?(\.exe)?"?\s+localgroup\s+"?administrators"?\s+.*/add', 'crit', 'account', '관리자 그룹 추가 명령'),
  @('net1?(\.exe)?"?\s+user\s+\S+\s+\S+.*/add', 'warn', 'account', '계정 만들기 명령')
)
$blCmd = $false; $guardT = $null; try { $guardT = [datetime]::Parse($S.guardAt) } catch {}
foreach ($e in @(Q 'Security' @(4688) 8000 | Where-Object { $_.TimeCreated -gt $lastExact })) {
  $img = ''; $cmd = ''; $who = ''; $sid = ''
  try { $sid = [string]$e.Properties[0].Value; $who = [string]$e.Properties[1].Value; $img = [string]$e.Properties[5].Value; $cmd = [string]$e.Properties[8].Value } catch {}
  if ($guardT -and $sid -eq 'S-1-5-18' -and $img -match '\\manage-bde\.exe$' -and [math]::Abs(($e.TimeCreated - $guardT).TotalMinutes) -lt 3) { continue }   # 자동 차단이 실행한 명령
  if ($img -notmatch '\\(vssadmin|wmic|wbadmin|bcdedit|manage-bde|cipher|wevtutil|powershell|pwsh|cmd|net1?|dism)\.exe$') { continue }
  $txt = "$cmd"; if (-not $txt) { continue }
  foreach ($b in $Bad) { if ($txt -match $b[0]) { Add-Ev "S:$($e.RecordId)" $b[1] $b[2] "$($b[3]): $(Cut $txt 220) (계정 $who)" $e.TimeCreated; if ($b[2] -eq 'bitlocker') { $blCmd = $true }; break } }
}

# ---- 시스템 로그: 새 서비스, 로그 지우기 ----
foreach ($e in @(Q 'System' @(7045, 104) 300)) {
  $id = "Y:$($e.RecordId)"
  if ($e.Id -eq 104) { Add-Ev $id 'crit' 'tamper' '이벤트 로그가 지워졌습니다 — 흔적 지우기 의심' $e.TimeCreated; continue }
  $d = EvData $e
  if ([string]$d.ServiceName -match '^MpKsl') { continue }   # Defender 가 수시로 올리는 드라이버
  Add-Ev $id 'warn' 'persist' "새 서비스 설치: $($d.ServiceName) ($(Cut ([string]$d.ImagePath) 160), 계정 $($d.AccountName))" $e.TimeCreated
}

# ---- Defender ----
foreach ($e in @(Q 'Microsoft-Windows-Windows Defender/Operational' @(1116, 1117, 5001, 5010, 5012) 100)) {
  $id = "D:$($e.RecordId)"; $d = EvData $e
  switch ($e.Id) {
    1116 { Add-Ev $id 'crit' 'malware' "악성코드 탐지: $($d.'Threat Name') ($(Cut ([string]$d.Path) 160))" $e.TimeCreated }
    1117 { Add-Ev $id 'info' 'malware' "악성코드 조치: $($d.'Threat Name') — $($d.'Action Name')" $e.TimeCreated }
    5001 { Add-Ev $id 'crit' 'tamper' 'Defender 실시간 보호가 꺼졌습니다' $e.TimeCreated }
    default { Add-Ev $id 'warn' 'tamper' 'Defender 검사 기능이 꺼졌습니다' $e.TimeCreated }
  }
}
$def = $null
try { $mp = Get-MpComputerStatus -ErrorAction Stop; $def = [ordered]@{ on = [bool]$mp.AntivirusEnabled; rt = [bool]$mp.RealTimeProtectionEnabled; sig = [int]$mp.AntivirusSignatureAge } } catch {}

# ---- 미끼 파일 ----
# 드라이브마다 !IMS-canary 폴더에 흔한 문서 이름의 파일을 두고, 바뀌거나 지워지거나 새 파일이 생기면 위험 알림 (평소엔 아무도 안 건드림)
$CanaryName = '!IMS-canary'
$CanaryFiles = @('0_급여대장.xlsx', '0_계약서.docx', '0_회계자료.pdf', '0_사진.jpg', '0_업무자료.txt', '_이 폴더는 지우지 마세요.txt')
$roots = @()
if ($conf['SEC_CANARY'] -eq '0') { $roots = @() }
elseif ($conf['SEC_CANARY']) { $roots = @($conf['SEC_CANARY'] -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ } | ForEach-Object { "$_\$CanaryName" }) }
else { $roots = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { "$($_.DeviceID)\$CanaryName" }) + @("$env:PUBLIC\Documents\$CanaryName") }
function Hash([string]$p) { $fs = $null; try { $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite'); $h = [Security.Cryptography.SHA256]::Create(); return [BitConverter]::ToString($h.ComputeHash($fs)) -replace '-', '' } catch { return 'ERR' } finally { if ($fs) { $fs.Close() } } }
function New-Canary([string]$dir) {
  try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { return }
  $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
  foreach ($n in $CanaryFiles) {
    $p = Join-Path $dir $n; if (Test-Path -LiteralPath $p) { continue }
    try {
      if ($n -like '_*') { Set-Content -LiteralPath $p -Encoding UTF8 -Value "랜섬웨어 감시용 미끼 파일입니다 (IMS 서버 모니터링).`r`n이 폴더의 파일을 열거나 고치거나 지우면 '보안 위험' 알림이 갑니다. 그대로 두세요." }
      else { $b = New-Object byte[] (8192 + (Get-Random -Maximum 24576)); $rng.GetBytes($b); [IO.File]::WriteAllBytes($p, $b) }
    } catch {}
  }
}
$canaryOk = $true; $canaryN = 0
foreach ($dir in $roots) {
  try {
    $pre = $dir + '\'
    $known = @($S.canary.Keys | Where-Object { $_.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) })
    $chg = @()
    if (-not (Test-Path -LiteralPath $dir)) {
      if ($known.Count) { $chg += '폴더가 사라짐' }
      foreach ($k in $known) { $S.canary.Remove($k) }; $known = @()
    }
    $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)
    if ($known.Count) {
      foreach ($f in $files) { if (-not $S.canary.ContainsKey($f.FullName)) { $chg += "새 파일 $($f.Name)" } elseif ($S.canary[$f.FullName] -ne (Hash $f.FullName)) { $chg += "바뀜 $($f.Name)" } }
      foreach ($k in $known) { if (-not (Test-Path -LiteralPath $k)) { $chg += "없어짐 $(Split-Path $k -Leaf)" } }
    }
    if ($chg.Count) {
      $canaryOk = $false
      Add-Ev "C:$($dir):$($now.ToString('yyyyMMddHHmmss'))" 'crit' 'ransom' "미끼 파일이 바뀌었습니다 ($dir): $(($chg | Select-Object -First 6) -join ', ')$(if ($chg.Count -gt 6) { " 외 $($chg.Count - 6)개" }) — 랜섬웨어 의심, 즉시 확인"
    }
    if ($chg.Count -or -not $known.Count) {                # 처음이거나 바뀐 뒤에는 다시 만들고 새로 기억 (새로 생긴 파일은 증거로 그대로 둔다)
      New-Canary $dir
      foreach ($k in $known) { $S.canary.Remove($k) }
      foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) { $S.canary[$f.FullName] = Hash $f.FullName }
    }
    $canaryN += @($S.canary.Keys | Where-Object { $_.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) }).Count
  } catch {}
}
foreach ($k in @($S.canary.Keys)) { $keep = $false; foreach ($dir in $roots) { if ($k.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) { $keep = $true } }; if (-not $keep) { $S.canary.Remove($k) } }

# ---- BitLocker ----
# 평소 안 쓰는 서버에서 암호화가 시작되거나 키(암호)가 추가되면 BitLocker 랜섬웨어 의심.
# 자동 차단(기본 켬, 서버 현황 → 🛡 보안 에서 서버별로 끔 · agent.conf SEC_BL_GUARD=0/1 이 우선):
#   암호화를 멈추고(manage-bde -pause) 우리 복구키를 추가해 bl-escrow.json(SYSTEM·관리자만 읽기) → 수집기에 보관,
#   공격자가 걸어 둔 재부팅 예약은 취소(shutdown /a). 이후에도 1분마다 다시 시작되거나 우리 키가 지워지면 또 막는다.
$rc = @{}; $rcPath = Join-Path $DataDir 'remote.conf'
if (Test-Path $rcPath) { foreach ($line in Get-Content $rcPath) { if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $rc[$matches[1].ToUpper()] = $matches[2] } } }
$Guard = $rc['BL_GUARD'] -ne '0'
if ($conf['SEC_BL_GUARD'] -eq '0') { $Guard = $false } elseif ($conf['SEC_BL_GUARD'] -eq '1') { $Guard = $true }
$EscFile = Join-Path $DataDir 'bl-escrow.json'
function RecIds([string]$m) {
  try { $o = (& manage-bde.exe -protectors -get $m -Type RecoveryPassword 2>&1 | Out-String); return @([regex]::Matches($o, '\{[0-9A-Fa-f-]{36}\}') | ForEach-Object { $_.Value.ToUpper() } | Select-Object -Unique) } catch { return @() }
}
function Save-Escrow($item) {
  $list = @(); try { if (Test-Path $EscFile) { $list = @((Get-Content $EscFile -Raw -Encoding UTF8 | ConvertFrom-Json).items | Where-Object { $_ }) } } catch {}
  $list = @(, $item) + @($list | Select-Object -First 19)
  try { @{ items = $list } | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $EscFile -Encoding UTF8 } catch {}
  try { & icacls.exe $EscFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' 2>&1 | Out-Null } catch {}
}
function Guard-Volume([string]$m, [int]$conv, [string]$why) {
  $done = @(); $script:S.guardAt = Iso (Get-Date)
  if ($conv -eq 2) { & manage-bde.exe -pause $m 2>&1 | Out-Null; $done += $(if ($LASTEXITCODE -eq 0) { '암호화 멈춤' } else { '멈추기 실패' }) }
  $have = @(RecIds $m); $mine = [string]$S.guard[$m]
  if (-not $mine -or $have -notcontains $mine) {
    $o = (& manage-bde.exe -protectors -add $m -RecoveryPassword 2>&1 | Out-String)
    $pw = [regex]::Match($o, '\d{6}(-\d{6}){7}').Value
    $new = [string](@(RecIds $m | Where-Object { $have -notcontains $_ }) | Select-Object -First 1)
    if ($pw) { $S.guard[$m] = $new; Save-Escrow ([ordered]@{ m = $m; id = $new; pw = $pw; t = (Iso (Get-Date)); why = (Cut $why 120) }); $done += '복구키 추가·보관' }
    else { $done += "복구키 추가 실패 ($(Cut $o 100))" }
  }
  & shutdown.exe /a 2>&1 | Out-Null                    # 재부팅 예약 취소 (예약이 없으면 아무 일 없음)
  Log "BitLocker 자동 차단 $m : $($done -join ', ') ($why)"
  return ($done -join ', ')
}
$blAvail = $false; $vols = @()
try { $vols = @(Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop); $blAvail = $true } catch {}
if ($blAvail -and $S.blAvail -eq $false) { Add-Ev "B:avail:$($now.ToString('yyyyMMddHHmm'))" 'warn' 'bitlocker' 'BitLocker 기능이 새로 생겼습니다 — 설치한 적이 없다면 확인하세요' }
function Read-Vol($v) {
  $r = @{ conv = -1; pct = 0; keys = 0; prot = 0 }
  try { $v2 = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DeviceID='$($v.DeviceID -replace '\\', '\\')'" -ErrorAction Stop; if ($v2) { $v = $v2 } } catch {}
  $r.prot = [int]$v.ProtectionStatus
  try { $cs = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus -ErrorAction Stop; $r.conv = [int]$cs.ConversionStatus; $r.pct = [int]$cs.EncryptionPercentage } catch {}
  try { $kp = Invoke-CimMethod -InputObject $v -MethodName GetKeyProtectors -Arguments @{ KeyProtectorType = [uint32]0 } -ErrorAction Stop; $r.keys = @($kp.VolumeKeyProtectorID | Where-Object { $_ }).Count } catch {}
  return $r
}
$bl = @()
foreach ($v in $vols) {
  $m = [string]$v.DriveLetter; if (-not $m) { continue }
  $x = Read-Vol $v
  $prev = $S.bl[$m]
  if (-not $prev -and $S.blAvail -eq $false) { $prev = '0|0|0' }          # 기능이 막 생긴 서버: 예전엔 암호화 안 된 것으로 본다
  if (-not $prev -and $blCmd -and @(1, 2, 4) -contains $x.conv) { $prev = '0|0|0' }   # 이번에 BitLocker 명령을 봤는데 처음 보는 볼륨이 암호화 중
  if ($prev) {
    $pv = $prev -split '\|'; $pc = [int]$pv[0]; $pk = [int]$pv[1]; $pp = [int]$pv[2]
    $mine = [string]$S.guard[$m]
    $started = $pc -eq 0 -and @(1, 2, 4) -contains $x.conv
    $resumed = $Guard -and $mine -and $x.conv -eq 2
    $lost = $Guard -and $mine -and $x.conv -ne 0 -and (@(RecIds $m) -notcontains $mine)
    $keyAdd = $x.keys -gt $pk -and $x.conv -ne 0
    if ($started -or $resumed -or $lost -or $keyAdd) {
      $what = $(if ($started) { "BitLocker 암호화가 시작됐습니다: $m ($($x.pct)%)" } elseif ($lost) { "자동으로 넣어 둔 복구키가 지워졌습니다: $m — 공격이 계속되는 중일 수 있음" } elseif ($resumed) { "멈춘 BitLocker 암호화가 다시 시작됐습니다: $m ($($x.pct)%)" } else { "BitLocker 키(암호)가 추가됐습니다: $m ($pk → $($x.keys)개)" })
      $evid = "B:$($m):$(if ($started) { 'enc' } elseif ($lost) { 'lost' } elseif ($resumed) { 'resume' } else { 'key' }):$($now.ToString('yyyyMMddHHmmss'))"
      if ($Guard) {
        $res = Guard-Volume $m $x.conv $what
        Add-Ev $evid 'crit' 'bitlocker' "$what → 자동 차단: $res. 서버를 끄거나 재부팅하지 말고 바로 확인하세요 (복구키는 🛡 보안 창에 보관)"
        $x = Read-Vol $v                                                       # 우리가 넣은 키 때문에 다음에 "키 추가" 알림이 나지 않게 다시 읽는다
      } else {
        Add-Ev $evid 'crit' 'bitlocker' "$what — 직접 켠 게 아니면 BitLocker 랜섬웨어 의심, 즉시 확인 (이 서버는 자동 차단 꺼짐)"
      }
    } elseif ($pp -eq 0 -and $x.prot -eq 1) { Add-Ev "B:$($m):prot:$($now.ToString('yyyyMMddHHmm'))" 'warn' 'bitlocker' "BitLocker 보호가 켜졌습니다: $m" }
  }
  if ($x.conv -eq 0 -and $S.guard.ContainsKey($m)) { $S.guard.Remove($m) }    # 해독이 끝나면 잊는다
  $bl += [ordered]@{ m = $m; conv = $x.conv; pct = $x.pct; prot = $x.prot; keys = $x.keys; guarded = [bool]$S.guard[$m] }
  $S.bl[$m] = "$($x.conv)|$($x.keys)|$($x.prot)"
}
$S.blAvail = $blAvail

# ---- 섀도 복사본 ---- (3개 이상 있던 것이 절반 이하로 줄면 삭제 의심. 백업 프로그램이 잠깐 만드는 1~2개는 무시)
$vss = $null; try { $vss = @(Get-CimInstance Win32_ShadowCopy -ErrorAction Stop).Count } catch {}
if ($null -ne $vss -and $null -ne $S.vss -and [int]$S.vss -ge 3 -and $vss -le [math]::Floor([int]$S.vss / 2)) {
  Add-Ev "V:$($now.ToString('yyyyMMddHHmm'))" 'crit' 'ransom' "섀도 복사본(복구 지점)이 $($S.vss)개 → $vss개로 줄었습니다 — 삭제 의심"
}
$S.vss = $vss

# ---- 저장 ----
$cut = $now.AddDays(-3)
$all = @(@($New) + @($S.events) | Where-Object { $_ -and $_.t } | Where-Object { try { [datetime]::Parse($_.t) -gt $cut } catch { $false } } | Select-Object -First 40)
foreach ($e in $New) { Log "$($e.sev) $($e.msg)" }
$ids = @(@($New | ForEach-Object { $_.id }) + @($S.ids | Where-Object { $_ }) | Select-Object -First 600)
$state = [ordered]@{ last = $now.ToString('o'); ids = $ids; rdp = @($S.rdp); events = $all; fails = @($S.fails); failAt = $S.failAt
  auditDay = $S.auditDay; auditOk = $S.auditOk; blAvail = $S.blAvail; vss = $S.vss; canary = $S.canary; bl = $S.bl; guard = $S.guard; guardAt = $S.guardAt }
try { $state | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $StFile -Encoding UTF8 } catch {}
$o = [ordered]@{
  time = (Iso $now); ver = $Ver
  status = [ordered]@{ audit = $S.auditOk; logs = $secReadable; canary = [ordered]@{ dirs = @($roots); files = $canaryN; ok = $canaryOk }
    bitlocker = [ordered]@{ avail = $blAvail; guard = $Guard; vols = @($bl) }; vss = $vss; defender = $def; rdp_known = @($S.rdp).Count }
  events = $all
}
try { $o | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $Out -Encoding UTF8 } catch {}
