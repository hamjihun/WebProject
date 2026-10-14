#Requires -Version 5.1
<#
    사내 PC 자동 셋팅 도구
    - 프로그램 설치 / 윈도우 업데이트 / 드라이버 확인·설치 / 작업표시줄 / 전원 관리 / 기타 설정
    - Setup.bat 으로 실행하세요. (관리자 권한 자동 요청)
    - 설치할 프로그램과 각종 설정 값은 config.json 에서 관리합니다.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root       = $PSScriptRoot
$ConfigPath = Join-Path $Root 'config.json'
$LogDir     = Join-Path $Root 'logs'

# ---------------------------------------------------------------------------
# 관리자 권한 확인
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show('관리자 권한으로 실행해야 합니다. Setup.bat 으로 실행하세요.', 'PC 셋팅', 'OK', 'Warning') | Out-Null
    exit 1
}

# ---------------------------------------------------------------------------
# 설정 파일
# ---------------------------------------------------------------------------
function Read-Config {
    Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Config($Cfg) {
    $Cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

try {
    $script:Config = Read-Config
} catch {
    [System.Windows.Forms.MessageBox]::Show("config.json 을 읽을 수 없습니다.`n`n$($_.Exception.Message)", 'PC 셋팅', 'OK', 'Error') | Out-Null
    exit 1
}

# ---------------------------------------------------------------------------
# 실제 작업 (UI 가 멈추지 않도록 별도 런스페이스에서 실행)
# ---------------------------------------------------------------------------
$Worker = {
    param($Sync, $Plan)

    $Cfg   = $Plan.Config
    $State = @{ Step = 0 }

    function Write-Log([string]$Message, [string]$Level = 'INFO') {
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        $Sync.Queue.Enqueue($line)
        Add-Content -LiteralPath $Plan.LogFile -Value $line -Encoding UTF8
    }

    function Set-Status([string]$Text) { $Sync.Status = $Text }

    # 현재 단계 안에서의 진행률 (done / total) 을 전체 진행률로 환산
    function Set-StepProgress([double]$Done, [double]$Total) {
        $fraction = 0
        if ($Total -gt 0) { $fraction = $Done / $Total }
        $Sync.Percent = [int](100 * ($State.Step + $fraction) / $Sync.StepCount)
    }

    function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    }

    function Invoke-Cmd([string]$Desc, [string]$Exe, [string[]]$Arguments) {
        & $Exe @Arguments *> $null
        if ($LASTEXITCODE -eq 0) { Write-Log $Desc 'OK'; return $true }
        Write-Log "$Desc 실패 (코드 $LASTEXITCODE)" 'ERROR'
        return $false
    }

    function Resolve-LocalPath([string]$Path) {
        if ([IO.Path]::IsPathRooted($Path)) { return $Path }
        return (Join-Path $Plan.Root $Path)
    }

    # --- 프로그램 설치 ------------------------------------------------------
    function Install-Programs {
        $list = @($Plan.Programs)
        if ($list.Count -eq 0) { Write-Log '선택된 프로그램이 없습니다.'; return }

        $hasWinget = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
        if (-not $hasWinget) {
            Write-Log 'winget 이 없습니다. winget 항목은 건너뜁니다. (Microsoft Store 에서 "앱 설치 관리자" 업데이트 필요)' 'WARN'
        }

        for ($i = 0; $i -lt $list.Count; $i++) {
            $p = $list[$i]
            Set-StepProgress $i $list.Count
            Set-Status "프로그램 설치 중 ($($i + 1)/$($list.Count)): $($p.name)"
            try {
                if ($p.winget) {
                    if (-not $hasWinget) { throw 'winget 이 없어 설치할 수 없습니다.' }
                    & winget.exe list --id $p.winget -e --accept-source-agreements *> $null
                    if ($LASTEXITCODE -eq 0) { Write-Log "$($p.name): 이미 설치되어 있어 건너뜀" 'OK'; continue }

                    Write-Log "$($p.name): 설치 시작 (winget: $($p.winget))"
                    & winget.exe install --id $p.winget -e --silent --accept-package-agreements --accept-source-agreements *> $null
                    $code = $LASTEXITCODE
                }
                elseif ($p.file) {
                    $path = Resolve-LocalPath $p.file
                    if (-not (Test-Path -LiteralPath $path)) { throw "설치파일이 없습니다: $path" }

                    Write-Log "$($p.name): 설치 시작 ($path)"
                    if ($path -like '*.msi') {
                        $msiArgs = "/i `"$path`" /qn /norestart"
                        if ($p.args) { $msiArgs += " $($p.args)" }
                        $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru -ErrorAction Stop
                    }
                    else {
                        $sp = @{ FilePath = $path; Wait = $true; PassThru = $true; ErrorAction = 'Stop' }
                        if ($p.args) { $sp.ArgumentList = $p.args }
                        $proc = Start-Process @sp
                    }
                    $code = $proc.ExitCode
                }
                else {
                    throw 'config.json 에 winget 또는 file 항목이 필요합니다.'
                }

                if ($code -eq 0) { Write-Log "$($p.name): 설치 완료" 'OK' }
                elseif ($code -eq 3010 -or $code -eq 1641) {
                    Write-Log "$($p.name): 설치 완료 (재부팅 필요)" 'OK'
                    $Sync.RebootRequired = $true
                }
                else { Write-Log "$($p.name): 설치 실패 (종료 코드 $code)" 'ERROR' }
            }
            catch { Write-Log "$($p.name): $($_.Exception.Message)" 'ERROR' }
        }
    }

    # --- 윈도우 업데이트 (드라이버 업데이트에도 사용) -----------------------
    function Invoke-WindowsUpdate([string]$Criteria, [string]$Label) {
        Set-Status "$Label 검색 중... (몇 분 걸릴 수 있습니다)"
        Write-Log "$Label 검색 시작"
        try {
            $session  = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $result   = $searcher.Search($Criteria)
        }
        catch { Write-Log "${Label} 검색 실패: $($_.Exception.Message)" 'ERROR'; return }

        # 윈도우 버전 업그레이드(기능 업데이트)는 제외
        $updates = @()
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)
            $isUpgrade = $false
            foreach ($c in $u.Categories) { if ($c.Name -eq 'Upgrades') { $isUpgrade = $true } }
            if ($isUpgrade) { Write-Log "버전 업그레이드는 건너뜀: $($u.Title)" 'WARN' } else { $updates += $u }
        }

        if ($updates.Count -eq 0) { Write-Log "${Label}: 설치할 항목이 없습니다." 'OK'; return }
        Write-Log "${Label}: $($updates.Count)개 발견"

        for ($i = 0; $i -lt $updates.Count; $i++) {
            $u = $updates[$i]
            Set-StepProgress $i $updates.Count
            Set-Status "$Label 설치 중 ($($i + 1)/$($updates.Count)): $($u.Title)"
            try {
                if (-not $u.EulaAccepted) { $u.AcceptEula() }
                $coll = New-Object -ComObject Microsoft.Update.UpdateColl
                [void]$coll.Add($u)

                if (-not $u.IsDownloaded) {
                    $downloader = $session.CreateUpdateDownloader()
                    $downloader.Updates = $coll
                    [void]$downloader.Download()
                }

                $installer = $session.CreateUpdateInstaller()
                $installer.Updates = $coll
                $r = $installer.Install()

                # ResultCode: 2 = 성공, 3 = 일부 성공, 4 = 실패, 5 = 중단
                if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) { Write-Log "설치 완료: $($u.Title)" 'OK' }
                else { Write-Log "설치 실패 (결과 코드 $($r.ResultCode)): $($u.Title)" 'ERROR' }
                if ($r.RebootRequired) { $Sync.RebootRequired = $true }
            }
            catch { Write-Log "설치 오류: $($u.Title) - $($_.Exception.Message)" 'ERROR' }
        }
    }

    # --- 드라이버 ------------------------------------------------------------
    function Write-ProblemDevices {
        $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
        if ($bad.Count -eq 0) { Write-Log '드라이버 문제가 있는 장치가 없습니다.' 'OK'; return }
        Write-Log "드라이버 문제가 있는 장치 $($bad.Count)개:" 'WARN'
        foreach ($b in $bad) { Write-Log "  - $($b.Name) (오류 코드 $($b.ConfigManagerErrorCode))" 'WARN' }
    }

    function Install-Drivers {
        $d = $Cfg.drivers
        Set-Status '장치 드라이버 상태 확인 중...'
        Write-ProblemDevices

        # 1) 미리 받아둔 드라이버 폴더 (하위 폴더의 .inf 전부)
        if ($d.localFolder) {
            $folder = Resolve-LocalPath $d.localFolder
            if (Test-Path -LiteralPath $folder) {
                $infCount = @(Get-ChildItem -LiteralPath $folder -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count
                if ($infCount -gt 0) {
                    Set-Status "드라이버 폴더에서 설치 중... ($infCount 개 .inf)"
                    & pnputil.exe /add-driver (Join-Path $folder '*.inf') /subdirs /install *> $null
                    $code = $LASTEXITCODE
                    if ($code -eq 0) { Write-Log "드라이버 폴더 설치 완료 ($infCount 개 .inf)" 'OK' }
                    elseif ($code -eq 3010) { Write-Log '드라이버 폴더 설치 완료 (재부팅 필요)' 'OK'; $Sync.RebootRequired = $true }
                    else { Write-Log "드라이버 폴더 설치 결과 코드 $code (일부는 이미 설치됐거나 이 PC에 맞지 않는 드라이버일 수 있습니다)" 'WARN' }
                }
            }
        }

        # 2) 제조사 업데이트 도구
        if ($d.useVendorTool) {
            $maker = (Get-CimInstance Win32_ComputerSystem).Manufacturer
            Write-Log "제조사: $maker"
            if ($maker -match 'Dell') {
                $dcu = @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe",
                         "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe") |
                       Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($dcu) {
                    Set-Status 'Dell Command Update 로 드라이버 업데이트 중...'
                    & $dcu /applyUpdates -silent -reboot=disable *> $null
                    switch ($LASTEXITCODE) {
                        0       { Write-Log 'Dell 드라이버 업데이트 완료' 'OK' }
                        1       { Write-Log 'Dell 드라이버 업데이트 완료 (재부팅 필요)' 'OK'; $Sync.RebootRequired = $true }
                        5       { Write-Log 'Dell 드라이버 업데이트 완료 (재부팅 필요)' 'OK'; $Sync.RebootRequired = $true }
                        500     { Write-Log 'Dell: 설치할 업데이트가 없습니다.' 'OK' }
                        default { Write-Log "Dell Command Update 결과 코드 $LASTEXITCODE" 'WARN' }
                    }
                }
                else { Write-Log 'Dell Command Update 가 없습니다. 프로그램 목록에 winget ID "Dell.CommandUpdate" 를 추가하면 함께 설치됩니다.' 'WARN' }
            }
            else { Write-Log '이 제조사는 전용 도구 연동이 없어 윈도우 업데이트로 드라이버를 설치합니다.' }
        }

        # 3) 윈도우 업데이트를 통한 드라이버
        if ($d.windowsUpdate) {
            Invoke-WindowsUpdate "IsInstalled=0 and IsHidden=0 and Type='Driver'" '드라이버 업데이트'
        }

        Write-Log '설치 후 장치 상태 재확인:'
        Write-ProblemDevices
    }

    # --- 작업표시줄 ----------------------------------------------------------
    function Set-Taskbar {
        $t = $Cfg.taskbar
        $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        $isWin11 = [Environment]::OSVersion.Version.Build -ge 22000

        $items = @(
            @{ Desc = '작업표시줄 정렬'; Run = {
                if (-not $isWin11 -or $null -eq $t.alignLeft) { return $false }
                Set-Reg $adv 'TaskbarAl' $(if ($t.alignLeft) { 0 } else { 1 }); $true } },
            @{ Desc = '검색 표시 방식'; Run = {
                $map = @{ hide = 0; icon = 1; box = 2 }
                if (-not $t.search -or -not $map.ContainsKey($t.search)) { return $false }
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' $map[$t.search]; $true } },
            @{ Desc = '작업 보기 버튼'; Run = {
                if ($null -eq $t.hideTaskView) { return $false }
                Set-Reg $adv 'ShowTaskViewButton' $(if ($t.hideTaskView) { 0 } else { 1 }); $true } },
            @{ Desc = '위젯 / 뉴스 및 관심사'; Run = {
                if (-not $t.hideWidgets) { return $false }
                if ($isWin11) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 }
                else { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0 }
                $true } },
            @{ Desc = '채팅(Teams) 버튼'; Run = {
                if (-not $isWin11 -or -not $t.hideChat) { return $false }
                Set-Reg $adv 'TaskbarMn' 0; $true } }
        )

        foreach ($item in $items) {
            try { if (& $item.Run) { Write-Log "작업표시줄: $($item.Desc) 적용" 'OK' } }
            catch { Write-Log "작업표시줄: $($item.Desc) 실패 - $($_.Exception.Message)" 'ERROR' }
        }
        $State.RestartExplorer = $true
    }

    # --- 전원 관리 -----------------------------------------------------------
    function Set-Power {
        $p = $Cfg.power
        $plans = @{ high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; balanced = '381b4222-f694-41f0-9685-ff5bb260df2e' }
        if ($p.plan -and $plans.ContainsKey($p.plan)) {
            & powercfg.exe /setactive $plans[$p.plan] *> $null
            if ($LASTEXITCODE -eq 0) { Write-Log "전원 관리 옵션: $($p.plan) 적용" 'OK' }
            else { Write-Log "전원 관리 옵션 '$($p.plan)' 이 이 PC에 없습니다. (최신 노트북은 '균형 조정'만 있는 경우가 많습니다)" 'WARN' }
        }

        $timeouts = [ordered]@{
            monitorTimeoutAC = @('monitor-timeout-ac', '모니터 끄기(전원 연결)')
            monitorTimeoutDC = @('monitor-timeout-dc', '모니터 끄기(배터리)')
            sleepTimeoutAC   = @('standby-timeout-ac', '절전 모드(전원 연결)')
            sleepTimeoutDC   = @('standby-timeout-dc', '절전 모드(배터리)')
        }
        foreach ($key in $timeouts.Keys) {
            $value = $p.$key
            if ($null -eq $value) { continue }
            $label = if ($value -eq 0) { '사용 안 함' } else { "$value 분" }
            [void](Invoke-Cmd "$($timeouts[$key][1]): $label" 'powercfg.exe' @('/change', $timeouts[$key][0], "$value"))
        }

        $lid = @{ nothing = 0; sleep = 1; hibernate = 2; shutdown = 3 }
        $lidChanged = $false
        if ($p.lidCloseAC -and $lid.ContainsKey($p.lidCloseAC)) {
            $lidChanged = Invoke-Cmd "덮개 닫을 때(전원 연결): $($p.lidCloseAC)" 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', "$($lid[$p.lidCloseAC])")
        }
        if ($p.lidCloseDC -and $lid.ContainsKey($p.lidCloseDC)) {
            $lidChanged = (Invoke-Cmd "덮개 닫을 때(배터리): $($p.lidCloseDC)" 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', "$($lid[$p.lidCloseDC])")) -or $lidChanged
        }
        if ($lidChanged) { & powercfg.exe /setactive SCHEME_CURRENT *> $null }

        if ($p.disableHibernate) { [void](Invoke-Cmd '최대 절전 모드 끄기' 'powercfg.exe' @('/hibernate', 'off')) }
    }

    # --- 기타 ----------------------------------------------------------------
    function Set-Misc {
        $m = $Cfg.misc
        if ($null -ne $m.showFileExtensions) {
            try {
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' $(if ($m.showFileExtensions) { 0 } else { 1 })
                Write-Log "파일 확장자 표시: $($m.showFileExtensions)" 'OK'
                $State.RestartExplorer = $true
            }
            catch { Write-Log "파일 확장자 설정 실패 - $($_.Exception.Message)" 'ERROR' }
        }

        if ($Plan.ComputerName -and $Plan.ComputerName -ne $env:COMPUTERNAME) {
            try {
                Rename-Computer -NewName $Plan.ComputerName -Force -ErrorAction Stop
                Write-Log "PC 이름 변경: $env:COMPUTERNAME → $($Plan.ComputerName) (재부팅 후 적용)" 'OK'
                $Sync.RebootRequired = $true
            }
            catch { Write-Log "PC 이름 변경 실패 - $($_.Exception.Message)" 'ERROR' }
        }
    }

    # --- 실행 ----------------------------------------------------------------
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Write-Log "셋팅 시작 - PC: $env:COMPUTERNAME / 사용자: $env:USERNAME / $($os.Caption) (빌드 $($os.BuildNumber))"
        $Sync.StepCount = [Math]::Max(1, $Plan.Steps.Count)

        for ($s = 0; $s -lt $Plan.Steps.Count; $s++) {
            $State.Step = $s
            Set-StepProgress 0 1
            $step = $Plan.Steps[$s]
            Write-Log "===== $($step.Title) ====="
            Set-Status $step.Title
            try {
                switch ($step.Id) {
                    'taskbar'  { Set-Taskbar }
                    'power'    { Set-Power }
                    'misc'     { Set-Misc }
                    'programs' { Install-Programs }
                    'drivers'  { Install-Drivers }
                    'update'   { Invoke-WindowsUpdate "IsInstalled=0 and IsHidden=0 and Type='Software'" '윈도우 업데이트' }
                }
            }
            catch { Write-Log "$($step.Title) 중 오류: $($_.Exception.Message)" 'ERROR' }
        }

        if ($State.RestartExplorer) {
            Write-Log '변경 사항 적용을 위해 탐색기를 다시 시작합니다.'
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        }
        Write-Log '===== 모든 작업 완료 =====' 'OK'
    }
    catch { Write-Log "예상치 못한 오류: $($_.Exception.Message)" 'ERROR' }
    finally {
        $Sync.Percent = 100
        $Sync.Status  = '완료'
        $Sync.Done    = $true
    }
}

# ---------------------------------------------------------------------------
# 화면 구성
# ---------------------------------------------------------------------------
$Font     = New-Object System.Drawing.Font('Malgun Gothic', 9)
$BoldFont = New-Object System.Drawing.Font('Malgun Gothic', 9, [System.Drawing.FontStyle]::Bold)

function New-Control([string]$Type, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Text = $Text
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    return $c
}

$form = New-Control 'Form' '사내 PC 자동 셋팅' 0 0 960 720
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $Font

# 1. 실행할 작업
$grpTasks = New-Control 'GroupBox' '1. 실행할 작업' 12 10 300 230
$grpTasks.Font = $BoldFont
$form.Controls.Add($grpTasks)

# 실행 순서: 빠른 설정 → 프로그램 → 드라이버 → 윈도우 업데이트(가장 오래 걸림)
$TaskDefs = @(
    @{ Id = 'taskbar';  Title = '작업표시줄 설정' },
    @{ Id = 'power';    Title = '전원 관리 설정' },
    @{ Id = 'misc';     Title = '기타 설정 (확장자 표시, PC 이름)' },
    @{ Id = 'programs'; Title = '프로그램 설치' },
    @{ Id = 'drivers';  Title = '드라이버 확인 및 설치' },
    @{ Id = 'update';   Title = '윈도우 업데이트' }
)
$TaskChecks = @{}
$y = 28
foreach ($t in $TaskDefs) {
    $chk = New-Control 'CheckBox' $t.Title 16 $y 270 26
    $chk.Font = $Font
    $chk.Checked = $true
    $grpTasks.Controls.Add($chk)
    $TaskChecks[$t.Id] = $chk
    $y += 32
}

# PC 이름 변경
$grpName = New-Control 'GroupBox' 'PC 이름 변경 (선택)' 12 250 300 90
$grpName.Font = $BoldFont
$form.Controls.Add($grpName)
$txtName = New-Control 'TextBox' '' 16 26 266 24
$txtName.Font = $Font
$txtName.MaxLength = 15
$grpName.Controls.Add($txtName)
$lblName = New-Control 'Label' "현재: $env:COMPUTERNAME  (비워두면 변경 안 함)" 16 56 270 20
$lblName.Font = $Font
$lblName.ForeColor = [System.Drawing.Color]::Gray
$grpName.Controls.Add($lblName)

# 설정 파일 / 로그 버튼
$btnConfig = New-Control 'Button' '설정 파일 열기' 12 352 145 32
$btnReload = New-Control 'Button' '설정 다시 불러오기' 167 352 145 32
$btnLogs   = New-Control 'Button' '로그 폴더 열기' 12 390 145 32
$form.Controls.AddRange(@($btnConfig, $btnReload, $btnLogs))

# 2. 설치할 프로그램
$grpProg = New-Control 'GroupBox' '2. 설치할 프로그램' 324 10 610 412
$grpProg.Font = $BoldFont
$form.Controls.Add($grpProg)

$clbPrograms = New-Control 'CheckedListBox' '' 16 26 578 330
$clbPrograms.Font = $Font
$clbPrograms.CheckOnClick = $true
$clbPrograms.HorizontalScrollbar = $true
$grpProg.Controls.Add($clbPrograms)

$btnAdd       = New-Control 'Button' '+ 프로그램 추가' 16 366 140 32
$btnRemove    = New-Control 'Button' '선택 항목 삭제' 164 366 120 32
$btnCheckAll  = New-Control 'Button' '전체 선택' 382 366 100 32
$btnCheckNone = New-Control 'Button' '전체 해제' 494 366 100 32
foreach ($b in @($btnAdd, $btnRemove, $btnCheckAll, $btnCheckNone)) { $b.Font = $Font; $grpProg.Controls.Add($b) }

# 진행 상황
$lblStatus = New-Control 'Label' '대기 중' 12 434 920 22
$lblStatus.Font = $BoldFont
$form.Controls.Add($lblStatus)

$progress = New-Control 'ProgressBar' '' 12 458 922 22
$progress.Minimum = 0
$progress.Maximum = 100
$form.Controls.Add($progress)

$txtLog = New-Control 'TextBox' '' 12 488 922 140
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

$btnStart = New-Control 'Button' '셋팅 시작' 784 636 150 36
$btnStart.Font = $BoldFont
$form.Controls.Add($btnStart)

# ---------------------------------------------------------------------------
# 프로그램 목록
# ---------------------------------------------------------------------------
function Get-ProgramLabel($P) {
    if ($P.winget) { return '{0}    [winget: {1}]' -f $P.name, $P.winget }
    $label = '{0}    [파일: {1}' -f $P.name, $P.file
    if ($P.args) { $label += "  옵션: $($P.args)" }
    return $label + ']'
}

function Update-ProgramList {
    $clbPrograms.Items.Clear()
    foreach ($p in @($script:Config.programs)) {
        if ($null -eq $p) { continue }
        $checked = -not ($p.PSObject.Properties.Name -contains 'selected' -and $p.selected -eq $false)
        [void]$clbPrograms.Items.Add((Get-ProgramLabel $p), $checked)
    }
}

function Show-AddProgramDialog {
    $dlg = New-Control 'Form' '프로그램 추가' 0 0 520 330
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = $Font

    $dlg.Controls.Add((New-Control 'Label' '표시 이름' 16 18 100 20))
    $txtPName = New-Control 'TextBox' '' 120 15 370 24
    $dlg.Controls.Add($txtPName)

    $rbWinget = New-Control 'RadioButton' 'winget 으로 설치 (Chrome, Zoom 등 일반 프로그램)' 16 54 470 22
    $rbWinget.Checked = $true
    $dlg.Controls.Add($rbWinget)
    $dlg.Controls.Add((New-Control 'Label' 'winget ID' 36 84 80 20))
    $txtWinget = New-Control 'TextBox' '' 120 81 370 24
    $dlg.Controls.Add($txtWinget)
    $lnkFind = New-Control 'LinkLabel' 'winget ID 찾기 (winget.run 에서 검색)' 120 108 300 20
    $lnkFind.Add_LinkClicked({ Start-Process 'https://winget.run' })
    $dlg.Controls.Add($lnkFind)

    $rbFile = New-Control 'RadioButton' '설치파일로 설치 (사내 프로그램, 한글 등)' 16 138 470 22
    $dlg.Controls.Add($rbFile)
    $dlg.Controls.Add((New-Control 'Label' '설치파일' 36 168 80 20))
    $txtFile = New-Control 'TextBox' '' 120 165 290 24
    $dlg.Controls.Add($txtFile)
    $btnBrowse = New-Control 'Button' '찾아보기' 416 164 74 26
    $dlg.Controls.Add($btnBrowse)
    $dlg.Controls.Add((New-Control 'Label' '설치 옵션' 36 200 80 20))
    $txtArgs = New-Control 'TextBox' '' 120 197 370 24
    $dlg.Controls.Add($txtArgs)
    $lblArgsHelp = New-Control 'Label' '무인설치 옵션 예: /S, /silent, /quiet, /verysilent  (.msi 는 비워두면 자동)' 120 224 380 20
    $lblArgsHelp.ForeColor = [System.Drawing.Color]::Gray
    $dlg.Controls.Add($lblArgsHelp)

    $btnOk     = New-Control 'Button' '추가' 310 252 86 30
    $btnCancel = New-Control 'Button' '취소' 404 252 86 30
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($btnOk, $btnCancel))
    $dlg.CancelButton = $btnCancel

    $toggle = {
        $txtWinget.Enabled = $rbWinget.Checked
        $txtFile.Enabled = $btnBrowse.Enabled = $txtArgs.Enabled = $rbFile.Checked
    }
    $rbWinget.Add_CheckedChanged($toggle)
    $rbFile.Add_CheckedChanged($toggle)
    & $toggle

    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = '설치파일 (*.exe;*.msi)|*.exe;*.msi|모든 파일 (*.*)|*.*'
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtFile.Text = $ofd.FileName
            if (-not $txtPName.Text) { $txtPName.Text = [IO.Path]::GetFileNameWithoutExtension($ofd.FileName) }
        }
    })

    $btnOk.Add_Click({
        if (-not $txtPName.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('표시 이름을 입력하세요.') | Out-Null; return }
        if ($rbWinget.Checked -and -not $txtWinget.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('winget ID 를 입력하세요.') | Out-Null; return }
        if ($rbFile.Checked -and -not (Test-Path -LiteralPath $txtFile.Text)) { [System.Windows.Forms.MessageBox]::Show('설치파일을 선택하세요.') | Out-Null; return }
        $dlg.DialogResult = 'OK'
    })

    if ($dlg.ShowDialog($form) -ne 'OK') { return $null }

    $entry = [ordered]@{ name = $txtPName.Text.Trim() }
    if ($rbWinget.Checked) {
        $entry.winget = $txtWinget.Text.Trim()
    }
    else {
        $src = (Resolve-Path -LiteralPath $txtFile.Text).Path
        $installers = Join-Path $Root 'installers'
        $file = $src
        if (-not $src.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "설치파일을 이 도구의 installers 폴더로 복사할까요?`n(USB 등으로 옮겨도 함께 따라가도록)",
                '프로그램 추가', 'YesNo', 'Question')
            if ($ans -eq 'Yes') {
                if (-not (Test-Path $installers)) { New-Item -ItemType Directory -Path $installers | Out-Null }
                $file = Join-Path $installers ([IO.Path]::GetFileName($src))
                Copy-Item -LiteralPath $src -Destination $file -Force
            }
        }
        if ($file.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
            $file = $file.Substring($Root.Length).TrimStart('\')
        }
        $entry.file = $file
        if ($txtArgs.Text.Trim()) { $entry.args = $txtArgs.Text.Trim() }
    }
    return [pscustomobject]$entry
}

# ---------------------------------------------------------------------------
# 이벤트
# ---------------------------------------------------------------------------
$btnAdd.Add_Click({
    $new = Show-AddProgramDialog
    if ($null -eq $new) { return }
    $script:Config.programs = @(@($script:Config.programs) | Where-Object { $null -ne $_ }) + $new
    Save-Config $script:Config
    Update-ProgramList
})

$btnRemove.Add_Click({
    $idx = $clbPrograms.SelectedIndex
    if ($idx -lt 0) { [System.Windows.Forms.MessageBox]::Show('삭제할 프로그램을 목록에서 클릭하세요.') | Out-Null; return }
    $list = @($script:Config.programs)
    $ans = [System.Windows.Forms.MessageBox]::Show("'$($list[$idx].name)' 을(를) 목록에서 삭제할까요?", '삭제', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    $script:Config.programs = @(for ($i = 0; $i -lt $list.Count; $i++) { if ($i -ne $idx) { $list[$i] } })
    Save-Config $script:Config
    Update-ProgramList
})

$btnCheckAll.Add_Click({  for ($i = 0; $i -lt $clbPrograms.Items.Count; $i++) { $clbPrograms.SetItemChecked($i, $true) } })
$btnCheckNone.Add_Click({ for ($i = 0; $i -lt $clbPrograms.Items.Count; $i++) { $clbPrograms.SetItemChecked($i, $false) } })

$btnConfig.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$ConfigPath`"" })

$btnReload.Add_Click({
    try {
        $script:Config = Read-Config
        Update-ProgramList
        $lblStatus.Text = '설정을 다시 불러왔습니다.'
    }
    catch { [System.Windows.Forms.MessageBox]::Show("config.json 형식이 올바르지 않습니다.`n`n$($_.Exception.Message)", '오류', 'OK', 'Error') | Out-Null }
})

$btnLogs.Add_Click({
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    Start-Process explorer.exe -ArgumentList "`"$LogDir`""
})

$script:Running = $false
$controlsToLock = @($grpTasks, $grpName, $grpProg, $btnStart, $btnConfig, $btnReload)

$btnStart.Add_Click({
    $steps = @($TaskDefs | Where-Object { $TaskChecks[$_.Id].Checked })
    if ($steps.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('실행할 작업을 하나 이상 선택하세요.') | Out-Null; return }

    $newName = $txtName.Text.Trim()
    if ($newName -and $TaskChecks['misc'].Checked -and $newName -notmatch '^[A-Za-z0-9-]{1,15}$') {
        [System.Windows.Forms.MessageBox]::Show('PC 이름은 영문, 숫자, 하이픈(-)만 사용해 15자 이내로 입력하세요.') | Out-Null
        return
    }

    $all = @($script:Config.programs)
    $selected = @(foreach ($i in $clbPrograms.CheckedIndices) { $all[$i] })

    $summary = ($steps | ForEach-Object { " - $($_.Title)" }) -join "`n"
    $ans = [System.Windows.Forms.MessageBox]::Show("다음 작업을 시작합니다.`n`n$summary`n`n선택된 프로그램: $($selected.Count)개`n`n진행할까요?", 'PC 셋팅', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $logFile = Join-Path $LogDir ('setup_{0}_{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))

    $plan = @{
        Root         = $Root
        Config       = $script:Config
        Steps        = $steps
        Programs     = $selected
        ComputerName = $newName
        LogFile      = $logFile
    }

    $script:Sync = [hashtable]::Synchronized(@{
        Queue          = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Status         = '시작 중...'
        Percent        = 0
        StepCount      = 1
        Done           = $false
        RebootRequired = $false
    })

    $txtLog.Clear()
    foreach ($c in $controlsToLock) { $c.Enabled = $false }
    $script:Running = $true

    $script:Runspace = [runspacefactory]::CreateRunspace()
    $script:Runspace.ApartmentState = 'STA'
    $script:Runspace.Open()
    $script:PS = [powershell]::Create()
    $script:PS.Runspace = $script:Runspace
    [void]$script:PS.AddScript($Worker.ToString()).AddArgument($script:Sync).AddArgument($plan)
    $script:Handle = $script:PS.BeginInvoke()
    $timer.Start()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    $line = $null
    while ($script:Sync.Queue.TryDequeue([ref]$line)) { $txtLog.AppendText($line + "`r`n") }
    $progress.Value = [Math]::Min(100, [Math]::Max(0, [int]$script:Sync.Percent))
    $lblStatus.Text = $script:Sync.Status

    if (-not $script:Sync.Done) { return }

    $timer.Stop()
    try { $script:PS.EndInvoke($script:Handle) } catch { $txtLog.AppendText("[오류] $($_.Exception.Message)`r`n") }
    foreach ($e in $script:PS.Streams.Error) { $txtLog.AppendText("[오류] $e`r`n") }
    $script:PS.Dispose()
    $script:Runspace.Dispose()
    $script:Running = $false
    foreach ($c in $controlsToLock) { $c.Enabled = $true }

    $errors = @($txtLog.Lines | Where-Object { $_ -like '*`[ERROR`]*' }).Count
    $msg = if ($errors -gt 0) { "셋팅이 끝났습니다. 실패한 항목이 $errors 개 있습니다. 로그를 확인하세요." } else { '셋팅이 모두 끝났습니다.' }

    if ($script:Sync.RebootRequired) {
        $ans = [System.Windows.Forms.MessageBox]::Show("$msg`n`n재부팅이 필요한 항목이 있습니다. 지금 재부팅할까요?", 'PC 셋팅', 'YesNo', 'Question')
        if ($ans -eq 'Yes') { Restart-Computer -Force }
    }
    else {
        [System.Windows.Forms.MessageBox]::Show($msg, 'PC 셋팅', 'OK', 'Information') | Out-Null
    }
})

$form.Add_FormClosing({
    param($s, $e)
    if ($script:Running) {
        [System.Windows.Forms.MessageBox]::Show('작업이 진행 중입니다. 끝날 때까지 기다려 주세요.', 'PC 셋팅', 'OK', 'Warning') | Out-Null
        $e.Cancel = $true
    }
})

Update-ProgramList
[void]$form.ShowDialog()
