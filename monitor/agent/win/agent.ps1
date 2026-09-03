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

$os = Get-CimInstance Win32_OperatingSystem
$osName = "$($os.Caption) $($os.Version)"
Log "에이전트 시작: $HostName -> $Url (간격 ${Interval}초)"

function Get-NetBytes {
  $s = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface | Where-Object { $_.Name -notmatch 'Loopback|isatap|Teredo' }
  [pscustomobject]@{ rx = ($s | Measure-Object BytesReceivedPersec -Sum).Sum; tx = ($s | Measure-Object BytesSentPersec -Sum).Sum }
}
$prevNet = Get-NetBytes
$prevT = Get-Date
$failStreak = 0

while ($true) {
  Start-Sleep -Seconds $Interval
  try {
    try {
      $cpu = [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue, 1)
    } catch {
      $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
    }
    $os = Get-CimInstance Win32_OperatingSystem
    $memTotal = [int64]$os.TotalVisibleMemorySize * 1024
    $memUsed = $memTotal - ([int64]$os.FreePhysicalMemory * 1024)
    $memPct = [int][math]::Round($memUsed * 100 / $memTotal)
    $uptime = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds

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
      host = $HostName; os = $osName; token = $Token
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
