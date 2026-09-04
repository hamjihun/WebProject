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
    $cpu = Get-CpuPercent
    $os = Get-CimInstance Win32_OperatingSystem
    $memTotal = [int64]$os.TotalVisibleMemorySize * 1024
    $memUsed = $memTotal - ([int64]$os.FreePhysicalMemory * 1024)
    $memPct = [int][math]::Round($memUsed * 100 / $memTotal)
    if (((Get-Date) - $startChecked).TotalMinutes -ge 10) { $startTime = Get-StartTime; $startChecked = Get-Date }
    $uptime = [int]((Get-Date) - $startTime).TotalSeconds

    $now = Get-Date
    $dt = [math]::Max(1, ($now - $prevT).TotalSeconds)
    $net = Get-NetBytes
    $netRx = [int64](($net.rx - $prevNet.rx) / $dt)
    $netTx = [int64](($net.tx - $prevNet.tx) / $dt)
    $prevNet = $net; $prevT = $now

    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
      @{ mount = $_.DeviceID; total = [int64]$_.Size; used = [int64]$_.Size - [int64]$_.FreeSpace }
    }
    $body = @{
      host = $HostName; name = (Get-DisplayName); os = $osName; token = $Token
      cpu = $cpu; mem_total = $memTotal; mem_used = $memUsed
      uptime = $uptime; net_rx = $netRx; net_tx = $netTx
      disks = @($disks)
    } | ConvertTo-Json -Depth 4 -Compress

    Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' `
      -Headers @{ 'X-Token' = $Token } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
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
