# IMS Monitoring Agent (설치 프로그램용)
# CPU/메모리/디스크/네트워크를 읽어 수집기로 전송합니다.
# 설정은 같은 폴더의 agent.conf 에서 읽고, 상태는 %ProgramData%\IMSMonitoringAgent\status.json 에 기록합니다.
param(
  [string]$Url = "",
  [int]$Interval = 0,
  [string]$Token = "",
  [string]$HostName = $env:COMPUTERNAME,
  [switch]$SkipCertCheck
)

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AgentVersion = "1.6.1"   # installer.nsi VERSION 과 같게 유지
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$StatusFile = Join-Path $DataDir "status.json"
$LogFile = Join-Path $DataDir "agent.log"
try { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null } catch {}

# agent.conf: URL=..., TOKEN=..., INTERVAL=5, SKIPCERT=0
$conf = @{}
$confPath = Join-Path $Dir "agent.conf"
if (Test-Path $confPath) {
  foreach ($line in Get-Content $confPath) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $conf[$matches[1].ToUpper()] = $matches[2] }
  }
}
if (-not $Url)      { $Url = $conf['URL'] }
if (-not $Token)    { $Token = $conf['TOKEN'] }
if ($Interval -le 0) { $Interval = [int]($conf['INTERVAL'] | ForEach-Object { if ($_) { $_ } else { 5 } }) }
if ($conf['SKIPCERT'] -eq '1') { $SkipCertCheck = $true }
if (-not $Url) { Write-Error "전송 주소(URL)가 없습니다. agent.conf 를 확인하세요."; exit 1 }

function Log([string]$msg) {
  $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg
  Write-Host $line
  try {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) { Move-Item -Force $LogFile ($LogFile + ".old") }
    Add-Content -Path $LogFile -Value $line
  } catch {}
}
function WriteStatus([bool]$ok, [string]$err, [double]$cpu, [int]$memPct) {
  try {
    @{ ok = $ok; time = (Get-Date).ToString('o'); error = $err; host = $HostName; url = $Url; cpu = $cpu; mem_pct = $memPct; interval = $Interval } |
      ConvertTo-Json -Compress | Set-Content -Path $StatusFile -Encoding UTF8
  } catch {}
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
if ($SkipCertCheck) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }

# 시작 직후 상태 파일부터 기록 (트레이가 "시작 중"으로 표시)
try { @{ ok = $false; starting = $true; time = (Get-Date).ToString('o'); error = '시작 중'; host = $HostName; url = $Url; interval = $Interval } | ConvertTo-Json -Compress | Set-Content -Path $StatusFile -Encoding UTF8 } catch {}
Log "에이전트 시작: $HostName -> $Url (간격 ${Interval}초)"

# 부팅 직후에는 WMI 가 준비 안 됐을 수 있으므로 될 때까지 재시도
$os = $null
for ($i = 0; $i -lt 40 -and -not $os; $i++) {
  try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { if ($i -eq 0) { Log "WMI 준비 대기: $($_.Exception.Message)" }; Start-Sleep -Seconds 15 }
}
if (-not $os) { Log "WMI 를 사용할 수 없어 종료합니다 (작업 스케줄러가 1분 뒤 재시작)"; exit 1 }
$osName = "$($os.Caption) $($os.Version)"

# 가동 시간 기준: Windows 가 실제로 켜진 시점.
# 빠른 시작(Fast Startup)으로 종료/시작하면 LastBootUpTime 이 갱신되지 않으므로
# 시스템 로그의 Kernel-Boot(ID 27) 이벤트(모든 시작마다 기록됨)와 비교해 더 최근 값을 쓴다.
function Get-StartTime {
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 27 } -MaxEvents 1 -ErrorAction Stop
    if ($ev -and $ev.TimeCreated -gt $boot) { $boot = $ev.TimeCreated }
  } catch {}
  return $boot
}
$startTime = try { Get-StartTime } catch { $os.LastBootUpTime }
$startChecked = Get-Date

# 표시 이름: 트레이 메뉴 "이름 설정" 이 %ProgramData%\IMSMonitoringAgent\display.conf 에 저장 (NAME=...)
$DisplayFile = Join-Path $DataDir "display.conf"
# Veeam 백업 서버면 veeam.ps1 을 10분마다 별도 프로세스로 실행해 결과(veeam.json)를 같이 보낸다
$VeeamScript = Join-Path $Dir "veeam.ps1"
$VeeamOut = Join-Path $DataDir "veeam.json"
$HasVeeam = (Test-Path $VeeamScript) -and ((Test-Path "$env:ProgramFiles\Veeam\Backup and Replication\Backup") -or (Test-Path "$env:ProgramFiles\Veeam\Backup and Replication\Console"))
$veeamLast = (Get-Date).AddHours(-1); $veeamProc = $null
if ($HasVeeam) { Log "Veeam 감지: 백업 작업 상태를 10분마다 수집합니다" }
# SQL 백업 폴더 / USB 복사 감시 (backup.ps1): 백업 폴더가 있거나 agent.conf 에 BACKUP_PATH/USB/SQL 이 있으면 5분마다
$BackupScript = Join-Path $Dir "backup.ps1"
$BackupOut = Join-Path $DataDir "backup.json"
$BackupPaths = @()
if ($conf['BACKUP_PATH']) { $BackupPaths = @($conf['BACKUP_PATH'] -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
else { foreach ($p in @('D:\DBBackup', 'D:\DB_BACKUP', 'C:\DBBackup', 'C:\DB_BACKUP')) { if (Test-Path $p) { $BackupPaths += $p } } }
$HasBackup = (Test-Path $BackupScript) -and ($BackupPaths.Count -gt 0 -or $conf['USB'] -or $conf['SQL'])
$backupLast = (Get-Date).AddHours(-1); $backupProc = $null
$knownDrives = $null; $usbBurstUntil = (Get-Date).AddMinutes(-1); $usbBurstLast = (Get-Date).AddMinutes(-1)   # USB 가 꽂히면 4분간 20초마다 확인 (3분 만에 자동 분리되는 경우 대비)
$RemoteConf = Join-Path $DataDir "remote.conf"; $remoteCache = ''   # 수집기 화면에서 정한 설정(USB 확인 시간대 등)을 받아 backup.ps1 에 전달
if ($HasBackup) { Log "백업 폴더 감지 ($($BackupPaths -join ', ')): SQL 백업 파일·USB 복사 상태를 5분마다 수집합니다" } else { Log "백업 폴더 없음 (D:\DBBackup 등): 백업 감시 안 함. 필요하면 agent.conf 에 BACKUP_PATH= 지정" }
function Get-DisplayName {
  try {
    if (Test-Path $DisplayFile) {
      foreach ($line in Get-Content $DisplayFile -Encoding UTF8) { if ($line -match '^\s*NAME\s*=\s*(.*?)\s*$') { return $matches[1] } }
    }
  } catch {}
  return ""
}

function Get-NetBytes {
  $s = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface | Where-Object { $_.Name -notmatch 'Loopback|isatap|Teredo' }
  [pscustomobject]@{ rx = ($s | Measure-Object BytesReceivedPersec -Sum).Sum; tx = ($s | Measure-Object BytesSentPersec -Sum).Sum }
}
$prevNet = Get-NetBytes
$prevT = Get-Date
$failStreak = 0

# CPU 사용률: Win32_PerfRawData_PerfOS_Processor(_Total) 의 유휴 시간 차이로 계산 (성능 카운터 cmdlet 미사용)
$script:prevCpuRaw = $null
function Get-CpuPercent {
  try {
    $p = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
    if ($p) {
      $cur = @{ idle = [double]$p.PercentProcessorTime; ts = [double]$p.Timestamp_Sys100NS }
      $prev = $script:prevCpuRaw; $script:prevCpuRaw = $cur
      if ($prev -and ($cur.ts - $prev.ts) -gt 0) {
        $v = 100.0 - (($cur.idle - $prev.idle) / ($cur.ts - $prev.ts)) * 100.0
        return [math]::Round([math]::Max(0, [math]::Min(100, $v)), 1)
      }
    }
  } catch {}
  try { return [double](Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average } catch { return 0 }
}
Get-CpuPercent | Out-Null   # 첫 샘플

while ($true) {
  Start-Sleep -Seconds $Interval
  try {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $tm = @{}
    $cpu = Get-CpuPercent; $tm.cpu = $sw.Elapsed.TotalSeconds
    $os = Get-CimInstance Win32_OperatingSystem
    $memTotal = [int64]$os.TotalVisibleMemorySize * 1024
    $memUsed = $memTotal - ([int64]$os.FreePhysicalMemory * 1024)
    $memPct = [int][math]::Round($memUsed * 100 / $memTotal)
    if (((Get-Date) - $startChecked).TotalMinutes -ge 10) { $startTime = Get-StartTime; $startChecked = Get-Date }
    $uptime = [int]((Get-Date) - $startTime).TotalSeconds
    $tm.mem = $sw.Elapsed.TotalSeconds - $tm.cpu

    $now = Get-Date
    $dt = [math]::Max(1, ($now - $prevT).TotalSeconds)
    $net = Get-NetBytes
    $netRx = [int64](($net.rx - $prevNet.rx) / $dt)
    $netTx = [int64](($net.tx - $prevNet.tx) / $dt)
    $prevNet = $net; $prevT = $now
    $tm.net = $sw.Elapsed.TotalSeconds - $tm.cpu - $tm.mem

    $allDrives = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=2 OR DriveType=3")
    if ($HasBackup) {
      # 새 드라이브 문자가 나타나면(USB 꽂힘) 즉시 + 4분 동안 20초마다 USB 상태 수집
      $cur = @($allDrives | ForEach-Object { $_.DeviceID })
      if ($null -ne $knownDrives) { foreach ($d in $cur) { if ($knownDrives -notcontains $d -and $d -ne 'C:' -and $d -ne 'D:') { Log "새 드라이브 감지: $d (USB 백업 확인 시작)"; $usbBurstUntil = (Get-Date).AddMinutes(4); $usbBurstLast = (Get-Date).AddMinutes(-1) } } }
      $knownDrives = $cur
    }
    $disks = $allDrives | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
      @{ mount = $_.DeviceID; total = [int64]$_.Size; used = [int64]$_.Size - [int64]$_.FreeSpace }
    }
    $tm.disk = $sw.Elapsed.TotalSeconds - $tm.cpu - $tm.mem - $tm.net
    $collectSec = $sw.Elapsed.TotalSeconds
    $backups = $null
    if ($HasVeeam) {
      if ((-not $veeamProc -or $veeamProc.HasExited) -and ((Get-Date) - $veeamLast).TotalMinutes -ge 10) {
        $veeamLast = Get-Date
        try { $veeamProc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$VeeamScript`"" -WindowStyle Hidden -PassThru; try { $veeamProc.PriorityClass = 'BelowNormal' } catch {} } catch { Log "Veeam 수집 실행 실패: $($_.Exception.Message)" }
      }
      try { if ((Test-Path $VeeamOut) -and ((Get-Date) - (Get-Item $VeeamOut).LastWriteTime).TotalHours -lt 3) { $backups = Get-Content $VeeamOut -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
    }
    if ($HasBackup) {
      $burst = ((Get-Date) -lt $usbBurstUntil) -and (((Get-Date) - $usbBurstLast).TotalSeconds -ge 20)
      if ((-not $backupProc -or $backupProc.HasExited) -and ($burst -or ((Get-Date) - $backupLast).TotalMinutes -ge 5)) {
        $backupLast = Get-Date; if ($burst) { $usbBurstLast = Get-Date }
        $extra = $(if ($burst) { ' -ForceUsb' } else { '' })
        try { $backupProc = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$BackupScript`" -ConfPath `"$confPath`"$extra" -WindowStyle Hidden -PassThru; try { $backupProc.PriorityClass = 'BelowNormal' } catch {} } catch { Log "백업 수집 실행 실패: $($_.Exception.Message)" }
      }
      try {
        if ((Test-Path $BackupOut) -and ((Get-Date) - (Get-Item $BackupOut).LastWriteTime).TotalHours -lt 2) {   # (usb 는 backup.ps1 이 usb-state/usb-done 을 합쳐 넣음)
          $bk = Get-Content $BackupOut -Raw -Encoding UTF8 | ConvertFrom-Json
          if (-not $backups) { $backups = New-Object PSObject; $backups | Add-Member NoteProperty time $bk.time }
          foreach ($k in @('files', 'sql', 'usb', 'usbs')) { if ($bk.$k -ne $null) { $backups | Add-Member NoteProperty $k $bk.$k -Force } }
          try { $cur = @($allDrives | ForEach-Object { $_.DeviceID }); foreach ($u in @(@($bk.usb) + @($bk.usbs))) { if ($u -and $u.connected -and $u.drive -and $cur -notcontains $u.drive) { $u.connected = $false } } } catch {}   # 빠진 뒤엔 '연결됨' 표시 안 함
        }
      } catch {}
    }
    $payload = @{
      host = $HostName; name = (Get-DisplayName); os = $osName; token = $Token
      cpu = $cpu; mem_total = $memTotal; mem_used = $memUsed
      uptime = $uptime; net_rx = $netRx; net_tx = $netTx
      disks = @($disks)
      agent = @{ version = $AgentVersion; veeam = [bool]$HasVeeam; backup = [bool]$HasBackup; paths = @($BackupPaths) }
    }
    if ($backups) { $payload.backups = $backups }
    $body = $payload | ConvertTo-Json -Depth 8 -Compress

    $resp = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' `
      -Headers @{ 'X-Token' = $Token } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5
    try { if ($resp -and $resp.agent) { $rc = "USB_HOURS=$($resp.agent.usb_window)`r`nUSB_PATHS=$($resp.agent.usb_paths)"; if ($rc -ne $remoteCache) { Set-Content -Path $RemoteConf -Value $rc -Encoding UTF8; $remoteCache = $rc } } } catch {}
    $sendSec = $sw.Elapsed.TotalSeconds - $collectSec
    if ($collectSec -ge 30 -or $sendSec -ge 3) {
      # 수집이 오래 걸리면 서버가 그 시간에 매우 느렸다는 뜻 (백업/메모리 부족). 어느 단계가 느렸는지 남긴다
      Log ("수집 지연 {0:N0}초 (cpu {1:N0}s, 메모리 {2:N0}s, 네트워크 {3:N0}s, 디스크 {4:N0}s, 전송 {5:N1}s) mem={6}%" -f $collectSec, $tm.cpu, $tm.mem, $tm.net, $tm.disk, $sendSec, $memPct)
    }
    WriteStatus $true "" $cpu $memPct
    if ($failStreak -gt 0) { Log "전송 복구 (cpu=$cpu% mem=$memPct%)" }
    $failStreak = 0
  } catch {
    $failStreak++
    $msg = $_.Exception.Message
    WriteStatus $false $msg 0 0
    if ($failStreak -le 3 -or $failStreak % 60 -eq 0) { Log "전송 실패 ($failStreak 회): $msg" }
  }
}
