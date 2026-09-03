# Windows 서버용 에이전트: CPU/메모리/디스크/네트워크를 읽어서 수집기로 전송합니다.
# 필요한 것: Windows PowerShell 5.1 이상 (기본 내장)
#
# 사용법 (PowerShell 창에서):
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\agent.ps1 -Url http://192.168.0.10:8787/api/metrics
#   .\agent.ps1 -Url http://192.168.0.10:8787/api/metrics -Interval 10 -Token 비밀값
#
# 상시 실행은 "작업 스케줄러"에 시작 시 실행으로 등록하거나 NSSM 으로 서비스화하면 됩니다.

param(
  [string]$Url = "http://127.0.0.1:8787/api/metrics",
  [int]$Interval = 5,
  [string]$Token = "",
  [string]$HostName = $env:COMPUTERNAME
)

$os = Get-CimInstance Win32_OperatingSystem
$osName = "$($os.Caption) $($os.Version)"

function Get-NetBytes {
  $s = Get-CimInstance Win32_PerfRawData_Tcpip_NetworkInterface | Where-Object { $_.Name -notmatch 'Loopback|isatap|Teredo' }
  [pscustomobject]@{ rx = ($s | Measure-Object BytesReceivedPersec -Sum).Sum; tx = ($s | Measure-Object BytesSentPersec -Sum).Sum }
}

$prevNet = Get-NetBytes
$prevT = Get-Date

while ($true) {
  Start-Sleep -Seconds $Interval

  # CPU: 카운터 사용 (실패 시 WMI LoadPercentage 로 대체)
  try {
    $cpu = [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue, 1)
  } catch {
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
  }

  $os = Get-CimInstance Win32_OperatingSystem
  $memTotal = [int64]$os.TotalVisibleMemorySize * 1024
  $memUsed = $memTotal - ([int64]$os.FreePhysicalMemory * 1024)
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

  try {
    Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' `
      -Headers @{ 'X-Token' = $Token } -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 5 | Out-Null
    Write-Host ("{0:yyyy-MM-dd HH:mm:ss} sent cpu={1}% mem={2}%" -f $now, $cpu, [math]::Round($memUsed * 100 / $memTotal))
  } catch {
    Write-Warning ("{0:yyyy-MM-dd HH:mm:ss} send failed to {1}: {2}" -f $now, $Url, $_.Exception.Message)
  }
}
