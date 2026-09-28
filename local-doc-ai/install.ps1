# 사내 문서 AI 설치 스크립트 (install.bat 에서 실행됨)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Say($msg, $color = "White") { Write-Host $msg -ForegroundColor $color }
function Fail($msg) { Say ""; Say "[설치 중단] $msg" Red; Say ""; exit 1 }

Say ""
Say "=== 사내 문서 AI 설치 ===" Cyan
Say ""

# 1. 파이썬 확인 ------------------------------------------------------------
Say "[1/5] 파이썬 확인" Yellow
$py = $null
foreach ($cand in @("py -3", "python")) {
    try {
        $ver = & cmd /c "$cand -c ""import sys; print(*sys.version_info[:2], sep='.')"" 2>nul"
        if ($LASTEXITCODE -eq 0 -and $ver) {
            $parts = $ver.Trim().Split(".")
            if ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 10) { $py = $cand; break }
        }
    } catch {}
}
if (-not $py) {
    Fail "파이썬 3.10 이상이 필요합니다. https://www.python.org/downloads/ 에서 설치하고, 설치 첫 화면에서 'Add python.exe to PATH' 를 꼭 체크하세요. 또는 명령 프롬프트에서: winget install Python.Python.3.12"
}
Say "  파이썬 $ver 사용" Green

# 2. 가상환경과 패키지 --------------------------------------------------------
Say "[2/5] 프로그램 구성요소 설치 (처음 한 번, 몇 분 걸릴 수 있음)" Yellow
if (-not (Test-Path ".venv\Scripts\python.exe")) {
    & cmd /c "$py -m venv .venv"
    if ($LASTEXITCODE -ne 0) { Fail "가상환경을 만들 수 없습니다." }
}
$vpy = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (Test-Path "wheels") {
    # 인터넷이 막힌 PC: 미리 받아 둔 wheels 폴더에서 설치
    & $vpy -m pip install --no-index --find-links wheels -r requirements.txt
} else {
    & $vpy -m pip install --disable-pip-version-check -q -r requirements.txt
}
if ($LASTEXITCODE -ne 0) { Fail "구성요소 설치에 실패했습니다. 인터넷 연결 또는 회사 보안 프로그램(프록시)을 확인하세요." }
Say "  완료" Green

# 3. Ollama 확인 -----------------------------------------------------------
Say "[3/5] AI 엔진(Ollama) 확인" Yellow
$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) {
    $guess = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
    if (Test-Path $guess) { $ollama = Get-Item $guess }
}
if (-not $ollama) {
    Fail "Ollama가 설치되어 있지 않습니다. https://ollama.com/download 에서 Windows용을 설치한 뒤 install.bat 을 다시 실행하세요. 또는: winget install Ollama.Ollama"
}
$ollamaExe = if ($ollama.Source) { $ollama.Source } else { $ollama.FullName }
try { Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 3 | Out-Null }
catch {
    Say "  Ollama 시작 중..."
    Start-Process $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 5
}
Say "  완료" Green

# 4. PC 메모리에 맞는 모델 선택 및 다운로드 ------------------------------------
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramGB -ge 14) {
    $chat = "qwen3:4b"; $ctx = 6144; $topk = 5
} else {
    $chat = "qwen3:1.7b"; $ctx = 4096; $topk = 4
}
Say "[4/5] AI 모델 다운로드 (메모리 ${ramGB}GB → $chat, 처음 한 번 약 2~4GB)" Yellow
foreach ($m in @($chat, "bge-m3")) {
    Say "  $m 받는 중..."
    & $ollamaExe pull $m
    if ($LASTEXITCODE -ne 0) { Fail "$m 모델을 받지 못했습니다. 인터넷 연결을 확인하세요." }
}
New-Item -ItemType Directory -Force -Path "data" | Out-Null
if (-not (Test-Path "data\settings.json")) {
    @{ chat_model = $chat; num_ctx = $ctx; top_k = $topk } | ConvertTo-Json | Set-Content -Encoding UTF8 "data\settings.json"
}
Say "  완료" Green

# 5. 바탕화면 바로가기 --------------------------------------------------------
Say "[5/5] 바탕화면 바로가기 만들기" Yellow
try {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "사내 문서 AI.lnk"))
    $lnk.TargetPath = Join-Path $PSScriptRoot "run.bat"
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.Save()
    Say "  완료" Green
} catch { Say "  바로가기를 만들지 못했습니다. run.bat 을 직접 실행하세요." DarkYellow }

Say ""
Say "설치가 끝났습니다. 바탕화면의 '사내 문서 AI' 또는 run.bat 을 실행하세요." Cyan
Say ""
