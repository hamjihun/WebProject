# USB 복사 bat 파일에서 robocopy 직후(분리 전) 호출: 복사 완료 시각·robocopy 결과·USB 상태를 기록한다.
#   robocopy: powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\IMSMonitoringAgent\usb-done.ps1" %ERRORLEVEL% "E:\DBBackup"
#   xcopy   : powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\IMSMonitoringAgent\usb-done.ps1" %ERRORLEVEL% "%USB%\DBBackup" xcopy
# 첫 인자: 복사 명령의 종료 코드. robocopy 는 0~7 정상/8 이상 실패, xcopy 는 0 정상/1 복사할 새 파일 없음/2 이상 실패.
# 두 번째 인자(선택): 복사 대상 폴더(생략하면 자동 감지). 세 번째 인자(선택): robocopy(기본) 또는 xcopy
param([int]$Code = 0, [string]$Path = '', [string]$Tool = 'robocopy')
$DataDir = Join-Path $env:ProgramData "IMSMonitoringAgent"
$Out = Join-Path $DataDir "usb-done.json"
$LogFile = Join-Path $DataDir "agent.log"
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} [USB] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
function Iso($d) { try { if ($d -and ($d -is [datetime]) -and $d.Year -gt 2000) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } catch {}; return $null }
try { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null } catch {}
$ok = $(if ($Tool -eq 'xcopy') { $Code -eq 0 } else { $Code -lt 8 })
$r = @{ time = Iso (Get-Date); code = $Code; ok = $ok; tool = $Tool; drive = ''; path = $Path; newest_file = $null; newest_time = $null; count = 0; free = 0; total = 0 }
try {
  if (-not $Path) {
    foreach ($ld in @(Get-CimInstance Win32_LogicalDisk | Where-Object { ($_.DriveType -eq 2 -or $_.DriveType -eq 3) -and $_.DeviceID -ne 'C:' -and $_.DeviceID -ne 'D:' })) {
      $c = @(Get-ChildItem -Path "$($ld.DeviceID)\" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'backup|bak|db' })
      if ($c.Count -gt 0) { $Path = ($c | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName; break }
    }
  }
  if ($Path -and (Test-Path $Path)) {
    $r.path = $Path; $r.drive = $Path.Substring(0, 2)
    $files = @(Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(bak|trn|dif|zip|7z|rar|bkf|sql)$' })
    $r.count = $files.Count
    $n = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($n) { $r.newest_file = $n.FullName.Substring($Path.Length).TrimStart('\'); $r.newest_time = Iso $n.LastWriteTime }
    $c = $files | Sort-Object CreationTime -Descending | Select-Object -First 1
    if ($c) { $r.copied_time = Iso $c.CreationTime }
    $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($r.drive)'"; if ($ld) { $r.free = [int64]$ld.FreeSpace; $r.total = [int64]$ld.Size }
  }
} catch { Log "확인 오류: $($_.Exception.Message)" }
try { $r | ConvertTo-Json -Compress | Set-Content -Path $Out -Encoding UTF8 } catch {}
Log "복사 완료 기록 ($Tool): 코드 $Code ($(if ($r.ok) { '정상' } elseif ($Tool -eq 'xcopy' -and $Code -eq 1) { '복사할 새 파일 없음' } else { '실패' })), $($r.path), 파일 $($r.count)개, 최신 $($r.newest_time)"
