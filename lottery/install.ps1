$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot
$NodeVer = 'v22.12.0'

Write-Host ''
Write-Host '======== 연말 경품 추첨 설치 ========' -ForegroundColor Yellow
Write-Host ''

# 1) 실행 엔진(Node.js) 준비
$ready = $false
if (Test-Path (Join-Path $PSScriptRoot 'node\node.exe')) {
  $ready = $true
  Write-Host '[1/3] 실행 엔진(Node.js)이 이미 준비되어 있습니다.' -ForegroundColor Green
} elseif (Get-Command node -ErrorAction SilentlyContinue) {
  $v = (& node -v)
  $major = [int]($v.TrimStart('v').Split('.')[0])
  if ($major -ge 18) {
    $ready = $true
    Write-Host "[1/3] PC에 설치된 Node.js $v 를 사용합니다." -ForegroundColor Green
  }
}
if (-not $ready) {
  $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
  $name = "node-$NodeVer-win-$arch"
  $url = "https://nodejs.org/dist/$NodeVer/$name.zip"
  Write-Host "[1/3] 실행 엔진(Node.js $NodeVer)을 내려받는 중입니다... (약 30MB, 1~2분)"
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $zip = Join-Path $env:TEMP "$name.zip"
    $tmp = Join-Path $env:TEMP 'yearend-lottery-node'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $dest = Join-Path $PSScriptRoot 'node'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item (Join-Path $tmp $name) $dest
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '      다운로드 완료' -ForegroundColor Green
  } catch {
    Write-Host ''
    Write-Host '      다운로드에 실패했습니다. (인터넷 차단 등)' -ForegroundColor Red
    Write-Host '      → https://nodejs.org 에서 LTS 버전을 직접 설치한 뒤 install.bat 을 다시 실행하세요.'
    Write-Host "      → 또는 인터넷 되는 PC에서 $url 을 받아 압축을 풀고,"
    Write-Host '        폴더 이름을 node 로 바꿔 이 폴더 안에 넣어도 됩니다.'
    exit 1
  }
}

# 2) 바탕화면 바로가기
try {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $ws = New-Object -ComObject WScript.Shell
  $lnk = $ws.CreateShortcut((Join-Path $desktop '연말 경품 추첨.lnk'))
  $lnk.TargetPath = Join-Path $PSScriptRoot 'start.bat'
  $lnk.WorkingDirectory = $PSScriptRoot
  $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,43"
  $lnk.Description = '연말 경품 추첨 서버 시작'
  $lnk.Save()
  Write-Host '[2/3] 바탕화면에 [연말 경품 추첨] 바로가기를 만들었습니다.' -ForegroundColor Green
} catch {
  Write-Host '[2/3] 바로가기를 만들지 못했습니다. 폴더의 start.bat 을 직접 실행하세요.' -ForegroundColor Yellow
}

# 3) 방화벽 (다른 PC에서 접속할 수 있도록) - 관리자 권한일 때만
$port = 3000
try { $cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json; if ($cfg.port) { $port = [int]$cfg.port } } catch {}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
  try {
    Get-NetFirewallRule -DisplayName 'YearEnd Lottery' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'YearEnd Lottery' -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
    Write-Host "[3/3] 방화벽에 $port 번 포트 접속을 허용했습니다." -ForegroundColor Green
  } catch {
    Write-Host '[3/3] 방화벽 설정에 실패했습니다. 처음 실행 때 나오는 [액세스 허용]을 눌러주세요.' -ForegroundColor Yellow
  }
} else {
  Write-Host '[3/3] 방화벽: 처음 실행할 때 Windows 보안 경고가 나오면 [액세스 허용]을 눌러주세요.' -ForegroundColor Yellow
  Write-Host '      (또는 install.bat 을 우클릭 → 관리자 권한으로 실행하면 자동으로 설정됩니다)'
}

Write-Host ''
Write-Host '설치가 끝났습니다! 바탕화면의 [연말 경품 추첨] 또는 start.bat 을 실행하세요.' -ForegroundColor Cyan
