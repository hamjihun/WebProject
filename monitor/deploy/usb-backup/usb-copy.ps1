# USB 백업용 robocopy 실행기 — 화면에는 전체 진행률(%)만, 로그에는 실패한 파일과 요약만 남긴다.
# bat 파일과 같은 폴더에 두고 bat 에서 이렇게 부른다:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0usb-copy.ps1" -Src "%SRC%" -Dst "%DST%" -Log "%LOG_FILE%" -Options "/E /XO /R:2 /W:5"
#   set RC=%ERRORLEVEL%      ← robocopy 결과 코드 그대로 (0~7 정상, 8 이상 일부 실패, 16 복사 못 함)
# 순서: ① 복사할 양 계산(robocopy /L, 실제 복사 안 함) → ② 실제 복사하면서 진행률 표시 → ③ 실패·요약만 로그에 기록
# -Options 의 각 항목에는 띄어쓰기가 없어야 한다 (예: /XF *.ldb ~$* /XD Spam).
param(
  [Parameter(Mandatory = $true)][string]$Src,
  [Parameter(Mandatory = $true)][string]$Dst,
  [string]$Log = '',
  [string]$Options = '/E /R:2 /W:5'
)

$opts = @($Options -split '\s+' | Where-Object { $_ })
$tmp = Join-Path $env:TEMP ('usbcopy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Fmt([double]$b) { if ($b -ge 1TB) { '{0:N2} TB' -f ($b / 1TB) } elseif ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) } }
function Span($ts) { '{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds }
function Show([string]$s) { $w = 110; try { $w = [Console]::WindowWidth - 1 } catch {}; if ($s.Length -gt $w) { $s = $s.Substring(0, $w) }; [Console]::Write("`r" + $s.PadRight($w)) }
function QP([string]$p) {                             # robocopy 경로 인수: 끝의 \ 는 따옴표를 깨므로 정리
  if ($p.EndsWith('\')) { $p = $p + '.' }
  return '"' + $p + '"'
}
function Title([string]$t) { try { $host.UI.RawUI.WindowTitle = $t } catch {} }

# ---- ① 복사할 양 계산 ----
$t0 = Get-Date
Write-Host "① 복사할 양 계산 중 (실제 복사는 아직 안 함, 파일이 많으면 몇 분 걸립니다)"
$dryOut = Join-Path $tmp 'dry.txt'
$dryOpts = @($opts | Where-Object { $_ -notmatch '^/(R|W):' -and $_ -notmatch '^/(TEE|NP|NFL|NDL|BYTES|LOG|UNILOG)' })
$a1 = (@((QP $Src), (QP $Dst)) + $dryOpts + @('/L', '/NFL', '/NDL', '/NJH', '/BYTES', '/NP', '/R:0', '/W:0')) -join ' '
$p1 = Start-Process robocopy.exe -ArgumentList $a1 -NoNewWindow -PassThru -RedirectStandardOutput $dryOut
$null = $p1.Handle
while (-not $p1.HasExited) { Show ('   계산 중... ' + (Span ((Get-Date) - $t0))); Title "백업 준비 중 - 복사할 양 계산"; Start-Sleep -Milliseconds 500 }
# 요약표(디렉터리·파일·바이트 줄)의 두 번째 숫자 = 복사할 개수·크기. 한글 Windows 에서도 숫자 칸은 같다
$rows = @()
foreach ($l in @(Get-Content $dryOut -Encoding Default -ErrorAction SilentlyContinue)) {
  if ($l -match '^\s*[^:]+:\s+(\d+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s*$') { $rows += , @([int64]$matches[1], [int64]$matches[2]) }
}
$totFiles = 0; $totBytes = 0
if ($rows.Count -ge 3) { $totFiles = $rows[1][1]; $totBytes = $rows[2][1] }
Show ("   복사할 파일 {0:N0}개 · {1} (계산 {2})" -f $totFiles, (Fmt $totBytes), (Span ((Get-Date) - $t0)))
Write-Host ''

# ---- ② 실제 복사 + 진행률 ----
Write-Host "② 복사 중"
$ulog = Join-Path $tmp 'run.log'
$a2 = (@((QP $Src), (QP $Dst)) + $opts + @('/NDL', '/NP', '/BYTES', ('/UNILOG:' + (QP $ulog)))) -join ' '
$t1 = Get-Date
$p2 = Start-Process robocopy.exe -ArgumentList $a2 -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $tmp 'out.txt')
$null = $p2.Handle
$done = [int64]0; $nf = 0; $errs = New-Object System.Collections.ArrayList; $grabNext = $false
$fs = $null; $sr = $null; $rest = ''
function Eat([string]$chunk) {                      # 로그에 새로 쓰인 부분을 읽어 크기를 더한다 (마지막 미완성 줄은 다음에)
  $txt = $script:rest + $chunk
  $lines = $txt -split "`n"
  $script:rest = $lines[$lines.Count - 1]
  for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    $l = $lines[$i].TrimEnd("`r")
    if ($script:grabNext) { if ($l.Trim() -and $script:errs.Count -lt 400) { [void]$script:errs.Add('      ' + $l.Trim()) }; $script:grabNext = $false; continue }
    if ($l -match '(ERROR|오류) \d+ \(0x') { if ($script:errs.Count -lt 400) { [void]$script:errs.Add($l.Trim()) }; $script:grabNext = $true }
    elseif ($l -match "`t\s*(\d+)`t") { $script:done += [int64]$matches[1]; $script:nf++ }
  }
}
function Draw {
  $pct = 0.0
  if ($totBytes -gt 0) { $pct = [math]::Min(99.9, 100.0 * $done / $totBytes) } elseif ($totFiles -gt 0) { $pct = [math]::Min(99.9, 100.0 * $nf / $totFiles) }
  $el = (Get-Date) - $t1
  $eta = ''
  if ($done -gt 0 -and $totBytes -gt $done -and $el.TotalSeconds -gt 5) { $eta = ' · 남은 시간 약 ' + (Span ([TimeSpan]::FromSeconds($el.TotalSeconds * ($totBytes - $done) / $done))) }
  $n = [int][math]::Floor($pct / 100 * 30)
  $bar = ('#' * $n) + ('-' * (30 - $n))
  $fail = $(if ($errs.Count) { " · 실패 $(@($errs | Where-Object { $_ -notmatch '^\s' }).Count)" } else { '' })
  Show ("   [{0}] {1,5:N1}%  {2} / {3} · 파일 {4:N0}/{5:N0} · 경과 {6}{7}{8}" -f $bar, $pct, (Fmt $done), (Fmt $totBytes), $nf, $totFiles, (Span $el), $eta, $fail)
  Title ("백업 {0:N1}% - {1}" -f $pct, $Dst)
}
while ($true) {
  $ended = $p2.HasExited
  if (-not $sr -and (Test-Path $ulog)) { try { $fs = [IO.File]::Open($ulog, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Unicode) } catch {} }
  if ($sr) { try { Eat ($sr.ReadToEnd()) } catch {} }
  Draw
  if ($ended) { break }
  Start-Sleep -Milliseconds 700
}
if ($rest) { Eat "`n" }
$p2.WaitForExit()
$code = $p2.ExitCode; if ($null -eq $code) { $code = 16 }
if ($sr) { $sr.Close() }; if ($fs) { $fs.Close() }
if ($code -lt 8) { $script:done = [math]::Max($done, $totBytes) }
Draw
Write-Host ''

# ---- ③ 결과: 실패한 파일·요약만 로그에 ----
$tail = @(); try { $tail = @(Get-Content $ulog -Encoding Unicode -Tail 14 -ErrorAction Stop | Where-Object { $_.Trim() }) } catch {}
$failN = @($errs | Where-Object { $_ -notmatch '^\s' }).Count
$what = $(if ($code -ge 16) { '복사 못 함 (경로·USB 확인)' } elseif ($code -ge 8) { "일부 파일 실패 ($failN 건)" } elseif ($code -band 1) { '정상 (새 파일 복사함)' } else { '정상 (복사할 새 파일 없음)' })
$out = @()
$out += ('==== {0:yyyy-MM-dd HH:mm:ss} ~ {1:HH:mm:ss} (걸린 시간 {2}) ====' -f $t0, (Get-Date), (Span ((Get-Date) - $t0)))
$out += "원본: $Src  →  대상: $Dst"
$out += "옵션: $Options"
$out += ("결과 코드 {0}: {1} · 복사한 파일 {2:N0}개 · {3}" -f $code, $what, $nf, (Fmt $done))
if ($errs.Count) { $out += '-- 실패한 파일 --'; $out += @($errs) }
if ($tail.Count) { $out += '-- robocopy 요약 --'; $out += $tail }
$out += ''
if ($Log) {
  try { $ld = Split-Path -Parent $Log; if ($ld -and -not (Test-Path $ld)) { New-Item -ItemType Directory -Force -Path $ld | Out-Null }; Add-Content -Path $Log -Value $out -Encoding UTF8 } catch { Write-Host "로그 저장 실패: $($_.Exception.Message)" }
}
Write-Host ''
Write-Host ("결과 코드 {0}: {1}" -f $code, $what)
if ($failN) { Write-Host '실패한 파일 (최대 10개):'; @($errs | Select-Object -First 20) | ForEach-Object { Write-Host "  $_" } }
Title ("백업 끝 - 코드 {0}" -f $code)
try { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
exit $code
