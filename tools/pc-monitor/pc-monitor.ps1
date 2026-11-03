<#
  PC 상태 모니터 (설치 불필요, Windows PowerShell 5.1 기본 기능만 사용)

  - 일정 간격으로 CPU / 메모리 / 디스크 / CPU 클럭 / 전원 상태 / CPU 상위 프로세스를 기록
  - 기록 위치: 문서\PCMonitor\monitor_YYYY-MM-DD.csv  (엑셀로 바로 열림)
  - CPU 또는 메모리가 높을 때, 또는 PC가 멈췄던 흔적(기록 지연)이 있을 때
    문서\PCMonitor\alert_YYYY-MM-DD.log 에 상세 내용 추가 기록
  - 종료: 창에서 Ctrl + C  (백그라운드 실행 시 작업 관리자에서 powershell 종료)
#>
param(
    [int]$IntervalSec   = 10,   # 기록 간격(초)
    [int]$CpuAlert      = 80,   # CPU 경고 기준(%)
    [int]$MemAlert      = 90,   # 메모리 경고 기준(%)
    [int]$TopN          = 5,    # CSV에 남길 상위 프로세스 수
    [int]$KeepDays      = 14,   # 이 기간보다 오래된 기록 파일은 자동 삭제
    [switch]$Quiet              # 화면 출력 생략(백그라운드용)
)

$ErrorActionPreference = 'SilentlyContinue'
$logDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PCMonitor'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# 오래된 기록 정리
Get-ChildItem $logDir -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } | Remove-Item -Force

$cores = [Environment]::ProcessorCount
$totalMemMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
$baseMHz = (Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed

function Get-Sample {
    # CPU 전체 사용률 (언어 설정과 무관한 WMI 클래스 사용)
    $cpu = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime

    # 실제 CPU 클럭 (기본 클럭 대비 %) -> 낮게 떨어지면 발열/절전으로 성능 제한(스로틀링) 의심
    $perf = (Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'").PercentProcessorPerformance
    $mhz = if ($perf -and $baseMHz) { [math]::Round($baseMHz * $perf / 100) } else { '' }

    # 메모리
    $os = Get-CimInstance Win32_OperatingSystem
    $memUsedPct = [math]::Round(100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100), 1)
    $memFreeMB = [math]::Round($os.FreePhysicalMemory / 1KB)

    # 디스크 사용률 (100 - 유휴%)
    $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    $diskBusy = if ($disk) { [math]::Max(0, 100 - $disk.PercentIdleTime) } else { '' }

    # C드라이브 여유 공간
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $cFreePct = if ($c) { [math]::Round($c.FreeSpace / $c.Size * 100, 1) } else { '' }

    # 전원 (어댑터 연결 여부 / 배터리 %)
    $bat = Get-CimInstance Win32_Battery | Select-Object -First 1
    $power = if (-not $bat) { '' } elseif ($bat.BatteryStatus -eq 2) { 'AC' } else { 'BAT' }
    $batPct = if ($bat) { $bat.EstimatedChargeRemaining } else { '' }

    # 온도 (관리자 권한 + 제조사 지원 시에만 값이 나옴, 없으면 공란)
    $temp = ''
    $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature | Select-Object -First 1
    if ($tz) { $temp = [math]::Round($tz.CurrentTemperature / 10 - 273.15, 1) }

    # 프로세스별 CPU / 메모리
    $procs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
        Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
        ForEach-Object {
            [pscustomobject]@{
                Name  = ($_.Name -replace '#\d+$', '')
                Cpu   = [math]::Round($_.PercentProcessorTime / $cores, 1)
                MemMB = [math]::Round($_.WorkingSetPrivate / 1MB)
            }
        }
    # 같은 이름(chrome 여러 개 등) 합산
    $grouped = $procs | Group-Object Name | ForEach-Object {
        [pscustomobject]@{
            Name  = $_.Name
            Cpu   = [math]::Round(($_.Group | Measure-Object Cpu -Sum).Sum, 1)
            MemMB = ($_.Group | Measure-Object MemMB -Sum).Sum
            Count = $_.Count
        }
    }

    [pscustomobject]@{
        Cpu = $cpu; Mhz = $mhz; PerfPct = $perf
        MemPct = $memUsedPct; MemFreeMB = $memFreeMB
        DiskBusy = $diskBusy; CFreePct = $cFreePct
        Power = $power; BatPct = $batPct; Temp = $temp
        TopCpu = $grouped | Sort-Object Cpu -Descending | Select-Object -First 10
        TopMem = $grouped | Sort-Object MemMB -Descending | Select-Object -First 10
    }
}

function Format-Top($list, $n) {
    ($list | Select-Object -First $n | ForEach-Object { "{0}({1}%)" -f $_.Name, $_.Cpu }) -join ' / '
}

if (-not $Quiet) {
    Write-Host "PC 모니터 시작 - 간격 ${IntervalSec}초, 기록 위치: $logDir" -ForegroundColor Cyan
    Write-Host "CPU 코어 $cores 개, 메모리 $totalMemMB MB, 기본 클럭 $baseMHz MHz"
    Write-Host "종료하려면 Ctrl + C`n"
}

$last = Get-Date
while ($true) {
    $now = Get-Date
    $gap = ($now - $last).TotalSeconds
    $last = $now

    $s = Get-Sample

    # 예정 간격보다 훨씬 늦게 돌아왔다면 그 사이 PC가 멈췄거나(프리징) 절전에 들어갔던 것
    $note = @()
    if ($gap -gt [math]::Max($IntervalSec * 3, 30)) { $note += ("기록지연 {0}초(멈춤/절전 의심)" -f [math]::Round($gap)) }
    if ($s.Cpu -ge $CpuAlert) { $note += 'CPU높음' }
    if ($s.MemPct -ge $MemAlert) { $note += '메모리부족' }
    if ($s.DiskBusy -ne '' -and $s.DiskBusy -ge 90) { $note += '디스크포화' }
    if ($s.PerfPct -and $s.PerfPct -lt 50 -and $s.Cpu -ge 50) { $note += '클럭저하(발열/절전 의심)' }

    $row = [pscustomobject][ordered]@{
        '시간'             = $now.ToString('yyyy-MM-dd HH:mm:ss')
        'CPU(%)'           = $s.Cpu
        'CPU클럭(MHz)'     = $s.Mhz
        '클럭비율(%)'      = $s.PerfPct
        '메모리사용(%)'    = $s.MemPct
        '메모리여유(MB)'   = $s.MemFreeMB
        '디스크사용(%)'    = $s.DiskBusy
        'C드라이브여유(%)' = $s.CFreePct
        '전원'             = $s.Power
        '배터리(%)'        = $s.BatPct
        '온도(C)'          = $s.Temp
        'CPU상위프로세스'  = Format-Top $s.TopCpu $TopN
        '메모리상위'       = ($s.TopMem | Select-Object -First 3 | ForEach-Object { "{0}({1}MB)" -f $_.Name, $_.MemMB }) -join ' / '
        '비고'             = $note -join ', '
    }

    $csv = Join-Path $logDir ("monitor_{0}.csv" -f $now.ToString('yyyy-MM-dd'))
    $row | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8

    if ($note.Count -gt 0) {
        $alert = Join-Path $logDir ("alert_{0}.log" -f $now.ToString('yyyy-MM-dd'))
        $lines = @()
        $lines += "==== $($row.'시간')  [$($row.'비고')]"
        $lines += ("CPU {0}%  클럭 {1}MHz({2}%)  메모리 {3}%  디스크 {4}%  전원 {5}  온도 {6}" -f `
                    $s.Cpu, $s.Mhz, $s.PerfPct, $s.MemPct, $s.DiskBusy, $s.Power, $s.Temp)
        $lines += "-- CPU 상위 10"
        $lines += $s.TopCpu | ForEach-Object { "   {0,-40} CPU {1,5}%  메모리 {2,6}MB  (x{3})" -f $_.Name, $_.Cpu, $_.MemMB, $_.Count }
        $lines += "-- 메모리 상위 10"
        $lines += $s.TopMem | ForEach-Object { "   {0,-40} 메모리 {1,6}MB  CPU {2,5}%" -f $_.Name, $_.MemMB, $_.Cpu }
        $lines += ''
        Add-Content -Path $alert -Value $lines -Encoding UTF8
    }

    if (-not $Quiet) {
        $color = if ($note.Count -gt 0) { 'Yellow' } else { 'Gray' }
        Write-Host ("[{0}] CPU {1,3}%  클럭 {2,4}MHz  메모리 {3,5}%  디스크 {4,3}%  {5}  | {6} {7}" -f `
            $now.ToString('HH:mm:ss'), $s.Cpu, $s.Mhz, $s.MemPct, $s.DiskBusy, $s.Power,
            (Format-Top $s.TopCpu 3), $(if ($note) { "<< $($note -join ', ')" })) -ForegroundColor $color
    }

    $elapsed = ((Get-Date) - $now).TotalSeconds
    Start-Sleep -Milliseconds ([math]::Max(500, ($IntervalSec - $elapsed) * 1000))
}
