#Requires -Version 5.1
<#
    사내 PC 자동 셋팅 도구
    - Setup.bat 으로 실행하세요. (관리자 권한 자동 요청)
    - 설치할 프로그램, 프린터, 각종 설정 값은 config.json 에서 관리합니다.
    - 설치파일은 USB(이름: 프로그램USB)의 【 Application 】 폴더에서 자동으로 찾습니다.
    - 재부팅이 필요하면(윈도우 업데이트, 문서중앙화) 로그인 후 -Resume 으로 자동 실행되어 이어서 진행합니다.
    - PCSetup.exe 로 실행하면 exe 가 이 스크립트를 임시 폴더에 꺼내 -RootDir(exe 폴더)와 함께 실행합니다.
#>
param(
    [switch]$Resume,
    [string]$RootDir,       # config.json / logs 가 있는 폴더 (exe 로 실행할 때 exe 폴더)
    [string]$LauncherExe    # exe 로 실행했을 때 exe 경로 (재부팅 후 이어하기에 사용)
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root       = if ($RootDir) { $RootDir.TrimEnd('\') } else { $PSScriptRoot }
$ConfigPath = Join-Path $Root 'config.json'
$LogDir     = Join-Path $Root 'logs'
$ResumePath = Join-Path $env:ProgramData 'PCSetup\resume.json'

# ---------------------------------------------------------------------------
# 관리자 권한 확인
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show('관리자 권한으로 실행해야 합니다. Setup.bat 으로 실행하세요.', 'PC 셋팅', 'OK', 'Warning') | Out-Null
    exit 1
}

# 이미 실행 중이면 하나만 (재부팅 후 예약 작업과 시작 항목이 함께 실행되는 경우 등)
$script:AppMutex = New-Object System.Threading.Mutex($false, 'Global\PCSetupTool')
$owned = $false
try { $owned = $script:AppMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    if (-not $Resume) { [System.Windows.Forms.MessageBox]::Show('PC 셋팅 프로그램이 이미 실행 중입니다.', 'PC 셋팅', 'OK', 'Information') | Out-Null }
    exit 0
}

$RunOnceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$RunOnceName = 'PCSetupResume'

# ---------------------------------------------------------------------------
# 화면과 작업 쪽에서 함께 쓰는 함수
# ---------------------------------------------------------------------------
$Common = {
    # USB 의 【 Application 】 폴더 찾기: 라벨이 '프로그램USB' 인 드라이브 우선, 없으면 모든 드라이브 검색
    function Find-AppFolder($Cfg) {
        $name  = $Cfg.usb.appFolder
        $label = $Cfg.usb.label
        $disks = @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -in 2, 3 })
        $labeled = @($disks | Where-Object { $_.VolumeName -eq $label })
        $others  = @($disks | Where-Object { $_.VolumeName -ne $label })

        foreach ($d in $labeled + $others) {
            $p = Join-Path ($d.DeviceID + '\') $name
            if (Test-Path -LiteralPath $p) { return $p }
        }
        # 폴더 이름이 조금 다른 경우: USB 루트에서 *Application* 폴더
        foreach ($d in $labeled) {
            $m = Get-ChildItem -LiteralPath ($d.DeviceID + '\') -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like '*Application*' } | Select-Object -First 1
            if ($m) { return $m.FullName }
        }
        return $null
    }

    # 【 Application 】 폴더 안의 설치파일(.exe/.msi) 목록 (상대경로)
    function Get-AppFiles([string]$AppRoot) {
        if (-not $AppRoot) { return @() }
        @(Get-ChildItem -LiteralPath $AppRoot -Recurse -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -in '.exe', '.msi' -and $_.Name -notmatch '^unins' } |
          ForEach-Object { $_.FullName.Substring($AppRoot.Length).TrimStart('\') })
    }

    # 프로그램 항목의 설치파일 경로 찾기 (path 지정 > find 패턴 순서)
    # find 패턴의 {site} 는 지점 이름으로 바뀜 (예: *ERP*{site}*.exe → *ERP*부산*.exe)
    function Find-Installer([string]$AppRoot, $Files, $P, [string]$SiteName) {
        if ($P.path) {
            $full = $P.path
            if (-not [IO.Path]::IsPathRooted($full) -and $AppRoot) { $full = Join-Path $AppRoot $full }
            if (Test-Path -LiteralPath $full) { return $full }
        }
        if (-not $AppRoot) { return $null }
        foreach ($raw in @($P.find)) {
            if (-not $raw) { continue }
            $pattern = $raw.Replace('{site}', $(if ($SiteName) { $SiteName } else { '*' }))
            $hits = @($Files | Where-Object { $_ -like $pattern })
            if ($hits.Count -gt 0) {
                $best = $hits | Sort-Object Length | Select-Object -First 1
                return (Join-Path $AppRoot $best)
            }
        }
        return $null
    }

    # 【 Application 】 아래의 폴더 찾기 (지정 경로가 없으면 이름 패턴으로 검색)
    function Resolve-AppDir([string]$AppRoot, [string]$Relative, [string]$Pattern) {
        if (-not $AppRoot) { return $null }
        if ($Relative) {
            $p = Join-Path $AppRoot $Relative
            if (Test-Path -LiteralPath $p) { return $p }
        }
        if ($Pattern) {
            $m = Get-ChildItem -LiteralPath $AppRoot -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -like $Pattern } | Select-Object -First 1
            if ($m) { return $m.FullName }
        }
        return $null
    }

    function Test-Installed($P) {
        foreach ($i in @($P.installed)) {
            if (-not $i) { continue }
            if (Test-Path -Path ([Environment]::ExpandEnvironmentVariables($i))) { return $true }
        }
        return $false
    }

    # 프로그램 추가/제거 목록에서 이름이 맞는 항목 (제거 명령 포함)
    function Get-UninstallEntries([string]$Pattern) {
        $keys = @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
          Where-Object { $_.DisplayName -and $_.DisplayName -like $Pattern -and $_.UninstallString })
    }

    function Get-ActivationInfo {
        $os  = Get-CimInstance Win32_OperatingSystem
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
               Select-Object -First 1
        [pscustomobject]@{
            Caption   = $os.Caption
            Edition   = $reg.EditionID
            IsHome    = ($reg.EditionID -like 'Core*')
            Activated = ($null -ne $lic -and $lic.LicenseStatus -eq 1)
        }
    }
}
. $Common

# ---------------------------------------------------------------------------
# 설정 파일
# ---------------------------------------------------------------------------
function Read-Config {
    $c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # Adobe Reader 는 자동 설치에서 뺌 (마무리 체크리스트에서 직접 설치) - 예전 config.json 에 남아 있어도 목록에서 제외
    if ($c.programs) { $c.programs = @($c.programs | Where-Object { $_.name -notlike '*Adobe*' -and $_.winget -notlike 'Adobe.*' }) }
    return $c
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

    . ([scriptblock]::Create($Plan.CommonCode))

    $Cfg        = $Plan.Config
    $AppRoot    = $Plan.AppRoot
    $ResumePath = $Plan.ResumePath
    $RunOnceKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    $RunOnceName = 'PCSetupResume'
    $State      = @{ Step = 0; RestartExplorer = $false; ResumeHere = $false; ResumeRound = 0; UpdateReboot = $false }
    $IsWin11 = [Environment]::OSVersion.Version.Build -ge 22000

    function Write-Log([string]$Message, [string]$Level = 'INFO') {
        if ($Plan.LogPrefix) { $Message = "$($Plan.LogPrefix) $Message" }
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        $Sync.Queue.Enqueue($line)
        if ($Level -eq 'ERROR') { $Sync.ErrorCount = 1 + [int]$Sync.ErrorCount }
        elseif ($Level -eq 'WARN') { $Sync.WarnCount = 1 + [int]$Sync.WarnCount }
        # 윈도우 업데이트(백그라운드)와 같은 로그 파일에 쓰므로 잠금
        if ($Sync.LogLock) { [System.Threading.Monitor]::Enter($Sync.LogLock) }
        try { Add-Content -LiteralPath $Plan.LogFile -Value $line -Encoding UTF8 }
        finally { if ($Sync.LogLock) { [System.Threading.Monitor]::Exit($Sync.LogLock) } }
    }

    # 화면의 진행 상황 표시판에 상태 기록 (state: pending/running/manual/waitAck/done/skipped/warn/error/reboot)
    function Set-TaskState([string]$Id, [string]$StateName, [string]$Text = '') { if ($Sync.TaskStates) { $Sync.TaskStates[$Id] = "$StateName|$Text" } }
    function Set-ProgState([string]$Name, [string]$StateName, [string]$Text = '') { if ($Sync.ProgStates) { $Sync.ProgStates[$Name] = "$StateName|$Text" } }

    # 작업이 끝난 뒤 안내창에 보여줄 메시지
    function Add-Notice([string]$Message) { [void]$Sync.Notices.Add($Message) }

    function Set-Status([string]$Text) { $Sync.Status = $Text }

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

    function Expand-SiteText([string]$Text) {
        if (-not $Text) { return $Text }
        $server = if ($Plan.Site) { $Plan.Site.erpServer } else { '(지점을 선택하지 않음)' }
        return $Text.Replace('{erpServer}', $server)
    }

    # 화면 위에 항상 떠 있는 안내창 (설치 화면에서 직접 고를 것이 있을 때)
    function Show-Guide([string]$Title, [string]$Text) { $Sync.Guide = "[$Title]`n`n$(Expand-SiteText $Text)" }

    function Hide-Guide { $Sync.GuideWait = ''; $Sync.Guide = '' }

    function Start-InstallerProcess([string]$Path, [string]$Arguments) {
        if ($Path -like '*.msi') {
            $msiArgs = "/i `"$Path`" /qn /norestart"
            if ($Arguments) { $msiArgs += " $Arguments" }
            $proc = Start-Process msiexec.exe -ArgumentList $msiArgs -PassThru -ErrorAction Stop
        }
        else {
            $sp = @{ FilePath = $Path; PassThru = $true; ErrorAction = 'Stop'; WorkingDirectory = (Split-Path $Path) }
            if ($Arguments) { $sp.ArgumentList = $Arguments.Replace('{dir}', (Split-Path $Path)) }
            $proc = Start-Process @sp
        }
        $null = $proc.Handle   # 끝난 뒤 종료 코드를 읽으려면 미리 핸들을 잡아둬야 함
        return $proc
    }

    function Start-Installer([string]$Path, [string]$Arguments) {
        $proc = Start-InstallerProcess $Path $Arguments
        $proc.WaitForExit()
        return $proc.ExitCode
    }

    # --- 설치 화면 자동 조작 (버튼 클릭, 입력칸 채우기) ------------------------
    function Initialize-UIA {
        if (-not ('System.Windows.Automation.AutomationElement' -as [type])) {
            Add-Type -AssemblyName UIAutomationClient
            Add-Type -AssemblyName UIAutomationTypes
        }
    }

    function Test-LikeAny([string]$Text, [string]$Patterns) {
        foreach ($pt in $Patterns.Split('|')) { if ($Text -like $pt.Trim()) { return $true } }
        return $false
    }

    function Get-TopWindows {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        return @($root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))
    }

    function Find-UIControl($Window, $ControlType) {
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ControlType)
        $all = @($Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
        # 목록 항목은 스크롤로 가려져 있어도 처리해야 하므로 그대로 둠
        if ($ControlType -in [System.Windows.Automation.ControlType]::ListItem, [System.Windows.Automation.ControlType]::TreeItem, [System.Windows.Automation.ControlType]::DataItem) { return $all }
        # 창 자체가 최소화 등으로 안 보이면 걸러내지 않음
        $winOff = $false
        try { $winOff = $Window.Current.IsOffscreen } catch { }
        if ($winOff) { return $all }
        # 화면에 실제로 보이는 것만 (InstallShield 등은 다른 페이지의 [설치]/[닫기] 버튼을 숨긴 채 갖고 있음)
        return @($all | Where-Object { try { -not $_.Current.IsOffscreen } catch { $false } })
    }

    # 창 제목줄의 최소화/최대화/닫기(X) 버튼인지 (이름이 '닫기' 라서 설치 창을 닫아버리는 것 방지)
    function Test-TitleBarButton($Button) {
        if ($Button.Current.AutomationId -in 'Close', 'Minimize', 'Maximize', 'Restore', 'Help') { return $true }
        try {
            $parent = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($Button)
            if ($parent -and $parent.Current.ControlType -eq [System.Windows.Automation.ControlType]::TitleBar) { return $true }
        }
        catch { }
        return $false
    }

    function Find-UIButton($Window, [string]$Patterns) {
        foreach ($b in (Find-UIControl $Window ([System.Windows.Automation.ControlType]::Button))) {
            $name = ($b.Current.Name -replace '&', '').Trim()
            if ($name -and $b.Current.IsEnabled -and (Test-LikeAny $name $Patterns) -and -not (Test-TitleBarButton $b)) { return $b }
        }
        return $null
    }

    function Invoke-UIButton($Button) {
        $pattern = $null
        if ($Button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); return }
        $Button.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    }

    # 이름이 맞는 체크박스를 찾아 체크 해제. 찾은 체크박스 개수를 돌려줌
    # 이름이 맞는 체크 항목을 찾아 체크 해제. 찾은 개수를 돌려줌
    # - 일반 체크박스: 체크 상태를 읽어서 켜져 있을 때만 해제
    # - 목록 안의 체크 항목 (카카오톡 설치의 '구성 요소 선택' 목록 등): 상태를 읽을 수 없으면
    #   항목을 선택하고 스페이스로 한 번만 전환 (기본값이 체크된 항목이라 한 번 누르면 해제됨)
    function Clear-UICheckBoxes($Window, [string]$Patterns, [string]$Name, $Job) {
        $found = 0
        $types = @([System.Windows.Automation.ControlType]::CheckBox, [System.Windows.Automation.ControlType]::TreeItem,
                   [System.Windows.Automation.ControlType]::ListItem, [System.Windows.Automation.ControlType]::DataItem)
        foreach ($ct in $types) {
            foreach ($cb in (Find-UIControl $Window $ct)) {
                $label = ($cb.Current.Name -replace '&', '').Trim()
                if (-not $label -or -not (Test-LikeAny $label $Patterns)) { continue }
                $found++
                $tp = $null
                if ($cb.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp)) {
                    if ($tp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
                        $tp.Toggle()
                        Write-Log "${Name}: '$label' 체크 해제" 'OK'
                        Start-Sleep -Milliseconds 400
                    }
                }
                elseif ($Job -and -not $Job.Toggled.Contains($label)) {
                    $sp = $null
                    if ($cb.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $sp.Select() }
                    $cb.SetFocus()
                    Start-Sleep -Milliseconds 300
                    [System.Windows.Forms.SendKeys]::SendWait(' ')
                    [void]$Job.Toggled.Add($label)
                    Write-Log "${Name}: '$label' 체크 해제 (스페이스)" 'OK'
                    Start-Sleep -Milliseconds 400
                }
            }
        }
        return $found
    }

    # 입력칸이 여러 개면 비어 있거나 IP 처럼 생긴 칸을 고름
    function Set-UIText($Window, [string]$Text) {
        $edits = Find-UIControl $Window ([System.Windows.Automation.ControlType]::Edit)
        if ($edits.Count -eq 0) { return $false }
        $target = $edits[0]
        foreach ($ed in $edits) {
            $vp = $null
            if ($ed.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
                $v = $vp.Current.Value
                if (-not $v -or $v -match '^\d{1,3}(\.\d{1,3}){1,3}(:\d+)?') { $target = $ed; break }
            }
        }
        $vp = $null
        if ($target.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) -and -not $vp.Current.IsReadOnly) {
            $vp.SetValue($Text)
        }
        else {
            $target.SetFocus()
            [System.Windows.Forms.SendKeys]::SendWait('^a')
            [System.Windows.Forms.SendKeys]::SendWait($Text)
        }
        return $true
    }

    # config 의 auto 단계를 순서대로 처리 (한 번 호출에 한 동작씩, 여러 설치를 번갈아 처리)
    #   click     : 누를 버튼 이름 (예: "Finish*|마침*")
    #   alsoClick : click 버튼이 나올 때까지 계속 누를 버튼 (예: "다음*|Next*")
    #   setText   : 입력칸에 넣을 값 (예: "{erpServer}"), 넣은 뒤 click 버튼을 누름
    #   window    : 창 제목 패턴 (생략하면 그 설치 프로그램의 모든 창)
    #   uncheck   : 버튼을 누르기 전에 체크 해제할 체크박스 이름 (예: "*Daum*")
    #               이 체크박스를 한 번도 못 찾았으면 click 버튼을 누르지 않음 (체크된 채로 설치되는 것 방지)
    #   optional  : true 면 못 찾아도 실패로 보지 않고 다음 단계로
    #   timeout   : 이 단계를 기다릴 시간(초)
    #   process   : 설치 프로그램이 아닌 다른 프로그램의 창에서 찾기 (예: "OpenWith" 기본 앱 선택 창, "msedge")
    #               설치를 시작한 뒤에 실행된 그 이름의 프로그램 창만 대상
    #   select    : click 전에 목록에서 고를 항목 (예: "*Adobe*Acrobat*")
    #   close     : true 면 찾은 창을 닫음
    #   radio     : 매번 선택해 둘 라디오 버튼 (예: 사용권 계약 '동의합니다')
    #   windowText: 창 제목/글자에 이 패턴이 있는 창에서만 (예: "*재부팅*|*다시 시작*")
    #   waitIdle  : 버튼을 누르기 전에 윈도우 업데이트/다른 설치가 끝났는지 확인
    #               true = 항상, 글자 패턴 = 그 글자가 창에 있을 때만 (예: 마침 화면에 '다시 시작' 이 있으면)
    function Move-AutoStep($Job) {
        $Job.StepIdx++
        $Job.UncheckSeen = $false
        $Job.Selected = $false
        $Job.SeenAt = $null
        $Job.ClickTries = 0
        $Job.KeySince = $null
        $Job.LastAlso = [datetime]::MinValue
        $Job.PauseUntil = (Get-Date).AddSeconds(1)
        $steps = @($Job.P.auto)
        if ($Job.StepIdx -lt $steps.Count) {
            $t = if ($steps[$Job.StepIdx].timeout) { [int]$steps[$Job.StepIdx].timeout } else { 180 }
            $Job.Deadline = (Get-Date).AddSeconds($t)
        }
        else { Write-Log "$($Job.P.name): 설치 화면 자동 진행 완료" 'OK' }
    }

    # 목록에서 이름이 맞는 항목 선택 (기본 앱 선택 창의 'Adobe Acrobat' 등)
    function Select-UIItem($Window, [string]$Patterns) {
        $types = @([System.Windows.Automation.ControlType]::ListItem, [System.Windows.Automation.ControlType]::DataItem,
                   [System.Windows.Automation.ControlType]::TreeItem, [System.Windows.Automation.ControlType]::Button)
        foreach ($ct in $types) {
            foreach ($it in (Find-UIControl $Window $ct)) {
                $label = ($it.Current.Name -replace '&', '').Trim()
                if (-not $label -or -not (Test-LikeAny $label $Patterns)) { continue }
                $sp = $null
                if ($it.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp)) { $sp.Select(); return $label }
                $ip = $null
                if ($it.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke(); return $label }
            }
        }
        return $null
    }

    # 창 제목이나 창 안의 글자에 패턴이 있는지 (예: '재부팅', '다시 시작')
    function Test-WindowText($Window, [string]$Patterns) {
        if (Test-LikeAny $Window.Current.Name $Patterns) { return $true }
        foreach ($t in (Find-UIControl $Window ([System.Windows.Automation.ControlType]::Text))) {
            if (Test-LikeAny $t.Current.Name $Patterns) { return $true }
        }
        foreach ($t in (Find-UIControl $Window ([System.Windows.Automation.ControlType]::RadioButton))) {
            if (Test-LikeAny $t.Current.Name $Patterns) { return $true }
        }
        return $false
    }

    # 라디오 버튼 선택 (예: 사용권 계약 '동의합니다')
    function Select-UIRadio($Window, [string]$Patterns, [string]$Name) {
        foreach ($rb in (Find-UIControl $Window ([System.Windows.Automation.ControlType]::RadioButton))) {
            $label = ($rb.Current.Name -replace '&', '').Trim()
            if (-not $label -or -not (Test-LikeAny $label $Patterns)) { continue }
            $sp = $null
            if ($rb.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sp) -and -not $sp.Current.IsSelected) {
                $sp.Select()
                Write-Log "${Name}: '$label' 선택" 'OK'
                Start-Sleep -Milliseconds 400
            }
        }
    }

    # 재부팅 버튼을 누르기 전: 윈도우 업데이트 / 다른 설치가 끝났는지 확인 (최대 30분 대기)
    function Wait-RebootSafe($Job) {
        for ($i = 0; $i -lt 360; $i++) {
            if ($Sync.Cancel) { return $false }
            $busy = @()
            if ($Sync.Bg -and -not $Sync.Bg.Done) { $busy += '윈도우 업데이트(백그라운드)' }
            try { if ((New-Object -ComObject Microsoft.Update.Installer).IsBusy) { $busy += '윈도우 업데이트 설치' } } catch { }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress') { $busy += 'MSI 설치' }
            $busy += @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.SessionId -ne 0 -and -not $Job.Tree.Contains([int]$_.Id) -and
                ($_.ProcessName -eq 'msiexec' -or $_.ProcessName -match 'setup|install')
            } | ForEach-Object { $_.ProcessName })
            if ($busy.Count -eq 0) {
                Write-Log "$($Job.P.name): 윈도우 업데이트와 다른 설치가 모두 끝난 것을 확인했습니다." 'OK'
                return $true
            }
            if ($i % 12 -eq 0) { Write-Log "$($Job.P.name): 재부팅 전에 끝나기를 기다립니다 - $(($busy | Select-Object -Unique) -join ', ')" 'WARN' }
            Set-Status "$($Job.P.name): 재부팅 전에 업데이트/설치가 끝나기를 기다리는 중 ($(($busy | Select-Object -Unique) -join ', '))"
            Set-ProgState $Job.P.name 'running' '재부팅 전 확인 중 (업데이트/설치 대기)'
            Start-Sleep -Seconds 5
        }
        Write-Log "$($Job.P.name): 30분을 기다려도 업데이트/설치가 끝나지 않아 재부팅 버튼을 누르지 않았습니다. 확인 후 직접 눌러주세요." 'WARN'
        return $false
    }

    # 버튼을 프로그램이 찾을 수 없는 화면(반디집 등)용: 창 안의 비율 위치를 실제 마우스로 클릭
    # 창이 최소화됐거나 다른 창에 가려져 있으면 원래 크기로 꺼내 맨 앞으로 가져온 뒤,
    # 클릭할 위치에 정말 그 창이 있는지 확인하고 클릭. 확인이 안 되면 클릭하지 않고 $false (다음에 다시 시도)
    function Invoke-ClickAt($Window, $Points, [string]$Name) {
        if (-not ('PCSetup.Mouse2' -as [type])) {
            Add-Type -Namespace PCSetup -Name Mouse2 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(int flags, int dx, int dy, int data, System.IntPtr extra);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, System.IntPtr pid);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint flags);
[DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr ctx);
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public struct POINT { public int X; public int Y; }
'@
        }
        $M = [PCSetup.Mouse2]
        # 화면 배율(125%, 150%)에서도 좌표가 맞도록 이 작업 스레드만 DPI 인식으로
        # (클릭이 끝나면 원래대로 되돌림 - 그대로 두면 이후 창/화면이 작게 보일 수 있음)
        $oldCtx = [IntPtr]::Zero
        try { $oldCtx = $M::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch { }
        $h = [IntPtr]$Window.Current.NativeWindowHandle
        $topmost = $false
        try {
            # 1) 최소화돼 있으면 원래 크기로 (최대 5초 기다림)
            for ($i = 0; $i -lt 10 -and $M::IsIconic($h); $i++) {
                if ($i -eq 0) { Write-Log "${Name}: 설치 창이 최소화돼 있어 다시 띄웁니다." }
                [void]$M::ShowWindow($h, 9)
                Start-Sleep -Milliseconds 500
            }
            if ($M::IsIconic($h)) { return $false }
            [void]$M::ShowWindow($h, 5)
            # 2) 맨 앞으로 (다른 프로그램이 앞에 있어도 가져올 수 있도록 입력 스레드를 잠깐 연결)
            $fgThread = $M::GetWindowThreadProcessId($M::GetForegroundWindow(), [IntPtr]::Zero)
            $myThread = $M::GetCurrentThreadId()
            $attached = $false
            if ($fgThread -ne 0 -and $fgThread -ne $myThread) { $attached = $M::AttachThreadInput($myThread, $fgThread, $true) }
            [void]$M::BringWindowToTop($h)
            [void]$M::SetForegroundWindow($h)
            if ($attached) { [void]$M::AttachThreadInput($myThread, $fgThread, $false) }
            # 클릭하는 동안만 '항상 위' (안내창 등 다른 창에 가리지 않도록)
            [void]$M::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
            $topmost = $true
            Start-Sleep -Milliseconds 500

            # 3) 클릭할 위치마다 정말 그 창이 있는지 먼저 확인 (하나라도 아니면 아무것도 클릭하지 않음)
            $r = New-Object PCSetup.Mouse2+RECT
            [void]$M::GetWindowRect($h, [ref]$r)
            $xy = @()
            foreach ($pt in @($Points)) {
                $x = [int]($r.Left + ($r.Right - $r.Left) * [double]$pt[0])
                $y = [int]($r.Top + ($r.Bottom - $r.Top) * [double]$pt[1])
                $p = New-Object PCSetup.Mouse2+POINT
                $p.X = $x; $p.Y = $y
                $hit = $M::GetAncestor($M::WindowFromPoint($p), 2)
                if ($hit -ne $h) { return $false }
                $xy += , @($x, $y, $pt)
            }

            # 4) 클릭
            foreach ($c in $xy) {
                [void]$M::SetCursorPos($c[0], $c[1])
                Start-Sleep -Milliseconds 150
                $M::mouse_event(0x02, 0, 0, 0, [IntPtr]::Zero)   # 왼쪽 버튼 누름
                $M::mouse_event(0x04, 0, 0, 0, [IntPtr]::Zero)   # 뗌
                Write-Log "${Name}: 창 위치 ($($c[2][0]), $($c[2][1])) 클릭" 'OK'
                Start-Sleep -Milliseconds 800
            }
            return $true
        }
        finally {
            if ($topmost) { try { [void]$M::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0013) } catch { } }
            if ($oldCtx -ne [IntPtr]::Zero) { try { [void]$M::SetThreadDpiAwarenessContext($oldCtx) } catch { } }
        }
    }

    # 자동 진행이 멈췄을 때 그 창의 버튼/체크박스 이름을 로그에 남김 (설정을 맞추기 위한 참고용)
    function Write-WindowDump($Windows, [string]$Name) {
        foreach ($w in @($Windows | Select-Object -First 4)) {
            try {
                $btns = @(Find-UIControl $w ([System.Windows.Automation.ControlType]::Button) | ForEach-Object { $_.Current.Name } | Where-Object { $_ } | Select-Object -First 15)
                $chks = @(Find-UIControl $w ([System.Windows.Automation.ControlType]::CheckBox) | ForEach-Object { $_.Current.Name } | Where-Object { $_ } | Select-Object -First 10)
                Write-Log "${Name}: [참고] 창 '$($w.Current.Name)' 버튼: $($btns -join ' / ')  체크: $($chks -join ' / ')"
            }
            catch { }
        }
    }

    # 작업표시줄에 최소화된 창을 원래 크기로 (예: 반디집 설치 후 '환경 설정' 창)
    function Restore-UIWindow($Window) {
        $wp = $null
        if ($Window.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp) -and
            $wp.Current.WindowVisualState -eq [System.Windows.Automation.WindowVisualState]::Minimized) {
            $wp.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
            Start-Sleep -Milliseconds 600
        }
    }

    function Step-AutoJob($Job, $Windows, $AllWindows, $Procs) {
        $steps = @($Job.P.auto)
        if ($Job.Manual -or $Job.StepIdx -ge $steps.Count) { return }
        if ((Get-Date) -lt $Job.PauseUntil) { return }
        $st = $steps[$Job.StepIdx]
        $name = $Job.P.name

        # 다른 프로그램(기본 앱 선택 창, 엣지 등)의 창에서 찾는 단계
        if ($st.process) {
            $ids = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($pr in $Procs) {
                $pn = [IO.Path]::GetFileNameWithoutExtension([string]$pr.Name)
                # anyAge: 설치 전부터 실행 중이던 프로그램도 포함 (예: 뒤에서 미리 실행돼 있던 엣지)
                if ($pn -and (Test-LikeAny $pn $st.process) -and ($st.anyAge -or $pr.CreationDate -ge $Job.Since)) { [void]$ids.Add([int]$pr.ProcessId) }
            }
            $Windows = @(foreach ($w in $AllWindows) { try { if ($ids.Contains([int]$w.Current.ProcessId)) { $w } } catch { } })
        }

        if ($st.close) {
            $closed = 0
            foreach ($w in $Windows) {
                try {
                    if ($st.window -and -not (Test-LikeAny $w.Current.Name $st.window)) { continue }
                    $wp = $null
                    if ($w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp)) { $wp.Close(); $closed++ }
                }
                catch { }
            }
            if ($closed -gt 0) {
                Write-Log "${name}: $($st.process) 창 $closed 개 닫기" 'OK'
                Move-AutoStep $Job
                return
            }
        }

        if ((Get-Date) -gt $Job.Deadline) {
            if ($st.optional) {
                Write-Log "${name}: 자동 진행 $($Job.StepIdx + 1) 단계 화면이 없어 넘어갑니다."
                Move-AutoStep $Job
                return
            }
            Write-Log "${name}: 자동 진행 $($Job.StepIdx + 1) 단계에서 화면을 찾지 못했습니다. 안내창을 보고 직접 진행해 주세요." 'WARN'
            Write-WindowDump $Windows $name
            Set-ProgState $name 'manual' '직접 진행 필요 (노란 안내창 참고)'
            $Job.Manual = $true
            return
        }

        # 창 안의 위치를 마우스로 클릭하는 단계 (clickAt: [[가로비율, 세로비율], ...])
        #   delay        : 창이 보인 뒤 기다릴 시간(초)
        #   whenInstalled: 설치 파일이 생긴 뒤(설치가 끝난 뒤)에만 클릭
        #   untilClosed  : 창이 닫힐 때까지 5초마다 다시 클릭 (최대 3번)
        if ($st.clickAt) {
            $cands = @(foreach ($w in $Windows) { try { if (-not $st.window -or (Test-LikeAny $w.Current.Name $st.window)) { $w } } catch { } })
            if ($cands.Count -eq 0) {
                if ($st.untilClosed -and $Job.ClickTries -gt 0) { Move-AutoStep $Job }
                return
            }
            if ($cands.Count -gt 1) { return }   # 팝업이 떠 있으면 닫힐 때까지 기다림
            if ($st.whenInstalled -and -not (Test-Installed $Job.P)) { return }
            if (-not $Job.SeenAt) { $Job.SeenAt = Get-Date; return }
            $delay = if ($null -ne $st.delay) { [double]$st.delay } else { 2 }
            if (((Get-Date) - $Job.SeenAt).TotalSeconds -lt $delay) { return }
            if ($Job.ClickTries -gt 0) {
                if (((Get-Date) - $Job.LastClick).TotalSeconds -lt 5) { return }
                if (-not $st.untilClosed -or $Job.ClickTries -ge 3) { Move-AutoStep $Job; return }
            }
            $ok = $false
            try { $ok = Invoke-ClickAt $cands[0] $st.clickAt $name } catch { Write-Log "${name}: 위치 클릭 오류 - $($_.Exception.Message)" 'WARN' }
            if (-not $ok) {
                # 창을 앞으로 가져오지 못했거나 다른 창에 가려짐 → 클릭하지 않고 2초 뒤 다시 시도
                if (-not $Job.ClickWarned) { Write-Log "${name}: 설치 창이 가려져 있어 앞으로 가져온 뒤 다시 시도합니다." 'WARN'; $Job.ClickWarned = $true }
                $Job.PauseUntil = (Get-Date).AddSeconds(2)
                return
            }
            $Job.ClickWarned = $false
            $Job.ClickTries++
            $Job.LastClick = Get-Date
            if (-not $st.untilClosed) { Move-AutoStep $Job }
            return
        }

        if ($st.close) { return }
        foreach ($w in $Windows) {
            try {
                if ($st.window -and -not (Test-LikeAny $w.Current.Name $st.window)) { continue }
                if ($st.windowText -and -not (Test-WindowText $w $st.windowText)) { continue }
                if ($st.restore) { Restore-UIWindow $w }
                if ($st.radio) { Select-UIRadio $w $st.radio $name }
                if ($st.select -and -not $Job.Selected) {
                    $picked = Select-UIItem $w $st.select
                    if (-not $picked) { continue }
                    $Job.Selected = $true
                    Write-Log "${name}: '$picked' 선택" 'OK'
                    Start-Sleep -Milliseconds 500
                }
                if ($st.uncheck -and (Clear-UICheckBoxes $w $st.uncheck $name $Job) -gt 0) { $Job.UncheckSeen = $true }
                $btn = $null
                if ($st.click -and ($Job.UncheckSeen -or -not $st.uncheck)) { $btn = Find-UIButton $w $st.click }

                if ($st.setText) {
                    if ($st.click -and -not $btn) { continue }
                    $text = Expand-SiteText $st.setText
                    if (-not (Set-UIText $w $text)) { continue }
                    Write-Log "${name}: '$text' 자동 입력" 'OK'
                    Start-Sleep -Milliseconds 500
                    if ($btn) { $bn = $btn.Current.Name; Invoke-UIButton $btn; Write-Log "${name}: [$bn] 자동 클릭" 'OK' }
                    Move-AutoStep $Job
                    return
                }
                if ($btn) {
                    $bn = $btn.Current.Name
                    $needWait = $false
                    if ($st.waitIdle -is [bool]) { $needWait = $st.waitIdle }
                    elseif ($st.waitIdle) { $needWait = Test-WindowText $w ([string]$st.waitIdle) }
                    if ($needWait) {
                        Write-Log "${name}: [$bn] 을 누르면 재부팅될 수 있어 업데이트/다른 설치가 끝났는지 먼저 확인합니다."
                        if (-not (Wait-RebootSafe $Job)) { $Job.Manual = $true; Set-ProgState $name 'manual' '재부팅 버튼을 직접 눌러주세요'; return }
                        Write-Log "${name}: 재부팅을 진행합니다." 'OK'
                    }
                    Invoke-UIButton $btn
                    Write-Log "${name}: [$bn] 자동 클릭" 'OK'
                    Move-AutoStep $Job
                    return
                }
                if ($st.alsoClick -and ((Get-Date) - $Job.LastAlso).TotalSeconds -ge 2) {
                    $b2 = Find-UIButton $w $st.alsoClick
                    if ($b2) {
                        $bn = $b2.Current.Name
                        Invoke-UIButton $b2
                        Write-Log "${name}: [$bn] 자동 클릭"
                        $Job.LastAlso = Get-Date
                        return
                    }
                }
                # 버튼을 찾지 못했지만 이 화면이 맞으면 5초 뒤 키 입력 (예: 카카오톡 설치 완료 → Enter = 마침)
                if ($st.fallbackKeys -and -not $btn) {
                    if (-not $Job.KeySince) { $Job.KeySince = Get-Date }
                    elseif (((Get-Date) - $Job.KeySince).TotalSeconds -ge 5) {
                        $w.SetFocus()
                        Start-Sleep -Milliseconds 300
                        [System.Windows.Forms.SendKeys]::SendWait([string]$st.fallbackKeys)
                        Write-Log "${name}: 버튼 대신 키 입력 $($st.fallbackKeys)" 'OK'
                        Move-AutoStep $Job
                        return
                    }
                }
            }
            catch { }   # 읽는 도중 창이 닫힌 경우
        }
    }

    function Restart-Explorer {
        if (-not $State.RestartExplorer) { return }
        Write-Log '변경 사항 적용을 위해 탐색기를 다시 시작합니다.'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $State.RestartExplorer = $false
    }

    # --- 1. 이더넷 IP ---------------------------------------------------------
    function Set-Network {
        $n = $Plan.Network
        $idx = $n.IfIndex
        $adapter = Get-NetAdapter -InterfaceIndex $idx -ErrorAction Stop
        Write-Log "어댑터: $($adapter.Name) ($($adapter.InterfaceDescription), $($adapter.Status))"

        if ($n.Dhcp) {
            # 자동으로 IP 주소 받기 + DNS 자동
            Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
            Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction Stop
            & ipconfig.exe /renew "$($adapter.Name)" *> $null
            Set-Status 'IP 주소를 자동으로 받는 중...'
            $ip = $null
            for ($i = 0; $i -lt 15; $i++) {
                $ip = Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                      Where-Object { $_.PrefixOrigin -eq 'Dhcp' } | Select-Object -First 1
                if ($ip) { break }
                Start-Sleep -Seconds 2
            }
            if ($ip) { Write-Log "자동으로 IP 주소 받기 설정 완료: $($ip.IPAddress)" 'OK' }
            else {
                Write-Log '자동으로 IP 주소 받기로 설정했지만 아직 IP를 받지 못했습니다. 랜선 연결을 확인하세요.' 'WARN'
                Add-Notice '네트워크: 자동으로 IP 주소를 받지 못했습니다. 랜선 연결을 확인하세요.'
            }
            return
        }

        $current = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        if ($current -notcontains $n.IP) {
            Set-Status "IP 사용 여부 확인 중: $($n.IP)"
            if (Test-Connection -ComputerName $n.IP -Count 2 -Quiet -ErrorAction SilentlyContinue) {
                Write-Log "IP $($n.IP) 는 이미 다른 장치가 사용 중입니다. IP 설정을 건너뜁니다." 'ERROR'
                Add-Notice "IP 충돌: $($n.IP) 를 다른 장치가 사용 중이라 IP를 설정하지 않았습니다. 다른 IP로 다시 실행하세요."
                return
            }
        }

        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
        Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -IPAddress $n.IP -PrefixLength $n.Prefix -DefaultGateway $n.Gateway -ErrorAction Stop | Out-Null

        $dns = @($n.Dns | Where-Object { $_ })
        if ($dns.Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $dns -ErrorAction Stop }
        Write-Log "IP $($n.IP) / 서브넷 $($n.Subnet) / 게이트웨이 $($n.Gateway) / DNS $($dns -join ', ')" 'OK'

        Set-Status '네트워크 연결 확인 중...'
        $ok = $false
        for ($i = 0; $i -lt 10; $i++) {
            if (Test-Connection -ComputerName $n.Gateway -Count 1 -Quiet -ErrorAction SilentlyContinue) { $ok = $true; break }
            Start-Sleep -Seconds 2
        }
        if ($ok) { Write-Log '게이트웨이 연결 확인' 'OK' }
        else {
            Write-Log '게이트웨이가 응답하지 않습니다. 랜선 연결과 IP를 확인하세요.' 'WARN'
            Add-Notice '네트워크: 게이트웨이 응답이 없습니다. 랜선 연결과 IP/게이트웨이를 확인하세요.'
        }
    }

    # --- 2. 프로그램 설치 (여러 개를 간격을 두고 동시에) --------------------------
    function New-InstallJob($P, [string]$Path) {
        return @{
            P = $P; Path = $Path; State = 'pending'; Proc = $null; Tree = $null; Since = $null; Code = $null
            StepIdx = 0; Deadline = [datetime]::MaxValue; PauseUntil = [datetime]::MinValue; LastAlso = [datetime]::MinValue
            UncheckSeen = $false; Manual = $false; Alive = $true; Failed = $false; Retried = $false; LastDismiss = [datetime]::MinValue
            Toggled = (New-Object 'System.Collections.Generic.HashSet[string]'); Selected = $false; DeadSince = $null; FallbackP = $null
            SeenAt = $null; ClickTries = 0; LastClick = [datetime]::MinValue; KeySince = $null
        }
    }

    function Start-InstallJob($Job) {
        $p = $Job.P
        if ($p.clipboard) {
            $clip = Expand-SiteText $p.clipboard
            [System.Windows.Forms.Clipboard]::SetText($clip)
            Write-Log "$($p.name): '$clip' 를 클립보드에 복사했습니다. (Ctrl+V 로 붙여넣기)"
        }
        $Job.Since = (Get-Date).AddSeconds(-2)
        $installArgs = if ($Job.Path -like '*.msi') { $p.argsMsi } else { $p.args }   # msi 는 자동으로 /qn
        # argsMatch: 설치 파일 이름에 따라 다른 옵션 (예: Adobe 오프라인 설치 파일 AcroRdr*.exe → 자동 설치)
        if ($p.argsMatch) {
            foreach ($pr in $p.argsMatch.PSObject.Properties) {
                if ([IO.Path]::GetFileName($Job.Path) -like $pr.Name) { $installArgs = [string]$pr.Value; $Job.SilentByMatch = $true }
            }
        }
        $Job.Proc  = Start-InstallerProcess $Job.Path $installArgs
        $Job.Tree  = New-Object 'System.Collections.Generic.HashSet[int]'
        [void]$Job.Tree.Add($Job.Proc.Id)
        $Job.State = 'running'
        $runText = if ($p.uninstall) { '삭제 중' } elseif ($p.auto) { '자동 진행 중' } elseif ($p.args) { '자동 설치 중' } else { '설치 화면에서 진행해 주세요' }
        Set-ProgState $p.name $(if ($p.auto -or $p.args -or $p.uninstall) { 'running' } else { 'manual' }) $runText
        if ($p.auto) {
            $first = @($p.auto)[0]
            $Job.Deadline = (Get-Date).AddSeconds($(if ($first.timeout) { [int]$first.timeout } else { 180 }))
        }
        $how = if ($p.uninstall) { '삭제' } elseif ($p.auto) { '자동 진행' } elseif ($p.args) { '자동 설치' } else { '설치 화면에서 직접 진행' }
        Write-Log "$($p.name): 시작 ($how) - $($Job.Path) $($p.args)"
    }

    # 설치 프로그램과 그 프로그램이 띄운 하위 프로그램(Client Update 등)을 묶어서 추적
    function Update-JobTree($Job, $Procs, $AliveIds) {
        $added = $true
        while ($added) {
            $added = $false
            foreach ($pr in $Procs) {
                $id = [int]$pr.ProcessId
                if ($Job.Tree.Contains($id)) { continue }
                if ($Job.Tree.Contains([int]$pr.ParentProcessId) -and $pr.CreationDate -ge $Job.Since) {
                    [void]$Job.Tree.Add($id)
                    $added = $true
                }
            }
        }
        $Job.Alive = $false
        foreach ($id in $Job.Tree) { if ($AliveIds.Contains($id)) { $Job.Alive = $true; break } }
    }

    function Complete-InstallJob($Job) {
        $Job.State = 'done'
        $Job.Code = $Job.Proc.ExitCode
        $name = $Job.P.name
        if ($Job.P.uninstall) {
            if (@(Get-UninstallEntries $Job.P.uninstall).Count -eq 0) { Write-Log "${name}: 삭제 완료" 'OK'; Set-ProgState $name 'done' '삭제 완료' }
            else { Write-Log "${name}: 삭제가 끝나지 않았습니다. (종료 코드 $($Job.Code)) 프로그램 추가/제거에서 확인하세요." 'WARN'; Set-ProgState $name 'warn' '삭제 확인 필요' }
            return
        }
        # 설치 프로그램이 정상 종료 코드로 끝나도(창을 닫아도 0 이 나올 수 있음) 실제 설치 파일이 있는지 확인
        $code = $Job.Code
        if ($code -in 0, 3010, 1641 -and @($Job.P.installed | Where-Object { $_ }).Count -gt 0 -and -not (Test-Installed $Job.P)) {
            Start-Sleep -Seconds 5   # 설치 마무리가 조금 늦는 경우
            if (-not (Test-Installed $Job.P)) {
                Write-Log "${name}: 설치 프로그램은 끝났지만(종료 코드 $code) 설치된 파일이 없습니다." 'WARN'
                $code = -2
            }
        }
        switch ($code) {
            0       { Write-Log "${name}: 설치 완료 (설치 확인됨)" 'OK'; Set-ProgState $name 'done' '설치 완료' }
            3010    { Write-Log "${name}: 설치 완료 (재부팅 필요)" 'OK'; $Sync.RebootRequired = $true; Set-ProgState $name 'done' '설치 완료 (재부팅 후 적용)' }
            1641    { Write-Log "${name}: 설치 완료 (재부팅 필요)" 'OK'; $Sync.RebootRequired = $true; Set-ProgState $name 'done' '설치 완료 (재부팅 후 적용)' }
            1618    {
                Write-Log "${name}: 다른 설치가 진행 중이라 설치하지 못했습니다. 나중에 다시 설치합니다." 'WARN'
                Set-ProgState $name $(if ($Job.Retried) { 'error' } else { 'pending' }) $(if ($Job.Retried) { '설치 실패 (다른 설치와 겹침)' } else { '다시 설치 대기' })
            }
            default {
                if (Test-Installed $Job.P) { Write-Log "${name}: 설치 완료 (종료 코드 $($Job.Code))" 'OK'; Set-ProgState $name 'done' '설치 완료' }
                else {
                    $Job.Failed = $true
                    $again = if (-not $Job.Retried) { ' - 마지막에 한 번 더 설치합니다' } else { '' }
                    $why = if ($code -eq -2) { '설치되지 않음' } else { "종료 코드 $($Job.Code)" }
                    Write-Log "${name}: 설치 실패 ($why)$again" $(if ($again) { 'WARN' } else { 'ERROR' })
                    if ($again) { Set-ProgState $name 'pending' "다시 설치 대기 ($why)" }
                    else { Set-ProgState $name 'error' "설치 실패 ($why)" }
                }
            }
        }
    }

    function Update-InstallJob($Job, $Procs, $AliveIds, $Windows) {
        Update-JobTree $Job $Procs $AliveIds
        if ($Job.State -eq 'running' -and ($Job.P.auto -or $Job.P.dismiss)) {
            # (설치 프로그램이 끝난 뒤에도 다른 프로그램 창을 처리하는 단계가 남아 있을 수 있음)
            $mine = @(foreach ($w in $Windows) { try { if ($Job.Tree.Contains([int]$w.Current.ProcessId)) { $w } } catch { } })
            # 중간에 뜨는 팝업/마지막 화면 버튼은 보이면 바로 누름
            # (예: 반디집 '새 버전 홈페이지 방문?' → 아니요, 카카오톡 설치 완료 → 마침)
            if ($Job.P.dismiss -and ((Get-Date) - $Job.LastDismiss).TotalSeconds -ge 1) {
                foreach ($w in $mine) {
                    try {
                        # dismissWhen 이 있으면 그 문구가 있는 창에서만 (예: '취소하시겠습니까?' → 아니오)
                        if ($Job.P.dismissWhen -and -not (Test-WindowText $w $Job.P.dismissWhen)) { continue }
                        $b = Find-UIButton $w $Job.P.dismiss
                        if ($b) {
                            $bn = $b.Current.Name
                            Invoke-UIButton $b
                            Write-Log "$($Job.P.name): 팝업 [$bn] 자동 클릭" 'OK'
                            $Job.LastDismiss = Get-Date
                            break
                        }
                    }
                    catch { }
                }
            }
            if ($Job.P.auto) { Step-AutoJob $Job $mine $Windows $Procs }
        }
        if (-not $Job.Proc.HasExited) { return }

        $steps = @($Job.P.auto)
        $autoPending = $Job.P.auto -and -not $Job.Manual -and $Job.StepIdx -lt $steps.Count
        if ($autoPending) {
            # 설치 창이 모두 닫힌 지 20초가 지났는데 설치 창에서 버튼을 누를 단계가 남아 있으면
            # (사용자가 직접 마침을 누른 경우 등) 그 단계는 끝난 것으로 보고 넘어감
            # 입력칸 채우기(ERP 서버 주소)와 다른 프로그램 창 단계는 건너뛰지 않음
            $cur = $steps[$Job.StepIdx]
            if ($Job.Alive) { $Job.DeadSince = $null }
            elseif (-not $Job.DeadSince) { $Job.DeadSince = Get-Date }
            elseif (((Get-Date) - $Job.DeadSince).TotalSeconds -ge 20 -and -not $cur.process -and -not $cur.setText) {
                Write-Log "$($Job.P.name): 설치 창이 닫혀 $($Job.StepIdx + 1) 단계를 건너뜁니다."
                Move-AutoStep $Job
                $Job.DeadSince = $null
                return
            }
            # 남은 단계가 모두 '없어도 되는' 단계이고 관련 프로그램이 모두 끝났으면 완료
            # 단, 다른 프로그램 창(기본 앱 선택, 엣지)을 처리하는 단계는 설치 프로그램이 끝난 뒤에 뜨므로 기다림
            $rest = @($steps | Select-Object -Skip $Job.StepIdx | Where-Object { -not $_.optional -or $_.process })
            if ($rest.Count -eq 0 -and -not $Job.Alive) { Complete-InstallJob $Job }
            return   # 아니면 다음 화면(Client Update 등)을 기다림 (제한시간이 지나면 직접 진행으로 전환)
        }
        if ($Job.Manual -and $Job.P.confirmAfter) {
            if ($Job.State -ne 'waitAck') {
                $Job.State = 'waitAck'
                Set-ProgState $Job.P.name 'waitAck' '끝나면 노란 안내창의 [완료] 를 눌러주세요'
                Write-Log "$($Job.P.name): 직접 진행을 마친 뒤 안내창의 [완료] 를 눌러주세요."
            }
            if ($Sync.GuideAck -eq $Job.P.name) { $Sync.GuideAck = ''; Complete-InstallJob $Job }
            return
        }
        Complete-InstallJob $Job
    }

    function Invoke-InstallJobs($Jobs, [int]$Gap, [bool]$Parallel) {
        $needUia = @($Jobs | Where-Object { $_.P.auto }).Count -gt 0
        if ($needUia) { Initialize-UIA }
        $next = Get-Date
        $batchStart = Get-Date
        $total = $Jobs.Count
        while ($true) {
            $open = @($Jobs | Where-Object { $_.State -ne 'done' })
            if ($open.Count -eq 0) { break }
            if ($Sync.Cancel) { Write-Log '중지 요청으로 프로그램 설치를 멈춥니다. (이미 실행된 설치 창은 그대로 남아 있습니다)' 'WARN'; break }

            $running = @($Jobs | Where-Object { $_.State -in 'running', 'waitAck' })
            $pending = @($Jobs | Where-Object { $_.State -eq 'pending' })
            $canStart = if ($Parallel) { (Get-Date) -ge $next -or $running.Count -eq 0 } else { $running.Count -eq 0 }
            if ($pending.Count -gt 0 -and $canStart) {
                try { Start-InstallJob $pending[0] }
                catch { Write-Log "$($pending[0].P.name): 설치 시작 실패 - $($_.Exception.Message)" 'ERROR'; $pending[0].State = 'done'; $pending[0].Code = -1 }
                $next = (Get-Date).AddSeconds($Gap)
            }

            $procs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name -ErrorAction SilentlyContinue)
            $aliveIds = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($pr in $procs) { [void]$aliveIds.Add([int]$pr.ProcessId) }
            $windows = if ($needUia) { Get-TopWindows } else { @() }
            foreach ($j in @($Jobs | Where-Object { $_.State -in 'running', 'waitAck' })) {
                try { Update-InstallJob $j $procs $aliveIds $windows }
                catch { Write-Log "$($j.P.name): 상태 확인 오류 - $($_.Exception.Message)" 'WARN' }
            }

            # 안내창: 진행 중인 설치들의 안내를 모아서 표시
            $active = @($Jobs | Where-Object { $_.State -in 'running', 'waitAck' -and $_.P.guide })
            $Sync.Guide = (@($active | ForEach-Object {
                $tag = if ($_.State -eq 'waitAck') { '  ← 끝나면 [완료]' } elseif ($_.Manual) { '  (직접 진행)' } else { '' }
                "■ $($_.P.name)$tag`r`n$((Expand-SiteText $_.P.guide) -replace "`n", "`r`n")"
            }) -join "`r`n`r`n")
            $waiting = @($Jobs | Where-Object { $_.State -eq 'waitAck' } | Select-Object -First 1)
            $Sync.GuideWait = if ($waiting.Count) { $waiting[0].P.name } else { '' }

            $done = @($Jobs | Where-Object { $_.State -eq 'done' }).Count
            $names = (@($Jobs | Where-Object { $_.State -in 'running', 'waitAck' } | ForEach-Object { $_.P.name })) -join ', '
            Set-Status "프로그램 설치 중: $names  (완료 $done/$total, 대기 $($pending.Count)) · $(Get-Eta $batchStart $done $total)"
            Set-StepProgress $done $total
            Start-Sleep -Milliseconds 800
        }
        Hide-Guide
    }

    # 프로그램 추가/제거의 제거 명령으로 삭제 작업 만들기 (예: OneDrive)
    function New-UninstallJobs($P) {
        $entries = @(Get-UninstallEntries $P.uninstall)
        if ($entries.Count -eq 0) { Write-Log "$($P.name): 프로그램 추가/제거에 없어 건너뜀 (이미 삭제됨)" 'OK'; Set-ProgState $P.name 'skipped' '이미 없음'; return @() }
        foreach ($proc in @($P.stopProcess)) { if ($proc) { Stop-Process -Name $proc -Force -ErrorAction SilentlyContinue } }
        $jobs = @()
        foreach ($en in $entries) {
            $cmd = [Environment]::ExpandEnvironmentVariables($en.UninstallString.Trim())
            if ($cmd -match '^"([^"]+)"\s*(.*)$' -or $cmd -match '^(.+?\.exe)\s*(.*)$') {
                $exe = $matches[1]; $arg = $matches[2].Trim()
                if ($P.extraArgs) { $arg = "$arg $($P.extraArgs)".Trim() }
                $jp = [pscustomobject]@{ name = $P.name; uninstall = $P.uninstall; args = $arg }
                $jobs += New-InstallJob $jp $exe
                Write-Log "$($P.name): '$($en.DisplayName)' 삭제 예정"
            }
            else { Write-Log "$($P.name): 제거 명령을 해석하지 못했습니다: $cmd" 'WARN' }
        }
        return $jobs
    }

    # 엣지 첫 실행 화면(데이터 없이 시작 / Google 데이터 / 허용 안 함)이 뜨지 않도록 정책 설정
    function Disable-EdgeFirstRun {
        $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        try {
            Set-Reg $key 'HideFirstRunExperience' 1            # 첫 실행 화면 숨김
            Set-Reg $key 'PersonalizationReportingEnabled' 0   # 'Microsoft 환경을 더 유용하게' → 허용 안 함
            Set-Reg $key 'AutoImportAtFirstRun' 4              # Google 등 다른 브라우저 데이터 가져오지 않음
            Set-Reg $key 'StartupBoostEnabled' 0               # 뒤에서 미리 실행되지 않도록 (설정이 바로 적용되게)
            Set-Reg $key 'BackgroundModeEnabled' 0
            # 이미 뒤에서 실행 중인 엣지는 위 설정을 아직 모르므로 종료 → 다음에 열 때 설정 적용
            Get-Process -Name msedge -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Log '엣지 첫 실행 화면 끄기 (데이터 없이 시작, 허용 안 함, 시작 부스트 끔)' 'OK'
        }
        catch { Write-Log "엣지 첫 실행 화면 설정 실패 - $($_.Exception.Message)" 'WARN' }
    }

    # 공식 오프라인 설치 파일 내려받기 (USB 설치 파일이 실패했을 때)
    function Get-FallbackInstaller($P) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) 'PCSetup'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir ([IO.Path]::GetFileName(([Uri]$P.fallbackUrl).AbsolutePath))
        Set-ProgState $P.name 'running' '설치 파일 내려받는 중'
        Write-Log "$($P.name): 오프라인 설치 파일을 내려받습니다. ($($P.fallbackUrl))"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $old = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'   # 진행 표시가 있으면 내려받기가 매우 느려짐
            Invoke-WebRequest -Uri $P.fallbackUrl -OutFile $file -UseBasicParsing -ErrorAction Stop
            $ProgressPreference = $old
            Write-Log "$($P.name): 내려받기 완료 ($([math]::Round((Get-Item -LiteralPath $file).Length / 1MB)) MB)" 'OK'
            return $file
        }
        catch {
            Write-Log "$($P.name): 내려받기 실패 - $($_.Exception.Message)" 'WARN'
            return $null
        }
    }

    function Install-Programs {
        $list = @($Plan.Programs)
        if ($list.Count -eq 0) { Write-Log '선택된 프로그램이 없습니다.'; return }
        if ($Cfg.browser.hideEdgeFirstRun -ne $false) { Disable-EdgeFirstRun }
        $files = Get-AppFiles $AppRoot
        $jobs = @()
        foreach ($p in $list) {
            if ($p.uninstall) { $jobs += New-UninstallJobs $p; continue }
            if (Test-Installed $p) { Write-Log "$($p.name): 이미 설치되어 있어 건너뜀" 'OK'; Set-ProgState $p.name 'skipped' '이미 설치됨'; continue }
            # winget(Windows 기본 설치 도구)이 있으면 공식 설치 파일을 받아 화면 없이 설치 (다른 설치와 동시에 진행)
            # 실패하면 USB 설치 파일(find/path)로 다시 설치
            if ($p.winget) {
                $wg = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($wg) {
                    $wp = [pscustomobject]@{
                        name      = $p.name
                        args      = "install --id $($p.winget) -e --silent --accept-package-agreements --accept-source-agreements"
                        installed = $p.installed
                    }
                    $job = New-InstallJob $wp $wg.Source
                    if ($p.find -or $p.path) { $job.FallbackP = $p }
                    $jobs += $job
                    Write-Log "$($p.name): winget 으로 설치합니다. ($($p.winget))"
                    continue
                }
                if (-not ($p.find -or $p.path)) { Write-Log "$($p.name): winget 이 없어 설치할 수 없습니다." 'ERROR'; Set-ProgState $p.name 'error' 'winget 없음'; continue }
                Write-Log "$($p.name): winget 이 없어 USB 설치 파일로 설치합니다."
            }
            $path = Find-Installer $AppRoot $files $p $Plan.Site.name
            if (-not $path) { Write-Log "$($p.name): 설치파일을 찾지 못했습니다. 화면에서 [설치파일 지정] 으로 선택하세요." 'ERROR'; Set-ProgState $p.name 'error' '설치파일 없음'; continue }
            $jobs += New-InstallJob $p $path
        }
        if ($jobs.Count -eq 0) { return }

        $gap = if ($null -ne $Cfg.install.staggerSeconds) { [int]$Cfg.install.staggerSeconds } else { 30 }
        $parallel = $Cfg.install.parallel -ne $false
        if ($parallel) { Write-Log "프로그램 $($jobs.Count)개를 $gap 초 간격으로 차례로 실행해 동시에 설치합니다." }
        Invoke-InstallJobs $jobs $gap $parallel

        # 다른 설치와 겹쳐서 실패한 것(1618)은 하나씩 다시 설치
        # 자동 설치가 실패한 것도 한 번 더 시도
        # fallbackUrl 이 있으면 (예: 크롬) 공식 오프라인 설치 파일을 내려받아서 다시 설치
        $retry = @($jobs | Where-Object { $_.Code -eq 1618 -or ($_.Failed -and -not $_.P.uninstall) })
        if ($retry.Count -gt 0 -and -not $Sync.Cancel) {
            Write-Log "겹치거나 실패한 프로그램을 하나씩 다시 설치합니다: $(($retry | ForEach-Object { $_.P.name }) -join ', ')"
            $again = @()
            foreach ($r in $retry) {
                $path = $r.Path
                $rp = $r.P
                if ($r.FallbackP) {
                    # winget 이 실패하면 USB 설치 파일로
                    $usb = Find-Installer $AppRoot $files $r.FallbackP $Plan.Site.name
                    if ($usb) { $rp = $r.FallbackP; $path = $usb; Write-Log "$($rp.name): winget 설치가 안 되어 USB 설치 파일로 설치합니다." }
                }
                elseif ($r.P.fallbackUrl -and $r.Code -ne 1618 -and -not (Test-Installed $r.P)) {
                    $dl = Get-FallbackInstaller $r.P
                    if ($dl) { $path = $dl }
                }
                $j = New-InstallJob $rp $path
                $j.Retried = $true
                $again += $j
            }
            Invoke-InstallJobs $again 0 $false
        }
    }

    # --- 3. 폰트 --------------------------------------------------------------
    function Install-Fonts {
        $f = $Cfg.fonts
        $folder = Resolve-AppDir $AppRoot $f.folder $f.search
        if (-not $folder) { $folder = Resolve-AppDir $AppRoot $null '*스마트체*' }
        if (-not $folder) { $folder = Resolve-AppDir $AppRoot $null '*font*' }
        if (-not $folder) { throw "폰트 폴더를 찾지 못했습니다: $($f.folder)" }
        Write-Log "폰트 폴더: $folder"

        $fonts = @(Get-ChildItem -LiteralPath $folder -Recurse -File | Where-Object { $_.Extension -in '.ttf', '.otf', '.ttc' })
        if ($fonts.Count -eq 0) { throw "폰트 파일(.ttf)이 없습니다: $folder" }
        Write-Log "폰트 파일 $($fonts.Count)개: $(($fonts | ForEach-Object { $_.Name }) -join ', ')"

        Add-Type -AssemblyName System.Drawing
        if (-not ('PCSetup.FontApi' -as [type])) {
            Add-Type -Namespace PCSetup -Name FontApi -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, int msg, System.IntPtr wParam, System.IntPtr lParam, int flags, int timeout, out System.IntPtr result);
'@
        }

        $fontsDir = Join-Path $env:windir 'Fonts'
        $regPath  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

        # 레지스트리에 이 파일이 폰트로 등록되어 있는지 (전체 사용자 또는 현재 사용자)
        $isRegistered = {
            param($fileName)
            foreach ($rp in @($regPath, 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts')) {
                $props = (Get-ItemProperty -LiteralPath $rp -ErrorAction SilentlyContinue).PSObject.Properties
                foreach ($pr in $props) { if ("$($pr.Value)" -and ([IO.Path]::GetFileName("$($pr.Value)") -ieq $fileName)) { return $true } }
            }
            return $false
        }

        $shellFonts = (New-Object -ComObject Shell.Application).Namespace(0x14)   # 0x14 = Windows 글꼴 폴더
        $ok = 0
        foreach ($font in $fonts) {
            try {
                $dest = Join-Path $fontsDir $font.Name
                if ((Test-Path -LiteralPath $dest) -and (& $isRegistered $font.Name)) {
                    Write-Log "폰트: $($font.Name) 이미 설치됨" 'OK'
                    $ok++
                    continue
                }

                # 1) 사람이 글꼴 폴더에 복사/붙여넣기 하는 것과 같은 방법 (설치 + 등록까지 Windows 가 처리)
                $shellFonts.CopyHere($font.FullName, 0x14)   # 0x14 = 진행창 없음 + 모두 예
                for ($w = 0; $w -lt 30; $w++) {
                    if ((Test-Path -LiteralPath $dest) -and (& $isRegistered $font.Name)) { break }
                    Start-Sleep -Milliseconds 500
                }

                # 2) 그래도 등록이 안 됐으면 직접 복사 + 등록
                if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $font.FullName -Destination $dest -Force -ErrorAction Stop }
                if (-not (& $isRegistered $font.Name)) {
                    $family = $font.BaseName
                    try {
                        $pfc = New-Object System.Drawing.Text.PrivateFontCollection
                        $pfc.AddFontFile($dest)
                        if ($pfc.Families.Count -gt 0) { $family = $pfc.Families[0].Name }
                        $pfc.Dispose()
                    }
                    catch { }   # 이름을 못 읽어도 파일 이름으로 등록
                    $type = if ($font.Extension -eq '.otf') { 'OpenType' } else { 'TrueType' }
                    $regName = "$family ($type)"
                    if ((Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains $regName) {
                        $regName = "$($font.BaseName) ($type)"
                    }
                    New-ItemProperty -LiteralPath $regPath -Name $regName -Value $font.Name -PropertyType String -Force -ErrorAction Stop | Out-Null
                    Write-Log "폰트: $($font.Name) 직접 등록 ($regName)"
                }
                [void][PCSetup.FontApi]::AddFontResource($dest)

                if ((Test-Path -LiteralPath $dest) -and (& $isRegistered $font.Name)) { Write-Log "폰트 설치: $($font.Name)" 'OK'; $ok++ }
                else { Write-Log "폰트 설치 확인 실패: $($font.Name)" 'ERROR' }
            }
            catch { Write-Log "폰트 설치 실패: $($font.Name) - $($_.Exception.Message)" 'ERROR' }
        }

        # 열려 있는 프로그램들에 글꼴이 바뀌었다고 알림 (WM_FONTCHANGE)
        $r = [IntPtr]::Zero
        [void][PCSetup.FontApi]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 3000, [ref]$r)
        Write-Log "폰트 $ok / $($fonts.Count) 개 설치됨 (이미 열려 있던 프로그램은 다시 열어야 목록에 보입니다)" $(if ($ok -eq $fonts.Count) { 'OK' } else { 'WARN' })
    }

    # --- 4. 작업표시줄 ---------------------------------------------------------
    function Set-Taskbar {
        $t = $Cfg.taskbar
        $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

        $items = @(
            @{ Desc = '뉴스 및 관심사 / 위젯 끄기'; Run = {
                if (-not $t.hideWidgets) { return $false }
                if ($IsWin11) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 }
                else {
                    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
                    try { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2 } catch { }
                }
                $true } },
            @{ Desc = '검색 표시 방식'; Run = {
                $map = @{ hide = 0; icon = 1; box = 2 }
                if (-not $t.search -or -not $map.ContainsKey($t.search)) { return $false }
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' $map[$t.search]; $true } },
            @{ Desc = '작업표시줄 왼쪽 정렬'; Run = {
                if (-not $IsWin11 -or $null -eq $t.alignLeft) { return $false }
                Set-Reg $adv 'TaskbarAl' $(if ($t.alignLeft) { 0 } else { 1 }); $true } },
            @{ Desc = '작업 보기 버튼'; Run = {
                if ($null -eq $t.hideTaskView) { return $false }
                Set-Reg $adv 'ShowTaskViewButton' $(if ($t.hideTaskView) { 0 } else { 1 }); $true } }
        )

        foreach ($item in $items) {
            try { if (& $item.Run) { Write-Log "작업표시줄: $($item.Desc) 적용" 'OK' } }
            catch { Write-Log "작업표시줄: $($item.Desc) 실패 - $($_.Exception.Message)" 'ERROR' }
        }
        if (@($t.unpin).Count -gt 0) {
            try { Remove-TaskbarPins @($t.unpin) } catch { Write-Log "작업표시줄 아이콘 제거 실패 - $($_.Exception.Message)" 'ERROR' }
        }
        $State.RestartExplorer = $true
    }

    # 작업표시줄에 고정된 아이콘 제거 (메일, Microsoft Store, 반디집 등)
    function Remove-TaskbarPins([string[]]$Patterns) {
        $removed = @()
        $shell = New-Object -ComObject Shell.Application
        foreach ($item in $shell.NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}').Items()) {
            $name = $item.Name
            if (-not (Test-LikeAny $name ($Patterns -join '|'))) { continue }
            foreach ($v in $item.Verbs()) {
                if ($v.Name.Replace('&', '') -match '작업 표시줄에서 제거|작업 표시줄에서 고정 해제|Unpin from taskbar') {
                    $v.DoIt()
                    $removed += $name
                }
            }
        }
        # 바로가기로 고정된 아이콘 (반디집 등)
        $pinDir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
        foreach ($lnk in @(Get-ChildItem -LiteralPath $pinDir -Filter *.lnk -ErrorAction SilentlyContinue)) {
            if (Test-LikeAny $lnk.BaseName ($Patterns -join '|')) {
                Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction SilentlyContinue
                if ($removed -notcontains $lnk.BaseName) { $removed += $lnk.BaseName }
            }
        }
        # Microsoft Store 는 다시 고정되지 않도록 정책도 설정
        if (Test-LikeAny 'Microsoft Store' ($Patterns -join '|')) {
            try { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'NoPinningStoreToTaskbar' 1 } catch { }
        }
        if ($removed.Count -gt 0) { Write-Log "작업표시줄 아이콘 제거: $(($removed | Select-Object -Unique) -join ', ')" 'OK' }
        else { Write-Log '작업표시줄에서 제거할 아이콘이 없습니다. (이미 없거나 고정되어 있지 않음)' }
    }

    # --- 5. 바탕화면 아이콘 ----------------------------------------------------
    function Set-DesktopIcons {
        $ids = [ordered]@{
            computer     = @('{20D04FE0-3AEA-1069-A2D8-08002B30309D}', '컴퓨터')
            userFiles    = @('{59031a47-3f72-44a7-89c5-5595fe6b30ee}', '사용자 파일(문서)')
            network      = @('{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}', '네트워크')
            recycleBin   = @('{645FF040-5081-101B-9F08-00AA002F954E}', '휴지통')
            controlPanel = @('{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}', '제어판')
        }
        $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons'
        foreach ($key in @($Cfg.desktopIcons)) {
            if (-not $ids.Contains($key)) { Write-Log "알 수 없는 바탕화면 아이콘: $key" 'WARN'; continue }
            try {
                Set-Reg "$base\NewStartPanel" $ids[$key][0] 0
                Set-Reg "$base\ClassicStartMenu" $ids[$key][0] 0
                Write-Log "바탕화면 아이콘 표시: $($ids[$key][1])" 'OK'
            }
            catch { Write-Log "바탕화면 아이콘 실패: $($ids[$key][1]) - $($_.Exception.Message)" 'ERROR' }
        }
        $State.RestartExplorer = $true
    }

    # --- 6. 오피스 바로가기 ----------------------------------------------------
    function New-OfficeShortcuts {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        $links = @(Get-ChildItem -LiteralPath $startMenu -Recurse -Filter *.lnk -ErrorAction SilentlyContinue)
        $officeDirs = @("$env:ProgramFiles\Microsoft Office", "${env:ProgramFiles(x86)}\Microsoft Office") | Where-Object { Test-Path -LiteralPath $_ }
        $shell = New-Object -ComObject WScript.Shell

        $apps = @(
            @{ Name = 'Excel';      Pattern = '^(Microsoft )?Excel( \d{4})?$';      Exe = 'EXCEL.EXE' },
            @{ Name = 'PowerPoint'; Pattern = '^(Microsoft )?PowerPoint( \d{4})?$'; Exe = 'POWERPNT.EXE' },
            @{ Name = 'Word';       Pattern = '^(Microsoft )?Word( \d{4})?$';       Exe = 'WINWORD.EXE' }
        )
        foreach ($a in $apps) {
            try {
                $lnk = $links | Where-Object { $_.BaseName -match $a.Pattern } | Select-Object -First 1
                if ($lnk) {
                    Copy-Item -LiteralPath $lnk.FullName -Destination (Join-Path $desktop $lnk.Name) -Force -ErrorAction Stop
                    Write-Log "바탕화면 바로가기: $($lnk.BaseName)" 'OK'
                    continue
                }
                $exe = $officeDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -Filter $a.Exe -ErrorAction SilentlyContinue } | Select-Object -First 1
                if (-not $exe) { Write-Log "$($a.Name): 설치되어 있지 않아 바로가기를 만들지 못했습니다." 'WARN'; continue }
                $sc = $shell.CreateShortcut((Join-Path $desktop "$($a.Name).lnk"))
                $sc.TargetPath = $exe.FullName
                $sc.Save()
                Write-Log "바탕화면 바로가기: $($a.Name)" 'OK'
            }
            catch { Write-Log "$($a.Name) 바로가기 실패 - $($_.Exception.Message)" 'ERROR' }
        }
    }

    # --- 7. 파일 확장명 / PC 이름 ----------------------------------------------
    function Set-Misc {
        $m = $Cfg.misc
        if ($null -ne $m.showFileExtensions) {
            try {
                Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' $(if ($m.showFileExtensions) { 0 } else { 1 })
                Write-Log "파일 확장명 표시: $($m.showFileExtensions)" 'OK'
                $State.RestartExplorer = $true
            }
            catch { Write-Log "파일 확장명 설정 실패 - $($_.Exception.Message)" 'ERROR' }
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

    # --- 사용자 계정 컨트롤 --------------------------------------------------------
    # 슬라이더 가장 아래 = '다음의 경우 항상 알리지 않음 (사용자 계정 컨트롤 끄기)'
    # (EnableLUA 는 켜둠 - 완전히 끄면 스토어 앱/엣지 일부 기능이 동작하지 않음)
    function Set-Uac {
        $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        Set-Reg $sys 'ConsentPromptBehaviorAdmin' 0
        Set-Reg $sys 'PromptOnSecureDesktop' 0
        Write-Log '사용자 계정 컨트롤: 가장 아래 (항상 알리지 않음)' 'OK'
    }

    # --- 8. 전원 --------------------------------------------------------------
    function Set-Power {
        $p = $Cfg.power
        $plans = @{ high = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; balanced = '381b4222-f694-41f0-9685-ff5bb260df2e' }
        if ($p.plan -and $plans.ContainsKey($p.plan)) {
            & powercfg.exe /setactive $plans[$p.plan] *> $null
            if ($LASTEXITCODE -eq 0) { Write-Log "전원 관리 옵션: $($p.plan) 적용" 'OK' }
            else { Write-Log "전원 관리 옵션 '$($p.plan)' 이 이 PC에 없습니다." 'WARN' }
        }

        $timeouts = [ordered]@{
            monitorTimeoutAC = @('monitor-timeout-ac', '화면 끄기(전원 사용)')
            monitorTimeoutDC = @('monitor-timeout-dc', '화면 끄기(배터리 사용)')
            sleepTimeoutAC   = @('standby-timeout-ac', '절전 모드(전원 사용)')
            sleepTimeoutDC   = @('standby-timeout-dc', '절전 모드(배터리 사용)')
        }
        foreach ($key in $timeouts.Keys) {
            $value = $p.$key
            if ($null -eq $value) { continue }
            $label = if ($value -eq 0) { '안 함' } else { "$value 분" }
            [void](Invoke-Cmd "$($timeouts[$key][1]): $label" 'powercfg.exe' @('/change', $timeouts[$key][0], "$value"))
        }

        $isLaptop = $null -ne (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($p.lidOnlyLaptop -and -not $isLaptop) {
            Write-Log '데스크톱 PC라서 덮개 설정은 건너뜁니다.'
        }
        else {
            $lid = @{ nothing = 0; sleep = 1; hibernate = 2; shutdown = 3 }
            $names = @{ nothing = '아무것도 안 함'; sleep = '절전'; hibernate = '최대 절전'; shutdown = '시스템 종료' }
            $changed = $false
            if ($p.lidCloseAC -and $lid.ContainsKey($p.lidCloseAC)) {
                $changed = Invoke-Cmd "덮개를 닫을 때(전원 사용): $($names[$p.lidCloseAC])" 'powercfg.exe' @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', "$($lid[$p.lidCloseAC])")
            }
            if ($p.lidCloseDC -and $lid.ContainsKey($p.lidCloseDC)) {
                $changed = (Invoke-Cmd "덮개를 닫을 때(배터리 사용): $($names[$p.lidCloseDC])" 'powercfg.exe' @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', "$($lid[$p.lidCloseDC])")) -or $changed
            }
            if ($changed) { & powercfg.exe /setactive SCHEME_CURRENT *> $null }
        }

        if ($p.disableHibernate) { [void](Invoke-Cmd '최대 절전 모드 끄기' 'powercfg.exe' @('/hibernate', 'off')) }
    }

    # --- 9. 시작화면 정리 (엣지만) ---------------------------------------------
    function Set-StartMenu {
        if ($IsWin11) {
            $template = Join-Path $Plan.Root 'startmenu\start2.bin'
            $dest = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState'
            if ((Test-Path -LiteralPath $template) -and (Test-Path -LiteralPath $dest)) {
                Copy-Item -LiteralPath $template -Destination (Join-Path $dest 'start2.bin') -Force -ErrorAction Stop
                Stop-Process -Name StartMenuExperienceHost -Force -ErrorAction SilentlyContinue
                Write-Log '저장된 시작화면 레이아웃 적용 완료' 'OK'
                return
            }

            # 저장된 레이아웃이 없으면 고정 해제 메뉴를 하나씩 실행
            $shell = New-Object -ComObject Shell.Application
            $apps = $shell.NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}').Items()
            $removed = 0
            $edge = $null
            foreach ($item in $apps) {
                if ($item.Name -eq 'Microsoft Edge') { $edge = $item }
                foreach ($v in $item.Verbs()) {
                    if ($v.Name.Replace('&', '') -match '시작 화면에서 제거|시작 화면에서 고정 해제|Unpin from Start') { $v.DoIt(); $removed++ }
                }
            }
            Write-Log "시작화면 고정 해제: $removed 개" 'OK'

            $pinned = $false
            if ($edge) {
                foreach ($v in $edge.Verbs()) {
                    if ($v.Name.Replace('&', '') -match '시작 화면에 고정|Pin to Start') { $v.DoIt(); $pinned = $true }
                }
            }
            if ($pinned) { Write-Log '시작화면에 엣지 고정' 'OK' }
            else { Write-Log '엣지를 시작화면에 자동으로 고정하지 못했습니다.' 'WARN' }

            Add-Notice ('시작화면: 자동으로 지우지 못한 항목(설치 안 된 추천 앱 등)이 남아 있을 수 있습니다. 남은 항목은 직접 정리해 주세요.' +
                        "`n  → 한 PC에서 엣지만 남기고 정리한 뒤 [시작화면 저장] 버튼을 누르면, 다음 PC부터는 그대로 자동 적용됩니다.")
            if (-not $pinned) { Add-Notice '시작화면: 엣지를 자동으로 고정하지 못했습니다. 시작 > 모든 앱 > Microsoft Edge 우클릭 > 시작 화면에 고정' }
            return
        }

        # Windows 10: 엣지만 있는 레이아웃을 잠깐 강제로 적용한 뒤 잠금 해제
        $xml = @'
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
  <LayoutOptions StartTileGroupCellWidth="6" />
  <DefaultLayoutOverride>
    <StartLayoutCollection>
      <defaultlayout:StartLayout GroupCellWidth="6">
        <start:Group Name="">
          <start:DesktopApplicationTile Size="2x2" Column="0" Row="0" DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" />
        </start:Group>
      </defaultlayout:StartLayout>
    </StartLayoutCollection>
  </DefaultLayoutOverride>
</LayoutModificationTemplate>
'@
        $dir = Join-Path $env:ProgramData 'PCSetup'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $xmlPath = Join-Path $dir 'StartLayout.xml'
        Set-Content -LiteralPath $xmlPath -Value $xml -Encoding UTF8

        $key = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
        $wsh = New-Object -ComObject WScript.Shell
        Set-Reg $key 'LockedStartLayout' 1
        Set-Reg $key 'StartLayoutFile' $xmlPath 'ExpandString'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 8
        $wsh.SendKeys('^{ESCAPE}')
        Start-Sleep -Seconds 3
        $wsh.SendKeys('^{ESCAPE}')

        Set-Reg $key 'LockedStartLayout' 0
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        Remove-ItemProperty -Path $key -Name 'LockedStartLayout', 'StartLayoutFile' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
        $State.RestartExplorer = $false
        Write-Log '시작화면 정리 완료 (엣지만 고정)' 'OK'
    }

    # --- 10~12. 브라우저 --------------------------------------------------------
    function Get-PolicyRoot([string]$Browser) {
        $base = if ($Browser -eq 'chrome') { 'HKLM:\SOFTWARE\Policies\Google\Chrome' } else { 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' }
        if ($Cfg.browser.enforceSettings) { return $base }
        return "$base\Recommended"
    }

    # 권장값 모드일 때 고정값(필수 정책)으로 들어가 있던 항목을 지워서 '조직에서 관리합니다' 잠금 해제
    function Clear-LockedPolicies([string]$Browser, [string[]]$Names, [string]$Label) {
        if ($Cfg.browser.enforceSettings) { return }
        $base = if ($Browser -eq 'chrome') { 'HKLM:\SOFTWARE\Policies\Google\Chrome' } else { 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' }
        $props = (Get-ItemProperty -LiteralPath $base -ErrorAction SilentlyContinue).PSObject.Properties.Name
        $removed = @($Names | Where-Object { $props -contains $_ })
        foreach ($n in $removed) { Remove-ItemProperty -LiteralPath $base -Name $n -ErrorAction SilentlyContinue }
        if ($removed.Count -gt 0) { Write-Log "${Label}: 잠겨 있던 설정 $($removed.Count)개를 직원이 바꿀 수 있게 풀었습니다." 'OK' }
    }

    # 즐겨찾기 모음에 링크 추가 (직원이 지우거나 옮길 수 있는 일반 즐겨찾기)
    # 브라우저의 즐겨찾기 파일(User Data\Default\Bookmarks)에 직접 추가 → 브라우저가 꺼져 있어야 함
    function Add-BrowserBookmarks([string]$Browser, [string]$Label) {
        $list = @($Cfg.browser.bookmarks | Where-Object { $_.url })
        if ($list.Count -eq 0) { return }
        if ($Browser -eq 'chrome') { $proc = 'chrome'; $dir = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default' }
        else { $proc = 'msedge'; $dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default' }
        Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $file = Join-Path $dir 'Bookmarks'
        $now = [string][long](([DateTime]::UtcNow - [DateTime]'1601-01-01').Ticks / 10)   # 크롬/엣지 시간 형식
        try {
            if (Test-Path -LiteralPath $file) {
                $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            }
            else {
                # 브라우저를 아직 한 번도 열지 않은 새 PC: 기본 즐겨찾기 파일을 만듦
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $root = { param($id, $guid, $name) [pscustomobject][ordered]@{ children = @(); date_added = $now; date_modified = '0'; guid = $guid; id = $id; name = $name; type = 'folder' } }
                $data = [pscustomobject][ordered]@{
                    roots   = [pscustomobject][ordered]@{
                        bookmark_bar = & $root '1' '0bc5d13f-2cba-5d74-951f-3f233fe6c908' '즐겨찾기 모음'
                        other        = & $root '2' '82b081ec-3dd3-529c-8475-ab6c344590dd' '기타 즐겨찾기'
                        synced       = & $root '3' '4cf2e351-0e85-532b-bb37-df045d8f8d0f' '모바일 즐겨찾기'
                    }
                    version = 1
                }
            }

            # 이미 있는 주소 / 가장 큰 id 찾기
            $urls = New-Object System.Collections.Generic.HashSet[string]
            $maxId = 3
            $walk = {
                param($node)
                if ($node.id -match '^\d+$' -and [int]$node.id -gt $script:bmMax) { $script:bmMax = [int]$node.id }
                if ($node.url) { [void]$urls.Add(([string]$node.url).TrimEnd('/').ToLower()) }
                foreach ($c in @($node.children)) { if ($c) { & $walk $c } }
            }
            $script:bmMax = $maxId
            foreach ($r in $data.roots.PSObject.Properties) { if ($r.Value -and $r.Value.PSObject.Properties['children']) { & $walk $r.Value } }

            $bar = $data.roots.bookmark_bar
            $added = @()
            foreach ($b in @($list)) {
                if ($urls.Contains(([string]$b.url).TrimEnd('/').ToLower())) { Write-Log "${Label}: 즐겨찾기 '$($b.name)' 이미 있음" 'OK'; continue }
                $script:bmMax++
                $item = [pscustomobject][ordered]@{
                    date_added = $now; date_last_used = '0'; guid = [guid]::NewGuid().ToString()
                    id = [string]$script:bmMax; name = [string]$b.name; type = 'url'; url = [string]$b.url
                }
                $bar.children = @($item) + @($bar.children | Where-Object { $_ })
                $added += $b.name
            }
            if ($added.Count -gt 0) {
                # 검사값(checksum)은 지우면 브라우저가 다시 계산함
                if ($data.PSObject.Properties['checksum']) { $data.PSObject.Properties.Remove('checksum') }
                $json = $data | ConvertTo-Json -Depth 100
                [IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
                Write-Log "${Label}: 즐겨찾기 모음에 $($added -join ', ') 추가" 'OK'
            }
        }
        catch { Write-Log "${Label}: 즐겨찾기 추가 실패 - $($_.Exception.Message)" 'WARN' }
    }

    function Set-EdgeSettings {
        $key = Get-PolicyRoot 'edge'
        $items = [ordered]@{
            ShowHomeButton             = '홈 단추 표시'
            FavoritesBarEnabled        = '즐겨찾기 모음 항상 표시'
            ShowDownloadsToolbarButton = '다운로드 단추 표시'
            PromptForDownloadLocation  = '다운로드 전에 저장 위치 확인'
        }
        foreach ($name in $items.Keys) {
            try { Set-Reg $key $name 1; Write-Log "엣지: $($items[$name])" 'OK' }
            catch { Write-Log "엣지: $($items[$name]) 실패 - $($_.Exception.Message)" 'ERROR' }
        }
        Add-BrowserBookmarks 'edge' '엣지'
        # 직원이 바꿀 수 있게: 예전에 고정값(조직에서 관리)으로 넣은 것과 셋팅 중에만 필요한 설정은 지움
        $extra = @('StartupBoostEnabled', 'BackgroundModeEnabled', 'ManagedFavorites')
        Clear-LockedPolicies 'edge' (@($items.Keys) + $extra) '엣지'
        Close-Browser 'msedge' '엣지'
    }

    # 설정이 바로 적용되도록 실행 중인 브라우저 닫기 (엣지는 시작 부스트로 뒤에서 실행 중일 수 있음)
    function Close-Browser([string]$Proc, [string]$Label) {
        if ($Cfg.browser.closeAfterSettings -eq $false) { Write-Log "$Label 을 다시 열면 적용됩니다."; return }
        $running = @(Get-Process -Name $Proc -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Log "$Label 설정 적용을 위해 실행 중인 $Label 을 닫았습니다."
        }
        Write-Log "$Label 을 열면 설정이 적용되어 있습니다."
    }

    function Set-ChromeSettings {
        $key = Get-PolicyRoot 'chrome'
        $items = [ordered]@{
            ShowHomeButton     = '홈 버튼 표시'
            BookmarkBarEnabled = '북마크바 항상 표시'
        }
        foreach ($name in $items.Keys) {
            try { Set-Reg $key $name 1; Write-Log "크롬: $($items[$name])" 'OK' }
            catch { Write-Log "크롬: $($items[$name]) 실패 - $($_.Exception.Message)" 'ERROR' }
        }
        Add-BrowserBookmarks 'chrome' '크롬'
        Clear-LockedPolicies 'chrome' (@($items.Keys) + @('ManagedBookmarks')) '크롬'
        Close-Browser 'chrome' '크롬'
    }

    function Wait-Process2($Proc, [int]$Seconds) {
        if (-not $Proc.WaitForExit($Seconds * 1000)) { Write-Log '업데이트가 오래 걸려 기다리지 않고 다음으로 넘어갑니다. (백그라운드에서 계속 진행)' 'WARN' }
    }

    function Update-Browsers {
        Set-Status '엣지 최신 버전으로 업데이트 중...'
        $edgeExe = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        $before = if (Test-Path -LiteralPath $edgeExe) { (Get-Item -LiteralPath $edgeExe).VersionInfo.ProductVersion } else { '없음' }
        $edgeUpd = "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe"
        if (Test-Path -LiteralPath $edgeUpd) {
            # 최신 버전 엣지를 내려받아 설치하도록 직접 요청 (/ua 만으로는 업데이트가 안 되는 경우가 있음)
            $edgeArgs = '/silent /install "appguid={56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}&appname=Microsoft%20Edge&needsadmin=True"'
            Wait-Process2 (Start-Process $edgeUpd -ArgumentList $edgeArgs -PassThru) 900
            Wait-Process2 (Start-Process $edgeUpd -ArgumentList '/ua /installsource scheduler' -PassThru) 300
            $after = if (Test-Path -LiteralPath $edgeExe) { (Get-Item -LiteralPath $edgeExe).VersionInfo.ProductVersion } else { '없음' }
            Write-Log "엣지 업데이트: $before → $after" 'OK'
        }
        else { Write-Log '엣지 업데이트 프로그램을 찾지 못했습니다.' 'WARN' }

        Set-Status '크롬 최신 버전으로 업데이트 중...'
        $updater = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Google\GoogleUpdater\*\updater.exe", "$env:ProgramFiles\Google\GoogleUpdater\*\updater.exe" -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $legacy = "${env:ProgramFiles(x86)}\Google\Update\GoogleUpdate.exe"
        if ($updater) {
            Wait-Process2 (Start-Process $updater.FullName -ArgumentList '--wake --system' -PassThru) 600
            Write-Log '크롬 업데이트 확인 완료' 'OK'
        }
        elseif (Test-Path -LiteralPath $legacy) {
            Wait-Process2 (Start-Process $legacy -ArgumentList '/ua /installsource scheduler' -PassThru) 600
            Write-Log '크롬 업데이트 확인 완료' 'OK'
        }
        else { Write-Log '크롬이 설치되어 있지 않거나 업데이트 프로그램을 찾지 못했습니다.' 'WARN' }
    }

    function Add-ForceInstall([string]$Key, [string]$Id, [string]$UpdateUrl) {
        if (-not (Test-Path -LiteralPath $Key)) { New-Item -Path $Key -Force | Out-Null }
        $props = (Get-ItemProperty -LiteralPath $Key).PSObject.Properties | Where-Object { $_.Name -match '^\d+$' }
        if ($props | Where-Object { "$($_.Value)" -like "$Id*" }) { return $false }
        $next = 1
        while ($props | Where-Object { $_.Name -eq "$next" }) { $next++ }
        Set-Reg $Key "$next" "$Id;$UpdateUrl" 'String'
        return $true
    }

    function Install-BrowserExtensions {
        $b = $Cfg.browser
        if ($b.updateFirst) { Update-Browsers }

        foreach ($id in @($b.chromeExtensions)) {
            if (-not $id) { continue }
            [void](Add-ForceInstall 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist' $id 'https://clients2.google.com/service/update2/crx')
            Write-Log "크롬 확장프로그램 등록: $id" 'OK'
        }
        foreach ($id in @($b.edgeExtensions)) {
            if (-not $id) { continue }
            [void](Add-ForceInstall 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist' $id 'https://edge.microsoft.com/extensionwebstorebase/v1/crx')
            Write-Log "엣지 확장프로그램 등록: $id" 'OK'
        }
        Write-Log '크롬/엣지를 열면 확장프로그램이 자동으로 설치됩니다. (인터넷 연결 필요)'
    }

    # --- 13. 프린터 ------------------------------------------------------------
    function Get-InfModelNames([string]$InfPath) {
        $sections = @{}
        $cur = $null
        foreach ($l in (Get-Content -LiteralPath $InfPath -ErrorAction Stop)) {
            $t = ($l -replace ';.*$', '').Trim()
            if (-not $t) { continue }
            if ($t -match '^\[(.+)\]$') {
                $cur = $matches[1].Trim().ToLower()
                if (-not $sections.ContainsKey($cur)) { $sections[$cur] = New-Object System.Collections.ArrayList }
                continue
            }
            if ($cur) { [void]$sections[$cur].Add($t) }
        }

        # [Strings] 값 (영문 기본값이 우선)
        $strings = @{}
        foreach ($sec in @($sections.Keys | Where-Object { $_ -like 'strings.*' }) + @('strings')) {
            if (-not $sections.ContainsKey($sec)) { continue }
            foreach ($t in $sections[$sec]) {
                if ($t -match '^([^=]+?)\s*=\s*(.*)$') { $strings[$matches[1].Trim().ToLower()] = $matches[2].Trim().Trim('"') }
            }
        }
        $resolve = {
            param($s)
            $s = $s.Trim().Trim('"')
            if ($s -match '^%(.+)%$' -and $strings.ContainsKey($matches[1].ToLower())) { return $strings[$matches[1].ToLower()] }
            return $s
        }

        $models = New-Object System.Collections.ArrayList
        foreach ($t in @($sections['manufacturer'])) {
            if (-not $t -or $t -notmatch '=') { continue }
            $parts = @($t.Split('=', 2)[1].Split(',') | ForEach-Object { $_.Trim() })
            $baseSec = $parts[0]
            $secNames = @($parts | Select-Object -Skip 1 | ForEach-Object { "$baseSec.$_" }) + @($baseSec)
            $secNames = @($secNames | Sort-Object { if ($_ -match 'amd64') { 0 } else { 1 } })
            foreach ($sn in $secNames) {
                $sec = $sections[$sn.ToLower()]
                if (-not $sec) { continue }
                foreach ($m in $sec) {
                    if ($m -match '^(.+?)\s*=') {
                        $name = & $resolve $matches[1]
                        if ($name -and -not $models.Contains($name)) { [void]$models.Add($name) }
                    }
                }
            }
        }
        return @($models)
    }

    function Install-Printers {
        $pc = $Cfg.printer
        $list = @($Plan.Printers)
        if ($list.Count -eq 0) { Write-Log '선택된 프린터가 없습니다. 화면에서 설치할 프린터를 체크하세요.' 'WARN'; return }

        $folder = Resolve-AppDir $AppRoot $pc.driverFolder $pc.search
        if (-not $folder) { throw "프린터 드라이버 폴더를 찾지 못했습니다: $($pc.driverFolder)" }
        $infs = @(Get-ChildItem -LiteralPath $folder -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
        if ($infs.Count -eq 0) { throw "드라이버 폴더에 .inf 파일이 없습니다: $folder" }

        Set-Status '프린터 드라이버 등록 중...'
        & pnputil.exe /add-driver (Join-Path $folder '*.inf') /subdirs /install *> $null
        Write-Log "프린터 드라이버 등록 (pnputil 결과 코드 $LASTEXITCODE)"

        $driverName = $pc.driverName
        if (-not $driverName) {
            $names = @()
            foreach ($inf in ($infs | Sort-Object { if ($_.FullName -match '64') { 0 } else { 1 } })) {
                try { $names += Get-InfModelNames $inf.FullName } catch { }
            }
            $names = @($names | Select-Object -Unique)
            Write-Log "드라이버 모델 목록: $($names -join ' / ')"
            $pick = @($names | Where-Object { $pc.driverHint -and $_ -match [regex]::Escape($pc.driverHint) })
            if ($pick.Count -gt 1) { $pcl = @($pick | Where-Object { $_ -match 'PCL' }); if ($pcl.Count) { $pick = $pcl } }
            if ($pick.Count -eq 0) { $pick = $names }
            $driverName = $pick | Select-Object -First 1
        }
        if (-not $driverName) { throw '드라이버 이름을 알 수 없습니다. config.json 의 printer.driverName 에 직접 입력하세요.' }

        if (-not (Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue)) {
            Add-PrinterDriver -Name $driverName -ErrorAction Stop
        }
        Write-Log "프린터 드라이버: $driverName" 'OK'

        foreach ($p in $list) {
            try {
                $port = "IP_$($p.ip)"
                if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) {
                    Add-PrinterPort -Name $port -PrinterHostAddress $p.ip -ErrorAction Stop
                }
                $printerName = ("$($pc.namePrefix) $($p.name)").Trim()
                if (Get-Printer -Name $printerName -ErrorAction SilentlyContinue) {
                    Write-Log "프린터가 이미 있습니다: $printerName" 'OK'
                    continue
                }
                Add-Printer -Name $printerName -DriverName $driverName -PortName $port -ErrorAction Stop
                Write-Log "프린터 추가: $printerName ($($p.ip))" 'OK'
            }
            catch { Write-Log "프린터 추가 실패: $($p.name) - $($_.Exception.Message)" 'ERROR' }
        }
    }

    # --- 드라이버 / 윈도우 업데이트 ----------------------------------------------
    # 진행 상황 표시판 / 진행 순서 창의 '윈도우 업데이트' 줄에 상세 진행 표시 (백그라운드 업데이트일 때)
    # 남은 시간: 지금까지 끝난 항목의 평균 시간 × 남은 개수
    function Get-Eta([datetime]$Start, [int]$Done, [int]$Total) {
        if ($Done -le 0) { return '남은 시간 계산 중' }
        $sec = ((Get-Date) - $Start).TotalSeconds / $Done * ($Total - $Done)
        if ($sec -lt 60) { return '1분 이내 남음' }
        $m = [math]::Ceiling($sec / 60)
        if ($m -ge 60) { return "약 $([math]::Floor($m / 60))시간 $($m % 60)분 남음" }
        return "약 $($m)분 남음"
    }

    function Set-UpdateProgress([string]$Text) {
        if ($Plan.Background) { Set-TaskState 'update' 'running' $Text }
    }

    function Get-ShortTitle([string]$Title) {
        if ($Title -match '\((KB\d+)\)') { $kb = $matches[1] } else { $kb = '' }
        $t = if ($Title.Length -gt 28) { $Title.Substring(0, 28) + '…' } else { $Title }
        if ($kb -and $t -notmatch $kb) { $t = "$kb $t" }
        return $t
    }

    function Invoke-WindowsUpdate([string]$Criteria, [string]$Label) {
        Set-UpdateProgress "$($State.UpdateRoundNow)회차 · 업데이트 검색 중"
        Set-Status "$Label 검색 중... (몇 분 걸릴 수 있습니다)"
        Write-Log "$Label 검색 시작"
        try {
            $session  = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $result   = $searcher.Search($Criteria)
        }
        catch { Write-Log "${Label} 검색 실패: $($_.Exception.Message)" 'ERROR'; return -1 }

        # 제외: 윈도우 버전 업그레이드, 소프트웨어 '미리 보기' 같은 선택 항목 (선택적 업데이트의 드라이버는 포함)
        $updates = @()
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)
            $isUpgrade = $false
            foreach ($c in $u.Categories) { if ($c.Name -eq 'Upgrades') { $isUpgrade = $true } }
            if ($isUpgrade) { Write-Log "버전 업그레이드는 건너뜀: $($u.Title)" 'WARN' }
            elseif ($u.BrowseOnly -and $u.Type -ne 2) { Write-Log "선택 항목은 건너뜀: $($u.Title)" }
            else { $updates += $u }
        }
        if ($updates.Count -eq 0) { Write-Log "${Label}: 설치할 항목이 없습니다." 'OK'; return 0 }
        Write-Log "${Label}: $($updates.Count)개 발견"
        $okCount = 0
        $updStart = Get-Date
        $failCount = 0

        for ($i = 0; $i -lt $updates.Count; $i++) {
            if ($Sync.Cancel) { Write-Log '중지 요청으로 업데이트 설치를 멈춥니다.' 'WARN'; break }
            $u = $updates[$i]
            Set-StepProgress $i $updates.Count
            Set-Status "$Label 설치 중 ($($i + 1)/$($updates.Count), $(Get-Eta $updStart $i $updates.Count)): $($u.Title)"
            $head = "$($State.UpdateRoundNow)회차 · $($i + 1)/$($updates.Count)"
            $eta = Get-Eta $updStart $i $updates.Count
            $tail = "(완료 $okCount, 실패 $failCount, $eta) $(Get-ShortTitle $u.Title)"
            try {
                if (-not $u.EulaAccepted) { $u.AcceptEula() }
                $coll = New-Object -ComObject Microsoft.Update.UpdateColl
                [void]$coll.Add($u)
                if (-not $u.IsDownloaded) {
                    Set-UpdateProgress "$head 내려받는 중 $tail"
                    $downloader = $session.CreateUpdateDownloader()
                    $downloader.Updates = $coll
                    [void]$downloader.Download()
                }
                Set-UpdateProgress "$head 설치 중 $tail"
                $installer = $session.CreateUpdateInstaller()
                $installer.Updates = $coll
                $r = $installer.Install()
                if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) { Write-Log "설치 완료: $($u.Title)" 'OK'; $okCount++ }
                else { Write-Log "설치 실패 (결과 코드 $($r.ResultCode)): $($u.Title)" 'ERROR'; $failCount++ }
                if ($r.RebootRequired) { $Sync.RebootRequired = $true; $State.UpdateReboot = $true }
            }
            catch { Write-Log "설치 오류: $($u.Title) - $($_.Exception.Message)" 'ERROR'; $failCount++ }
        }
        Set-UpdateProgress "$($State.UpdateRoundNow)회차 끝 (완료 $okCount, 실패 $failCount) · 다시 확인 중"
        return $updates.Count
    }

    function Test-PendingReboot {
        return ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'))
    }

    # 재부팅 전에 설치 중인 프로그램이 없는지 확인 (최대 10분 대기)
    function Wait-InstallIdle {
        for ($i = 0; $i -lt 120; $i++) {
            $busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.SessionId -ne 0 -and ($_.ProcessName -eq 'msiexec' -or $_.ProcessName -match 'setup|install')
            })
            if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress')) { $busy += 'msi' }
            if ($busy.Count -eq 0) { return }
            if ($i -eq 0) { Write-Log "설치 중인 프로그램이 끝나기를 기다립니다: $(($busy | ForEach-Object { if ($_.ProcessName) { $_.ProcessName } else { $_ } }) -join ', ')" 'WARN' }
            Set-Status '재부팅 전에 설치 중인 프로그램이 끝나기를 기다리는 중...'
            Start-Sleep -Seconds 5
        }
        Write-Log '10분을 기다려도 설치 중인 프로그램이 남아 있습니다.' 'WARN'
    }

    # 재부팅 후 로그인하면 남은 작업을 이어서 하도록 예약
    function Register-Resume([string[]]$RemainingIds, [int]$Round) {
        $base = Split-Path $ResumePath
        $app  = Join-Path $base 'app'
        if (-not (Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
        # USB 드라이브 문자가 바뀌어도 실행되도록 도구를 C: 에 복사 (실행마다 한 번만)
        if ($Plan.Root.TrimEnd('\') -ne $app -and -not $State.AppCopied) {
            $State.AppCopied = $true
            if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $app -Force | Out-Null
            # 도구에 필요한 파일만 복사 (exe 를 USB 루트에 둔 경우 USB 전체가 복사되지 않도록)
            $items = @('PCSetup.ps1', 'Setup.bat', 'config.json', 'startmenu')
            if ($Plan.LauncherExe) { $items += [IO.Path]::GetFileName($Plan.LauncherExe) }
            foreach ($it in $items) {
                $src = Join-Path $Plan.Root $it
                if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $app -Recurse -Force }
            }
        }
        $state = [ordered]@{
            Steps       = @($RemainingIds)
            UpdateRound = $Round
            Site        = $Plan.Site
            Printers    = @($Plan.Printers)
            Notices     = @($Sync.Notices)
            LogFile     = $Plan.LogFile
            SavedAt     = (Get-Date).ToString('s')
        }
        $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResumePath -Encoding UTF8

        # 계정 이름 대신 SID 로 예약 (PC 이름을 바꿔도 동작하도록)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($Plan.LauncherExe) {
            $action = New-ScheduledTaskAction -Execute (Join-Path $app ([IO.Path]::GetFileName($Plan.LauncherExe))) -Argument '-Resume'
        }
        else {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$app\PCSetup.ps1`" -Resume"
        }
        $trigger   = New-ScheduledTaskTrigger -AtLogOn
        $trigger.Delay = 'PT20S'
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        $taskOk = $true
        try { Register-ScheduledTask -TaskName 'PCSetupResume' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null }
        catch { $taskOk = $false; Write-Log "이어하기 예약 작업 등록 실패 (시작 항목으로 대신 실행): $($_.Exception.Message)" 'WARN' }

        # 예비: 로그인할 때 한 번 실행되는 시작 항목 (관리자 권한으로 다시 실행)
        $ps1 = Join-Path $app 'PCSetup.ps1'
        $cmd = "powershell.exe -NoProfile -WindowStyle Hidden -Command `"Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \`"$ps1\`" -Resume'`""
        try { Set-Reg $RunOnceKey $RunOnceName $cmd 'String' } catch { Write-Log "시작 항목 등록 실패: $($_.Exception.Message)" 'WARN' }
        if ($State.LastResume -ne ($RemainingIds -join ',')) {
            $State.LastResume = ($RemainingIds -join ',')
            Write-Log "재부팅되면 로그인 후 자동으로 이어서 진행합니다. (남은 작업: $($RemainingIds -join ', '))"
        }
    }

    function Clear-Resume {
        Unregister-ScheduledTask -TaskName 'PCSetupResume' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ResumePath -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
    }

    # 단계마다 '남은 작업' 저장 → 어떤 이유로 재부팅되든 로그인 후 이어서 진행
    # (IP 설정은 다시 하지 않음, 업데이트가 아직 진행 중이면 업데이트도 포함)
    function Save-Checkpoint([int]$FromStep) {
        if ($Plan.Background) { return }
        $ids = @()
        if ($State.UpdatePending) { $ids += 'update' }
        $ids += @($Plan.Steps | Select-Object -Skip $FromStep | ForEach-Object { $_.Id } | Where-Object { $_ -notin 'network', 'update' })
        if ($ids.Count -eq 0) { return }
        try { Register-Resume $ids ([int]$Plan.UpdateRound) } catch { Write-Log "이어하기 저장 실패: $($_.Exception.Message)" 'WARN' }
    }

    # 윈도우 업데이트(선택적 업데이트의 드라이버 포함)를 '최신 버전' 이 될 때까지 반복
    function Invoke-UpdateCycle {
        $max = if ($Cfg.windowsUpdate.maxRounds) { [int]$Cfg.windowsUpdate.maxRounds } else { 6 }
        $round = [int]$Plan.UpdateRound
        while ($true) {
            $round++
            if ($round -gt $max) {
                Write-Log "업데이트를 $max 회 반복했지만 남은 항목이 있습니다." 'WARN'
                Add-Notice '윈도우 업데이트: 남은 항목이 있습니다. 설정 > Windows 업데이트 에서 확인하세요.'
                return
            }
            if ($Sync.Cancel) { return }
            Write-Log "윈도우 업데이트 $round 회차 (드라이버 포함)"
            $State.UpdateRoundNow = $round
            $State.UpdateReboot = $false
            $n = Invoke-WindowsUpdate 'IsInstalled=0 and IsHidden=0' '윈도우 업데이트'
            if ($n -lt 0) { Add-Notice '윈도우 업데이트 검색에 실패했습니다. 인터넷 연결을 확인하고 설정 > Windows 업데이트 에서 진행하세요.'; return }
            if ($State.UpdateReboot -or (Test-PendingReboot)) {
                Write-Log '업데이트 적용을 위해 재부팅이 필요합니다.' 'WARN'
                $State.ResumeRound = $round
                $State.ResumeHere = $true
                return
            }
            if ($n -eq 0) { Write-Log '윈도우 업데이트: 최신 버전입니다.' 'OK'; return }
        }
    }

    # 프로그램 설치와 동시에 진행하도록 윈도우 업데이트를 별도 런스페이스에서 실행
    function Start-BackgroundUpdate {
        $bg = [hashtable]::Synchronized(@{
            Queue = $Sync.Queue; Notices = $Sync.Notices; LogLock = $Sync.LogLock; TaskStates = $Sync.TaskStates
            Status = '윈도우 업데이트 준비 중'; Percent = 0; StepCount = 1; Done = $false; Cancel = $false
            RebootRequired = $false; NeedReboot = $false; ResumeRound = 0
            Guide = ''; GuideWait = ''; GuideAck = ''
        })
        $bgPlan = $Plan.Clone()
        $bgPlan.Steps = @(@{ Id = 'update'; Title = '윈도우 업데이트' })
        $bgPlan.Background = $true
        $bgPlan.LogPrefix = '[업데이트]'
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($Plan.WorkerCode).AddArgument($bg).AddArgument($bgPlan)
        $State.Bg = @{ Sync = $bg; PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $Sync.Bg = $bg
        $Sync.BgPS = $ps
        $State.UpdatePending = $true
        Write-Log '윈도우 업데이트를 백그라운드에서 시작했습니다. (프로그램 설치와 동시에 진행)'
    }

    # 윈도우 업데이트가 끝나기를 기다리고, 재부팅이 필요한지 확인
    function Wait-BackgroundUpdate {
        if (-not $State.Bg) { return }
        $bg = $State.Bg.Sync
        Write-Log '윈도우 업데이트가 끝나기를 기다립니다...'
        while (-not $bg.Done) {
            if ($Sync.Cancel) { $bg.Cancel = $true; return }
            Set-Status '윈도우 업데이트가 끝나기를 기다리는 중 (아래 줄에 진행 상황)'
            Start-Sleep -Seconds 2
        }
        try { [void]$State.Bg.PS.EndInvoke($State.Bg.Handle) } catch { }
        $State.Bg.PS.Dispose()
        $State.Bg.RS.Dispose()
        $State.Bg = $null
        $Sync.Bg = $null
        $Sync.BgPS = $null
        if ($bg.NeedReboot) {
            $State.ResumeHere = $true
            $State.ResumeRound = $bg.ResumeRound
            Set-TaskState 'update' 'reboot' '재부팅 후 이어서 업데이트'
        }
        else {
            if ($bg.RebootRequired) { $Sync.RebootRequired = $true }
            if ([int]$bg.ErrorCount -gt 0) { Set-TaskState 'update' 'warn' '확인 필요 (로그 참고)' }
            else { Set-TaskState 'update' 'done' '최신 버전' }
            $State.UpdatePending = $false
        }
    }

    # 업데이트 재부팅이 필요하면: 설치 중인 프로그램이 없는지 확인 → 이어하기 예약 (업데이트부터 다시)
    function Request-UpdateReboot([string[]]$RemainingIds) {
        Restart-Explorer
        Wait-InstallIdle
        $ids = @('update') + @($RemainingIds | Where-Object { $_ -and $_ -ne 'update' })
        try {
            Register-Resume $ids $State.ResumeRound
            $Sync.ResumeRequested = $true
        }
        catch {
            Write-Log "이어하기 예약 실패: $($_.Exception.Message)" 'ERROR'
            Add-Notice '재부팅 후 Setup.bat 을 다시 실행해서 윈도우 업데이트부터 이어서 진행하세요.'
            $Sync.RebootRequired = $true
        }
    }

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

        if ($d.localFolder) {
            $folder = $d.localFolder
            if (-not [IO.Path]::IsPathRooted($folder)) { $folder = Join-Path $Plan.Root $folder }
            if ((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count -gt 0) {
                Set-Status '드라이버 폴더에서 설치 중...'
                & pnputil.exe /add-driver (Join-Path $folder '*.inf') /subdirs /install *> $null
                Write-Log "드라이버 폴더 설치 (결과 코드 $LASTEXITCODE)"
                if ($LASTEXITCODE -eq 3010) { $Sync.RebootRequired = $true }
            }
        }

        if ($d.useVendorTool) {
            $maker = (Get-CimInstance Win32_ComputerSystem).Manufacturer
            Write-Log "제조사: $maker"
            if ($maker -match 'Dell') {
                $dcu = @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe", "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe") |
                       Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($dcu) {
                    Set-Status 'Dell Command Update 로 드라이버 업데이트 중...'
                    & $dcu /applyUpdates -silent -reboot=disable *> $null
                    switch ($LASTEXITCODE) {
                        0       { Write-Log 'Dell 드라이버 업데이트 완료' 'OK' }
                        { $_ -in 1, 5 } { Write-Log 'Dell 드라이버 업데이트 완료 (재부팅 필요)' 'OK'; $Sync.RebootRequired = $true }
                        500     { Write-Log 'Dell: 설치할 업데이트가 없습니다.' 'OK' }
                        default { Write-Log "Dell Command Update 결과 코드 $LASTEXITCODE" 'WARN' }
                    }
                }
                else { Write-Log 'Dell Command Update 가 설치되어 있지 않습니다.' 'WARN' }
            }
        }

        if ($d.windowsUpdate) { [void](Invoke-WindowsUpdate "IsInstalled=0 and IsHidden=0 and Type='Driver'" '드라이버 업데이트') }
        Write-Log '설치 후 장치 상태 재확인:'
        Write-ProblemDevices
    }

    # --- 14. 정품 인증 확인 -----------------------------------------------------
    function Test-Activation {
        $a = Get-ActivationInfo
        Write-Log "Windows: $($a.Caption) (에디션 $($a.Edition))"
        if ($a.Activated) { Write-Log '정품 인증: 완료' 'OK' }
        else {
            Write-Log '정품 인증: 안 되어 있음' 'WARN'
            Add-Notice '정품 인증이 안 되어 있습니다. 설정 > 시스템 > 정품 인증 에서 제품 키를 등록하세요.'
        }
        if ($a.IsHome) {
            Write-Log 'Home 버전입니다. Pro 로 업그레이드가 필요합니다.' 'WARN'
            Add-Notice 'Windows Home 버전입니다. Pro 로 업그레이드하세요. (설정 > 시스템 > 정품 인증 > 제품 키 변경 에서 Pro 키 입력)'
        }
    }

    # --- 15. 문서중앙화 --------------------------------------------------------
    function Install-DocCentral {
        $dc = $Cfg.docCentral
        $path = Find-Installer $AppRoot (Get-AppFiles $AppRoot) $dc $null
        $folder = $null
        if (-not $path -and ($dc.folder -or $dc.search)) { $folder = Resolve-AppDir $AppRoot $dc.folder $dc.search }
        if (-not $path -and -not $folder) { throw '문서중앙화 설치파일을 찾지 못했습니다.' }

        if (-not $path) {
            $files = @(Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.Extension -in '.exe', '.msi' -and $_.Name -notmatch '^unins' })
            $preferred = @($files | Where-Object { $_.Name -match 'setup|install|설치' })
            if ($preferred.Count) { $files = $preferred }
            $path = ($files | Sort-Object { $_.FullName.Length } | Select-Object -First 1).FullName
        }
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw '문서중앙화 설치파일을 찾지 못했습니다.' }

        $p = [pscustomobject]@{
            name = '문서중앙화'; args = $dc.args; guide = $dc.guide; auto = $dc.auto; dismiss = $dc.dismiss; dismissWhen = $dc.dismissWhen
        }
        Write-Log "문서중앙화 설치 시작: $path (재부팅이 여러 번 될 수 있습니다)"
        Invoke-InstallJobs @(New-InstallJob $p $path) 0 $false
    }

    # --- 실행 ----------------------------------------------------------------
    try {
        if (-not $Plan.Background) {
            $os = Get-CimInstance Win32_OperatingSystem
            Write-Log "셋팅 시작 - PC: $env:COMPUTERNAME / 사용자: $env:USERNAME / $($os.Caption) (빌드 $($os.BuildNumber))"
            Write-Log "USB 폴더: $AppRoot"
        }
        $Sync.StepCount = [Math]::Max(1, $Plan.Steps.Count)
        $stoppedAt = -1

        for ($s = 0; $s -lt $Plan.Steps.Count; $s++) {
            if ($Sync.Cancel) { Write-Log '중지 요청으로 남은 작업을 건너뜁니다.' 'WARN'; break }
            $State.Step = $s
            Set-StepProgress 0 1
            $step = $Plan.Steps[$s]
            if ($step.Id -eq 'docCentral') {
                # 문서중앙화 전에 윈도우 업데이트를 마무리하고, 재부팅이 필요하면 먼저 재부팅
                Wait-BackgroundUpdate
                if ($State.ResumeHere) { $stoppedAt = $s; break }
                # 문서중앙화 설치가 PC를 재부팅해도 남은 작업(정품 인증 확인 등)을 이어서 하도록 미리 예약
                Restart-Explorer
                $after = @($Plan.Steps | Select-Object -Skip ($s + 1) | ForEach-Object { $_.Id })
                try { Register-Resume $after 0 } catch { Write-Log "이어하기 예약 실패: $($_.Exception.Message)" 'WARN' }
            }
            if (-not $Plan.Background) { Write-Log "===== $($step.Title) =====" }
            Set-Status $step.Title
            $err0 = [int]$Sync.ErrorCount
            $warn0 = [int]$Sync.WarnCount
            Set-TaskState $step.Id 'running'
            if ($step.Id -notin 'docCentral', 'update') { Save-Checkpoint $s }
            try {
                switch ($step.Id) {
                    'network'     { Set-Network }
                    'programs'    { Install-Programs }
                    'fonts'       { Install-Fonts }
                    'taskbar'     { Set-Taskbar }
                    'desktop'     { Set-DesktopIcons }
                    'officeLinks' { New-OfficeShortcuts }
                    'misc'        { Set-Misc }
                    'uac'         { Set-Uac }
                    'power'       { Set-Power }
                    'startmenu'   { Set-StartMenu }
                    'edge'        { Set-EdgeSettings }
                    'chrome'      { Set-ChromeSettings }
                    'extensions'  { Install-BrowserExtensions }
                    'printer'     { Install-Printers }
                    'drivers'     { Install-Drivers }
                    'update'      { if ($Plan.Background) { Invoke-UpdateCycle } else { Start-BackgroundUpdate } }
                    'activation'  { Test-Activation }
                    'docCentral'  { Install-DocCentral }
                }
            }
            catch { Write-Log "$($step.Title) 중 오류: $($_.Exception.Message)" 'ERROR' }

            # 윈도우 업데이트는 백그라운드에서 계속되므로 끝날 때 따로 표시
            if ($step.Id -ne 'update' -or $Plan.Background) {
                if ([int]$Sync.ErrorCount -gt $err0) { Set-TaskState $step.Id 'error' '실패 항목 있음 (로그 참고)' }
                elseif ([int]$Sync.WarnCount -gt $warn0) { Set-TaskState $step.Id 'warn' '확인 필요 (로그 참고)' }
                else { Set-TaskState $step.Id 'done' }
            }
        }

        if ($Plan.Background) {
            # 백그라운드 업데이트: 재부팅 필요 여부만 알려줌 (재부팅은 메인 작업이 결정)
            if ($State.ResumeHere) { $Sync.NeedReboot = $true; $Sync.ResumeRound = $State.ResumeRound }
            Write-Log '윈도우 업데이트 작업 끝'
            return
        }

        # 모든 작업 뒤 (문서중앙화가 없을 때): 업데이트 마무리 확인
        if ($stoppedAt -lt 0 -and -not $Sync.Cancel) {
            Wait-BackgroundUpdate
            if ($State.ResumeHere) { $stoppedAt = $Plan.Steps.Count }
        }
        if ($State.ResumeHere -and -not $Sync.Cancel) {
            Write-Log '윈도우 업데이트 적용을 위해 재부팅이 필요합니다.' 'WARN'
            Request-UpdateReboot @($Plan.Steps | Select-Object -Skip $stoppedAt | ForEach-Object { $_.Id })
        }

        Restart-Explorer
        if ($Sync.Cancel) {
            Write-Log '===== 중지되었습니다 =====' 'WARN'
        }
        elseif ($Sync.ResumeRequested) {
            Write-Log '===== 재부팅 후 이어서 진행합니다 =====' 'OK'
        }
        else {
            Clear-Resume
            Write-Log '===== 모든 작업 완료 =====' 'OK'
        }
    }
    catch { Write-Log "예상치 못한 오류: $($_.Exception.Message)" 'ERROR' }
    finally {
        if ($State.Bg -and -not $Plan.Background) { $State.Bg.Sync.Cancel = $true }
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
$Gray     = [System.Drawing.Color]::Gray

function New-Control([string]$Type, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Text = $Text
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    if ($Type -ne 'GroupBox') { $c.Font = $Font }
    return $c
}

function New-Group([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $g = New-Control 'GroupBox' $Text $X $Y $W $H
    $g.Font = $BoldFont
    $form.Controls.Add($g)
    return $g
}

$form = New-Object System.Windows.Forms.Form
$form.Text = '사내 PC 자동 셋팅'
$form.ClientSize = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = $Font

# 실행 순서대로. 윈도우 업데이트는 백그라운드에서 시작해 프로그램 설치와 동시에 진행하고,
# 문서중앙화 직전(또는 마지막)에 끝나기를 기다려 재부팅이 필요하면 재부팅 후 이어서 진행
$TaskDefs = @(
    @{ Id = 'uac';         Title = '사용자 계정 컨트롤 끄기 (가장 아래)'; Default = $true },
    @{ Id = 'network';     Title = '이더넷 IP 설정';                    Default = $true },
    @{ Id = 'update';      Title = '윈도우 업데이트 (설치와 동시에 진행)'; Default = $true },
    @{ Id = 'programs';    Title = '프로그램 설치 (USB)';               Default = $true },
    @{ Id = 'fonts';       Title = '폰트 설치 (LG스마트체)';            Default = $true },
    @{ Id = 'taskbar';     Title = '작업표시줄 (뉴스·아이콘 정리)';      Default = $true },
    @{ Id = 'desktop';     Title = '바탕화면 아이콘 표시';              Default = $true },
    @{ Id = 'officeLinks'; Title = '엑셀·파워포인트·워드 바로가기';      Default = $true },
    @{ Id = 'misc';        Title = '파일 확장명 표시 / PC 이름';        Default = $true },
    @{ Id = 'power';       Title = '전원 설정';                         Default = $true },
    @{ Id = 'startmenu';   Title = '시작화면 정리 (엣지만)';            Default = $true },
    @{ Id = 'extensions';  Title = '크롬·엣지 업데이트 + ClouDoc 확장';  Default = $true },
    @{ Id = 'edge';        Title = '엣지 설정';                         Default = $true },
    @{ Id = 'chrome';      Title = '크롬 설정';                         Default = $true },
    @{ Id = 'printer';     Title = '프린터 설치';                       Default = $true },
    @{ Id = 'drivers';     Title = '드라이버 확인 (제조사 도구 등)';     Default = $false },
    @{ Id = 'docCentral';  Title = '문서중앙화 설치 (재부팅 여러 번)';   Default = $true },
    @{ Id = 'activation';  Title = '정품 인증 확인';                    Default = $true }
)

# --- 왼쪽: 작업 선택 ---
$grpTasks = New-Group '1. 실행할 작업 (분류별)' 12 8 330 340
# 화면에서는 분류별로 묶어서 보여줌 (실행 순서는 위 $TaskDefs 순서 그대로)
$TaskCategories = [ordered]@{
    '윈도우 설정'   = @('uac', 'network', 'taskbar', 'desktop', 'officeLinks', 'misc', 'power', 'startmenu')
    '프로그램 설치' = @('update', 'programs', 'fonts', 'printer', 'docCentral', 'drivers')
    '브라우저'      = @('extensions', 'edge', 'chrome')
    '기타'          = @('activation')
}
# 분류에 빠진 작업이 있으면 '기타' 에 넣음
$listed = @($TaskCategories.Values | ForEach-Object { $_ })
$TaskCategories['기타'] = @($TaskCategories['기타']) + @($TaskDefs | Where-Object { $listed -notcontains $_.Id } | ForEach-Object { $_.Id })

function Get-TaskCategory([string]$Id) {
    foreach ($cat in $TaskCategories.Keys) { if (@($TaskCategories[$cat]) -contains $Id) { return $cat } }
    return '기타'
}

$tvTasks = New-Control 'TreeView' '' 10 22 310 276
$tvTasks.CheckBoxes = $true
$tvTasks.ShowPlusMinus = $false
$tvTasks.ShowRootLines = $false
$tvTasks.ItemHeight = 20
$TaskNodes = @{}
foreach ($cat in $TaskCategories.Keys) {
    $parent = $tvTasks.Nodes.Add($cat)
    $parent.NodeFont = $BoldFont
    $parent.Text = $cat      # 굵은 글꼴에서 글자가 잘리지 않도록 다시 지정
    foreach ($id in @($TaskCategories[$cat])) {
        $def = $TaskDefs | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $def) { continue }
        $node = $parent.Nodes.Add($def.Title)
        $node.Tag = $id
        $node.Checked = [bool]$def.Default
        $TaskNodes[$id] = $node
    }
}
$tvTasks.ExpandAll()

# 분류 체크 = 아래 작업 전부, 작업 체크 = 분류 체크 상태 갱신
function Update-CategoryChecks {
    foreach ($parent in $tvTasks.Nodes) {
        $all = $true
        foreach ($n in $parent.Nodes) { if (-not $n.Checked) { $all = $false } }
        if ($parent.Checked -ne $all) { $parent.Checked = $all }
    }
}
$tvTasks.Add_AfterCheck({
    param($s, $e)
    if ($e.Action -eq [System.Windows.Forms.TreeViewAction]::Unknown) { return }   # 코드에서 바꾼 것은 무시
    if ($e.Node.Nodes.Count -gt 0) { foreach ($n in $e.Node.Nodes) { $n.Checked = $e.Node.Checked } }
    else { Update-CategoryChecks }
})
$tvTasks.Add_BeforeCollapse({ param($s, $e) $e.Cancel = $true })   # 분류는 항상 펼쳐둠

function Test-TaskChecked([string]$Id) { return ($TaskNodes.ContainsKey($Id) -and $TaskNodes[$Id].Checked) }
function Set-AllTasks([bool]$On) {
    foreach ($n in $TaskNodes.Values) { $n.Checked = $On }
    Update-CategoryChecks
}
Update-CategoryChecks
$btnTasksAll  = New-Control 'Button' '전체 선택' 10 302 150 30
$btnTasksNone = New-Control 'Button' '전체 해제' 170 302 150 30
$btnTasksAll.Add_Click({ Set-AllTasks $true })
$btnTasksNone.Add_Click({ Set-AllTasks $false })
$grpTasks.Controls.AddRange(@($tvTasks, $btnTasksAll, $btnTasksNone))

# 실행 중/끝난 뒤에는 체크 목록 대신 진행 상황 표시판을 보여줌 (✔ 완료 / ▶ 진행 중 / ✖ 실패 ...)
function New-StatusList([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Col1, [int]$W1) {
    $lv = New-Control 'ListView' '' $X $Y $W $H
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HeaderStyle = 'Nonclickable'
    $lv.ShowItemToolTips = $true
    $lv.Visible = $false
    [void]$lv.Columns.Add($Col1, $W1)
    [void]$lv.Columns.Add('상태', $W - $W1 - 24)
    return $lv
}
$lvTasks = New-StatusList 10 22 310 308 '작업' 150
$grpTasks.Controls.Add($lvTasks)

$btnConfig    = New-Control 'Button' '설정 파일 열기' 12 356 160 30
$btnReload    = New-Control 'Button' '설정 다시 불러오기' 182 356 160 30
$btnLogs      = New-Control 'Button' '로그 폴더 열기' 12 390 160 30
$btnDump      = New-Control 'Button' 'USB 폴더 목록 저장' 182 390 160 30
$btnSaveStart = New-Control 'Button' '시작화면 저장 (Win11)' 12 424 160 30
$btnOrder     = New-Control 'Button' '진행 순서 보기' 182 424 160 30
$btnOrder.Font = $BoldFont
$form.Controls.AddRange(@($btnConfig, $btnReload, $btnLogs, $btnDump, $btnSaveStart, $btnOrder))

# --- 가운데: 네트워크 / 프린터 / PC 이름 / 정품 인증 ---
$grpNet = New-Group '2. 이더넷 IP (수동 입력)' 354 8 400 184
$rows = @('어댑터', 'IP', '서브넷 마스크', '게이트웨이', 'DNS')
for ($i = 0; $i -lt $rows.Count; $i++) {
    $grpNet.Controls.Add((New-Control 'Label' $rows[$i] 12 (25 + $i * 30) 90 20))
}
$cmbAdapter = New-Control 'ComboBox' '' 104 22 286 24
$cmbAdapter.DropDownStyle = 'DropDownList'
$txtIp      = New-Control 'TextBox' $Config.network.ip 104 52 160 24
$txtSubnet  = New-Control 'TextBox' $Config.network.subnet 104 82 160 24
$txtGateway = New-Control 'TextBox' '192.168.0.1' 104 112 160 24
$txtDns1    = New-Control 'TextBox' $Config.network.dns1 104 142 160 24
$lblGwHint  = New-Control 'Label' 'IP 입력 시 자동 변경' 270 115 125 20
$lblGwHint.ForeColor = $Gray
$chkDhcp    = New-Control 'CheckBox' '자동으로 IP 받기' 270 52 125 24
$grpNet.Controls.AddRange(@($cmbAdapter, $txtIp, $txtSubnet, $txtGateway, $txtDns1, $lblGwHint, $chkDhcp))

# 지점: ERP 서버 주소와 기본 프린터가 정해짐
$grpSite = New-Group '3. 지점 (ERP 서버 / 프린터)' 354 198 400 48
$SiteRadios = @()
$x = 12
foreach ($site in @($Config.sites)) {
    $rb = New-Control 'RadioButton' $site.name $x 20 70 22
    $grpSite.Controls.Add($rb)
    $SiteRadios += $rb
    $x += 76
}
$lblSite = New-Control 'Label' '' ($x + 4) 22 (390 - $x) 20
$lblSite.ForeColor = $Gray
$grpSite.Controls.Add($lblSite)

$grpPrinter = New-Group '4. 설치할 프린터 (네트워크)' 354 252 400 92
$clbPrinters = New-Control 'CheckedListBox' '' 10 20 380 64
$clbPrinters.CheckOnClick = $true
$grpPrinter.Controls.Add($clbPrinters)

$grpName = New-Group 'PC 이름 변경 (선택)' 354 350 400 54
$txtName = New-Control 'TextBox' '' 10 22 150 24
$txtName.MaxLength = 15
$lblName = New-Control 'Label' "현재: $env:COMPUTERNAME  (비워두면 변경 안 함)" 168 25 225 20
$lblName.ForeColor = $Gray
$grpName.Controls.AddRange(@($txtName, $lblName))

$grpAct = New-Group 'Windows 정품 인증' 354 408 400 50
$lblAct = New-Control 'Label' '확인 중...' 10 22 172 22
$lblAct.AutoEllipsis = $true
$btnAct = New-Control 'Button' '인증 설정' 184 17 86 27
$btnCheck = New-Control 'Button' '마무리 체크리스트' 274 17 118 27
$btnCheck.Font = $BoldFont
$grpAct.Controls.AddRange(@($lblAct, $btnAct, $btnCheck))

# --- 오른쪽: USB / 프로그램 ---
$grpUsb = New-Group '5. USB 설치파일 폴더' 766 8 402 84
$txtUsb = New-Control 'TextBox' '' 10 22 300 24
$txtUsb.ReadOnly = $true
$btnUsb = New-Control 'Button' '찾아보기' 316 21 76 26
$lblUsb = New-Control 'Label' '' 10 54 382 20
$grpUsb.Controls.AddRange(@($txtUsb, $btnUsb, $lblUsb))

$grpApps = New-Group '6. 설치할 프로그램' 766 98 402 360
$clbPrograms = New-Control 'CheckedListBox' '' 10 22 382 290
$clbPrograms.CheckOnClick = $true
$clbPrograms.HorizontalScrollbar = $true
$btnPick   = New-Control 'Button' '설치파일 지정' 10 320 100 30
$btnRescan = New-Control 'Button' '다시 찾기' 116 320 80 30
$btnAdd    = New-Control 'Button' '+ 추가' 232 320 76 30
$btnRemove = New-Control 'Button' '삭제' 314 320 78 30
$grpApps.Controls.AddRange(@($clbPrograms, $btnPick, $btnRescan, $btnAdd, $btnRemove))
$lvPrograms = New-StatusList 10 22 382 290 '프로그램' 130
$grpApps.Controls.Add($lvPrograms)

# --- 아래: 진행 상황 ---
# 상태줄: 두 줄 (1줄 = 지금 하는 작업, 2줄 = 윈도우 업데이트 진행). 길면 끝을 … 로, 마우스를 올리면 전체
$lblStatus = New-Control 'Label' '대기 중' 12 462 1156 44
$lblStatus.Font = $BoldFont
$lblStatus.AutoEllipsis = $true
$StatusTip = New-Object System.Windows.Forms.ToolTip
$progress = New-Control 'ProgressBar' '' 12 508 1156 16
$txtLog = New-Control 'TextBox' '' 12 528 1156 178
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$btnStart = New-Control 'Button' '셋팅 시작' 1018 714 150 36
$btnStart.Font = $BoldFont
$btnStop = New-Control 'Button' '중지' 860 714 150 36
$btnStop.Font = $BoldFont
$btnStop.ForeColor = [System.Drawing.Color]::DarkRed
$btnStop.Enabled = $false
$form.Controls.AddRange(@($lblStatus, $progress, $txtLog, $btnStart, $btnStop))

# ---------------------------------------------------------------------------
# 화면 데이터
# ---------------------------------------------------------------------------
$script:AppRoot  = $null
$script:AppFiles = @()
$script:Adapters = @()

function Update-UsbInfo {
    if ($script:AppRoot) {
        $txtUsb.Text = $script:AppRoot
        $lblUsb.Text = "설치파일 $($script:AppFiles.Count)개 확인"
        $lblUsb.ForeColor = [System.Drawing.Color]::Green
    }
    else {
        $txtUsb.Text = ''
        $lblUsb.Text = "'$($Config.usb.label)' USB 를 꽂고 [다시 찾기] 또는 [찾아보기]"
        $lblUsb.ForeColor = [System.Drawing.Color]::Red
    }
}

function Find-Usb {
    $script:AppRoot = Find-AppFolder $script:Config
    $script:AppFiles = Get-AppFiles $script:AppRoot
    Update-UsbInfo
}

function Update-ProgramList {
    $checked = @{}
    for ($i = 0; $i -lt $clbPrograms.Items.Count; $i++) { $checked[$i] = $clbPrograms.GetItemChecked($i) }
    $clbPrograms.Items.Clear()
    $list = @($script:Config.programs)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $p = $list[$i]
        if ($p.uninstall) {
            $where = if (@(Get-UninstallEntries $p.uninstall).Count -gt 0) { '프로그램 추가/제거에서 삭제' } else { '(이미 없음)' }
        }
        elseif ($p.winget) {
            $usb = if ($p.find -or $p.path) { Find-Installer $script:AppRoot $script:AppFiles $p $null } else { $null }
            $where = "winget: $($p.winget)" + $(if ($usb) { "  (실패 시 USB: $([IO.Path]::GetFileName($usb)))" } else { '' })
        }
        else {
            $siteName = $(if (Get-SelectedSite) { (Get-SelectedSite).name } else { $null })
            $path = Find-Installer $script:AppRoot $script:AppFiles $p $siteName
            if ($path -and $script:AppRoot -and $path.StartsWith($script:AppRoot)) { $where = $path.Substring($script:AppRoot.Length).TrimStart('\') }
            elseif ($path) { $where = $path }
            else { $where = '⚠ 설치파일을 찾지 못함' }
        }
        if (Test-Installed $p) { $where = "(설치됨)  $where" }
        $isChecked = if ($checked.ContainsKey($i)) { $checked[$i] } else { -not ($p.PSObject.Properties.Name -contains 'selected' -and $p.selected -eq $false) }
        [void]$clbPrograms.Items.Add(('{0}   →   {1}' -f $p.name, $where), $isChecked)
    }
}

function Update-PrinterList {
    $clbPrinters.Items.Clear()
    foreach ($p in @($script:Config.printer.printers)) {
        [void]$clbPrinters.Items.Add(('{0}   ({1})' -f $p.name, $p.ip), $false)
    }
}

function Update-Adapters {
    $cmbAdapter.Items.Clear()
    $script:Adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -notmatch 'Wireless|Wi-?Fi|802\.11|Bluetooth|무선' -and $_.Name -notmatch 'Wi-?Fi|무선' } |
        Sort-Object @{ Expression = { $_.Status -ne 'Up' } }, Name)
    foreach ($a in $script:Adapters) { [void]$cmbAdapter.Items.Add(('{0} - {1} ({2})' -f $a.Name, $a.InterfaceDescription, $a.Status)) }
    if ($cmbAdapter.Items.Count -gt 0) { $cmbAdapter.SelectedIndex = 0 }
}

function Update-Activation {
    try {
        $a = Get-ActivationInfo
        $state = if ($a.Activated) { '인증됨' } else { '인증 안 됨' }
        $lblAct.Text = "$state  /  $($a.Edition)" + $(if ($a.IsHome) { ' (Home → Pro 업그레이드 필요)' } else { '' })
        $lblAct.ForeColor = if ($a.Activated -and -not $a.IsHome) { [System.Drawing.Color]::Green } else { [System.Drawing.Color]::Red }
        $script:ActText = $lblAct.Text
        $script:ActColor = $lblAct.ForeColor
        $StatusTip.SetToolTip($lblAct, $lblAct.Text)
    }
    catch { $lblAct.Text = '확인 실패' }
}

function Test-IPv4([string]$s) {
    $ip = $null
    return ($s -match '^\d{1,3}(\.\d{1,3}){3}$' -and [Net.IPAddress]::TryParse($s, [ref]$ip))
}

function Get-PrefixLength([string]$Mask) {
    if (-not (Test-IPv4 $Mask)) { return -1 }
    $bits = ([Net.IPAddress]::Parse($Mask).GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    if ($bits -match '01') { return -1 }
    return ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function Get-RelativeToApp([string]$Path) {
    if ($script:AppRoot -and $Path.StartsWith($script:AppRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($script:AppRoot.Length).TrimStart('\')
    }
    return $Path
}

# ---------------------------------------------------------------------------
# 이벤트
# ---------------------------------------------------------------------------
# IP 를 입력하면 게이트웨이를 같은 대역의 .1 로 자동 변경 (192.168.50.x → 192.168.50.1)
$txtIp.Add_TextChanged({
    $o = $txtIp.Text.Split('.')
    if ($o.Count -ge 3 -and $o[2] -match '^\d{1,3}$') { $txtGateway.Text = '{0}.{1}.{2}.1' -f $o[0], $o[1], $o[2] }
})
$txtIp.Add_GotFocus({ $txtIp.SelectionStart = $txtIp.Text.Length })

# 자동으로 IP 받기(DHCP)를 고르면 수동 입력칸은 사용하지 않음
$chkDhcp.Add_CheckedChanged({
    $manual = -not $chkDhcp.Checked
    foreach ($tb in @($txtIp, $txtSubnet, $txtGateway, $txtDns1)) { $tb.Enabled = $manual }
    $lblGwHint.Visible = $manual
})

$btnUsb.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "설치파일이 있는 '$($Config.usb.appFolder)' 폴더를 선택하세요."
    if ($fbd.ShowDialog() -eq 'OK') {
        $script:AppRoot = $fbd.SelectedPath.TrimEnd('\')
        $script:AppFiles = Get-AppFiles $script:AppRoot
        Update-UsbInfo
        Update-ProgramList
    }
})

$btnRescan.Add_Click({
    $form.Cursor = 'WaitCursor'
    Find-Usb
    Update-ProgramList
    $form.Cursor = 'Default'
})

$btnPick.Add_Click({
    $idx = $clbPrograms.SelectedIndex
    if ($idx -lt 0) { [System.Windows.Forms.MessageBox]::Show('목록에서 프로그램을 먼저 클릭하세요.') | Out-Null; return }
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = '설치파일 (*.exe;*.msi)|*.exe;*.msi|모든 파일 (*.*)|*.*'
    if ($script:AppRoot) { $ofd.InitialDirectory = $script:AppRoot }
    if ($ofd.ShowDialog() -ne 'OK') { return }
    $p = @($script:Config.programs)[$idx]
    $p | Add-Member -NotePropertyName path -NotePropertyValue (Get-RelativeToApp $ofd.FileName) -Force
    Save-Config $script:Config
    Update-ProgramList
})

$btnAdd.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = '설치파일 (*.exe;*.msi)|*.exe;*.msi|모든 파일 (*.*)|*.*'
    if ($script:AppRoot) { $ofd.InitialDirectory = $script:AppRoot }
    if ($ofd.ShowDialog() -ne 'OK') { return }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('목록에 표시할 이름을 입력하세요.', '프로그램 추가', [IO.Path]::GetFileNameWithoutExtension($ofd.FileName))
    if (-not $name) { return }
    $args2 = [Microsoft.VisualBasic.Interaction]::InputBox("무인설치 옵션을 입력하세요. (예: /S, /silent, /quiet)`n모르면 비워두세요. 설치 화면이 뜨면 직접 진행하면 됩니다.", '프로그램 추가', '')
    $entry = [ordered]@{ name = $name; path = (Get-RelativeToApp $ofd.FileName) }
    if ($args2) { $entry.args = $args2 }
    $script:Config.programs = @(@($script:Config.programs) | Where-Object { $null -ne $_ }) + [pscustomobject]$entry
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
    $clbPrograms.Items.Clear()
    Save-Config $script:Config
    Update-ProgramList
})

$btnConfig.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$ConfigPath`"" })

$btnReload.Add_Click({
    try {
        $script:Config = Read-Config
        $clbPrograms.Items.Clear()
        Find-Usb
        Update-ProgramList
        Update-PrinterList
        $lblStatus.Text = '설정을 다시 불러왔습니다.'
    }
    catch { [System.Windows.Forms.MessageBox]::Show("config.json 형식이 올바르지 않습니다.`n`n$($_.Exception.Message)", '오류', 'OK', 'Error') | Out-Null }
})

$btnLogs.Add_Click({
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    Start-Process explorer.exe -ArgumentList "`"$LogDir`""
})

# USB 폴더 구조를 텍스트로 저장 (설정 맞출 때 참고용)
$btnDump.Add_Click({
    if (-not $script:AppRoot) { [System.Windows.Forms.MessageBox]::Show('USB 폴더를 먼저 찾아주세요.') | Out-Null; return }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $out = Join-Path $LogDir 'usb_folder_list.txt'
    $lines = Get-ChildItem -LiteralPath $script:AppRoot -Recurse -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($script:AppRoot.Length).TrimStart('\')
        if ($_.PSIsContainer) { "[폴더] $rel" } else { "       $rel" }
    }
    Set-Content -LiteralPath $out -Value (@("기준 폴더: $($script:AppRoot)") + $lines) -Encoding UTF8
    Start-Process notepad.exe -ArgumentList "`"$out`""
})

# Windows 11: 이 PC의 시작화면 배치를 저장해 다른 PC에 그대로 적용
$btnSaveStart.Add_Click({
    if ([Environment]::OSVersion.Version.Build -lt 22000) { [System.Windows.Forms.MessageBox]::Show('Windows 11 에서만 사용합니다. Windows 10 은 자동으로 엣지만 남깁니다.') | Out-Null; return }
    $src = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin'
    if (-not (Test-Path -LiteralPath $src)) { [System.Windows.Forms.MessageBox]::Show('시작화면 파일을 찾지 못했습니다.') | Out-Null; return }
    $ans = [System.Windows.Forms.MessageBox]::Show("지금 이 PC의 시작화면 배치를 저장합니다.`n시작화면을 엣지만 남기고 정리한 상태인지 확인하세요.`n`n저장할까요?", '시작화면 저장', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    $dir = Join-Path $Root 'startmenu'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Copy-Item -LiteralPath $src -Destination (Join-Path $dir 'start2.bin') -Force
    [System.Windows.Forms.MessageBox]::Show('저장했습니다. 다음 PC부터는 이 배치가 자동으로 적용됩니다.') | Out-Null
})

$btnAct.Add_Click({ Start-Process 'ms-settings:activation' })

# --- 지점 선택 ---
function Get-SelectedSite {
    for ($i = 0; $i -lt $SiteRadios.Count; $i++) { if ($SiteRadios[$i].Checked) { return @($Config.sites)[$i] } }
    return $null
}

foreach ($rb in $SiteRadios) {
    $rb.Add_CheckedChanged({
        $site = Get-SelectedSite
        if (-not $site) { return }
        $lblSite.Text = "ERP 서버 $($site.erpServer)"
        Update-ProgramList
        # 이 지점의 기본 프린터를 체크 (김해는 2F/1F 를 직접 선택)
        $names = @($site.printers)
        $all = @($script:Config.printer.printers)
        for ($j = 0; $j -lt $all.Count; $j++) { $clbPrinters.SetItemChecked($j, ($names -contains $all[$j].name)) }
    })
}

# --- 설치 안내창 (항상 위) ---
$guideForm = New-Object System.Windows.Forms.Form
$guideForm.Text = 'PC 셋팅 - 설치 안내'
$guideForm.ClientSize = New-Object System.Drawing.Size(470, 380)
$guideForm.FormBorderStyle = 'FixedToolWindow'
$guideForm.TopMost = $true
$guideForm.ShowInTaskbar = $false
$guideForm.StartPosition = 'Manual'
$guideForm.ControlBox = $false
$guideForm.BackColor = [System.Drawing.Color]::LightYellow
$lblGuide = New-Object System.Windows.Forms.TextBox
$lblGuide.Multiline = $true
$lblGuide.ReadOnly = $true
$lblGuide.ScrollBars = 'Vertical'
$lblGuide.BorderStyle = 'None'
$lblGuide.BackColor = [System.Drawing.Color]::LightYellow
$lblGuide.Location = New-Object System.Drawing.Point(14, 12)
$lblGuide.Size = New-Object System.Drawing.Size(444, 312)
$lblGuide.Font = New-Object System.Drawing.Font('Malgun Gothic', 10.5)
$btnGuideOk = New-Object System.Windows.Forms.Button
$btnGuideOk.Text = '완료 (다음 단계로)'
$btnGuideOk.Font = $BoldFont
$btnGuideOk.Location = New-Object System.Drawing.Point(230, 334)
$btnGuideOk.Size = New-Object System.Drawing.Size(228, 36)
$btnGuideOk.Add_Click({ $script:Sync.GuideAck = $script:Sync.GuideWait })
$guideForm.Controls.AddRange(@($lblGuide, $btnGuideOk))
$script:LastGuide = ''

function Update-GuideWindow {
    $text = [string]$script:Sync.Guide
    if ($text -ne $script:LastGuide) {
        $script:LastGuide = $text
        if ($text) {
            # 글상자는 줄바꿈이 CRLF 여야 함
            $lblGuide.Text = $text.Replace("`r`n", "`n").Replace("`n", "`r`n")
            $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $guideForm.Location = New-Object System.Drawing.Point(($area.Right - $guideForm.Width - 12), ($area.Top + 12))
            if (-not $guideForm.Visible) { $guideForm.Show() }
        }
        elseif ($guideForm.Visible) { $guideForm.Hide() }
    }
    $wait = [string]$script:Sync.GuideWait
    $btnGuideOk.Visible = [bool]$wait
    if ($wait) { $btnGuideOk.Text = "$wait 완료 (다음으로)" }
}

# --- 진행 상황 표시판 ---
$C = [System.Drawing.Color]
$StateStyles = @{
    pending = @('·', '대기',                 $C::Gray,       $C::White)
    running = @('▶', '진행 중',              $C::RoyalBlue,  [System.Drawing.Color]::FromArgb(232, 241, 255))
    manual  = @('!', '직접 진행 필요',        $C::DarkOrange, $C::LightYellow)
    waitAck = @('!', '[완료] 버튼을 눌러주세요', $C::DarkOrange, $C::LightYellow)
    done    = @('✔', '완료',                 $C::Green,      $C::Honeydew)
    skipped = @('✔', '이미 완료',             $C::SeaGreen,   $C::Honeydew)
    warn    = @('!', '확인 필요',             $C::DarkOrange, $C::LightYellow)
    error   = @('✖', '실패',                 $C::Red,        $C::MistyRose)
    reboot  = @('↻', '재부팅 후 계속',         $C::Purple,     $C::Lavender)
    stopped = @('■', '중지됨',               $C::Gray,       $C::WhiteSmoke)
}

function Set-StatusRow($Item, [string]$Value) {
    if ($Item.Name -eq $Value) { return }     # 바뀐 것만 다시 그림
    $Item.Name = $Value
    $parts = $Value.Split('|', 2)
    $style = $StateStyles[$parts[0]]
    if (-not $style) { return }
    $text = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $style[1] }
    $Item.SubItems[1].Text = "$($style[0]) $text"
    $Item.ToolTipText = "$($Item.Text) : $text"   # 글자가 잘려도 마우스를 올리면 전체 내용
    $Item.ForeColor = $style[2]
    $Item.BackColor = $style[3]
}

function Add-StatusRow($List, [string]$Key, [string]$Label, [string]$Group = '') {
    $it = New-Object System.Windows.Forms.ListViewItem($Label)
    [void]$it.SubItems.Add('')
    $it.Tag = $Key
    if ($Group) {
        $g = $List.Groups[$Group]
        if (-not $g) { $g = $List.Groups.Add($Group, $Group) }
        $it.Group = $g
    }
    [void]$List.Items.Add($it)
    Set-StatusRow $it 'pending|'
}

function Update-StatusView {
    if (-not $script:Sync) { return }
    foreach ($pair in @(@($lvTasks, $script:Sync.TaskStates), @($lvPrograms, $script:Sync.ProgStates))) {
        $list = $pair[0]; $states = $pair[1]
        if (-not $states) { continue }
        foreach ($it in $list.Items) {
            $v = $states[[string]$it.Tag]
            if ($v) { Set-StatusRow $it $v }
        }
    }
    $doneT = @($lvTasks.Items | Where-Object { $_.Name -match '^(done|skipped)' }).Count
    $doneP = @($lvPrograms.Items | Where-Object { $_.Name -match '^(done|skipped)' }).Count
    $grpTasks.Text = "1. 진행 상황  (완료 $doneT / $($lvTasks.Items.Count))"
    $grpApps.Text  = "6. 프로그램 진행 상황  (완료 $doneP / $($lvPrograms.Items.Count))"
    Update-OrderWindow
}

# --- 진행 순서 창 (실제 실행 순서 + 설명 + 실시간 상태) ---
$TaskNotes = @{
    uac         = '맨 처음 실행'
    network     = '수동 IP 또는 자동으로 받기'
    update      = '백그라운드에서 시작 → 아래 작업들과 동시에 진행'
    programs    = '30초 간격으로 실행해 동시에 설치 (+ OneDrive 삭제)'
    fonts       = ''
    taskbar     = ''
    desktop     = ''
    officeLinks = '오피스 설치가 끝난 뒤'
    misc        = 'PC 이름은 재부팅 후 적용'
    power       = ''
    startmenu   = ''
    extensions  = '브라우저 설정보다 먼저 업데이트'
    edge        = '설정 후 실행 중인 엣지 닫기'
    chrome      = '설정 후 실행 중인 크롬 닫기'
    printer     = '체크한 프린터만'
    drivers     = ''
    docCentral  = '업데이트 끝난 것 확인 후 (재부팅되면 로그인 후 이어서)'
    activation  = '마지막 확인'
}
$script:OrderForm = $null
$script:OrderSig = ''

function Update-OrderWindow {
    if (-not $script:OrderForm -or $script:OrderForm.IsDisposed -or -not $script:OrderForm.Visible) { return }
    $lv = $script:OrderForm.Tag
    $running = $script:Running -or ($lvTasks.Visible -and $script:Sync)
    $sig = (@($TaskDefs | ForEach-Object { "$($_.Id)=$(Test-TaskChecked $_.Id)" }) -join ',') + "|$running"
    if ($sig -ne $script:OrderSig) {
        # 체크 상태가 바뀌었으면 목록을 다시 만듦
        $script:OrderSig = $sig
        $lv.BeginUpdate()
        $lv.Items.Clear()
        $n = 0
        foreach ($t in $TaskDefs) {
            $on = Test-TaskChecked $t.Id
            $num = if ($on) { $n++; "$n" } else { '-' }
            $it = New-Object System.Windows.Forms.ListViewItem($num)
            [void]$it.SubItems.Add($t.Title)
            [void]$it.SubItems.Add((Get-TaskCategory $t.Id))
            [void]$it.SubItems.Add([string]$TaskNotes[$t.Id])
            [void]$it.SubItems.Add($(if ($on) { '' } else { '제외' }))
            $it.Tag = $t.Id
            if (-not $on) { $it.ForeColor = [System.Drawing.Color]::Silver }
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
    }
    # 진행 중이면 상태 표시
    if ($script:Sync -and $script:Sync.TaskStates) {
        foreach ($it in $lv.Items) {
            if ($it.Text -eq '-') { continue }
            $v = [string]$script:Sync.TaskStates[[string]$it.Tag]
            if (-not $v) { $v = 'pending|' }
            if ($it.SubItems[4].Tag -eq $v) { continue }
            $it.SubItems[4].Tag = $v
            $parts = $v.Split('|', 2)
            $style = $StateStyles[$parts[0]]
            if (-not $style) { continue }
            $text = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { $style[1] }
            $it.SubItems[4].Text = "$($style[0]) $text"
            $it.ToolTipText = $text
            $it.ForeColor = $style[2]
            $it.BackColor = $style[3]
        }
    }
}

function Show-OrderWindow {
    if ($script:OrderForm -and -not $script:OrderForm.IsDisposed) {
        $script:OrderForm.Show()
        $script:OrderForm.Activate()
        $script:OrderSig = ''
        Update-OrderWindow
        return
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'PC 셋팅 - 진행 순서'
    $f.ClientSize = New-Object System.Drawing.Size(1000, 520)
    $f.StartPosition = 'CenterParent'
    $f.Font = $Font
    $f.ShowInTaskbar = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '체크한 작업이 아래 번호 순서대로 실행됩니다. (회색 = 체크 안 함)'
    $lbl.Location = New-Object System.Drawing.Point(12, 10)
    $lbl.Size = New-Object System.Drawing.Size(976, 20)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.HeaderStyle = 'Nonclickable'
    $lv.Location = New-Object System.Drawing.Point(12, 34)
    $lv.Size = New-Object System.Drawing.Size(976, 440)
    $lv.ShowItemToolTips = $true
    $lv.Anchor = 'Top, Bottom, Left, Right'
    foreach ($col in @(@('순서', 48), @('작업', 230), @('분류', 90), @('설명', 230), @('상태', 355))) { [void]$lv.Columns.Add($col[0], $col[1]) }
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = '닫기'
    $btnClose.Location = New-Object System.Drawing.Point(888, 482)
    $btnClose.Size = New-Object System.Drawing.Size(100, 30)
    $btnClose.Anchor = 'Bottom, Right'
    $btnClose.Add_Click({ $script:OrderForm.Hide() })
    $f.Controls.AddRange(@($lbl, $lv, $btnClose))
    $f.Tag = $lv
    # 닫기(X) 는 숨기기만 (다시 열 때 그대로)
    $f.Add_FormClosing({ param($s, $e) if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $s.Hide() } })
    $script:OrderForm = $f
    $script:OrderSig = ''
    $f.Show($form)
    Update-OrderWindow
}

$btnOrder.Add_Click({ Show-OrderWindow })

# 셋팅이 끝난 뒤 직접 해야 할 일 (config.json 의 finishChecklist)
function Show-Checklist {
    if ($script:CheckForm -and -not $script:CheckForm.IsDisposed) {
        Update-ChecklistActivation
        $script:CheckForm.Show()
        $script:CheckForm.Activate()
        return
    }
    $items = @($Config.finishChecklist | Where-Object { $_ })
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'PC 셋팅 - 마무리 체크리스트 (직접 해야 할 일)'
    $f.ClientSize = New-Object System.Drawing.Size(560, 560)
    $f.StartPosition = 'CenterParent'
    $f.Font = $Font
    $f.ShowInTaskbar = $true
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = '자동 셋팅이 끝났습니다. 아래 항목은 직접 진행하고 하나씩 체크하세요.'
    $hdr.Font = $BoldFont
    $hdr.Location = New-Object System.Drawing.Point(12, 10)
    $hdr.Size = New-Object System.Drawing.Size(536, 22)
    $pnl = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnl.FlowDirection = 'TopDown'
    $pnl.WrapContents = $false
    $pnl.AutoScroll = $true
    $pnl.BorderStyle = 'FixedSingle'
    $pnl.BackColor = [System.Drawing.Color]::White
    $pnl.Location = New-Object System.Drawing.Point(12, 36)
    $pnl.Size = New-Object System.Drawing.Size(536, 470)
    $pnl.Anchor = 'Top, Bottom, Left, Right'
    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(12, 522)
    $lblCount.Size = New-Object System.Drawing.Size(300, 24)
    $lblCount.Font = $BoldFont
    $lblCount.Anchor = 'Bottom, Left'
    $script:CheckBoxes = @()
    $script:CheckActLabel = $null
    $n = 0
    foreach ($it in $items) {
        $n++
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = "$n. $it"
        $cb.AutoSize = $true
        $cb.MaximumSize = New-Object System.Drawing.Size(500, 0)
        $cb.Margin = New-Object System.Windows.Forms.Padding(8, 10, 8, 2)
        $cb.Font = $BoldFont
        $cb.Add_CheckedChanged({
            param($s, $e)
            $s.ForeColor = if ($s.Checked) { [System.Drawing.Color]::Gray } else { [System.Drawing.SystemColors]::ControlText }
            $s.Font = if ($s.Checked) { New-Object System.Drawing.Font($BoldFont, ([System.Drawing.FontStyle]::Bold -bor [System.Drawing.FontStyle]::Strikeout)) } else { $BoldFont }
            Update-ChecklistCount
        })
        [void]$pnl.Controls.Add($cb)
        $script:CheckBoxes += $cb
        if ($it -like '*정품*' -and -not $script:CheckActLabel) {
            $al = New-Object System.Windows.Forms.Label
            $al.AutoSize = $true
            $al.Margin = New-Object System.Windows.Forms.Padding(30, 0, 8, 2)
            [void]$pnl.Controls.Add($al)
            $script:CheckActLabel = $al
        }
    }
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = '닫기'
    $btnClose.Location = New-Object System.Drawing.Point(448, 518)
    $btnClose.Size = New-Object System.Drawing.Size(100, 30)
    $btnClose.Anchor = 'Bottom, Right'
    $btnClose.Add_Click({ $script:CheckForm.Hide() })
    $f.Controls.AddRange(@($hdr, $pnl, $lblCount, $btnClose))
    # 닫기(X) 는 숨기기만 (다시 열어도 체크한 것이 그대로)
    $f.Add_FormClosing({ param($s, $e) if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $s.Hide() } })
    $script:CheckForm = $f
    $script:CheckCountLabel = $lblCount
    Update-ChecklistActivation
    Update-ChecklistCount
    $f.Show($form)
}

function Update-ChecklistCount {
    if (-not $script:CheckCountLabel) { return }
    $done = @($script:CheckBoxes | Where-Object { $_.Checked }).Count
    $all = @($script:CheckBoxes).Count
    $script:CheckCountLabel.Text = "확인 완료 $done / $all"
    $script:CheckCountLabel.ForeColor = if ($all -gt 0 -and $done -eq $all) { [System.Drawing.Color]::Green } else { [System.Drawing.Color]::DarkOrange }
}

function Update-ChecklistActivation {
    if (-not $script:CheckActLabel) { return }
    Update-Activation
    $script:CheckActLabel.Text = "현재 상태: $($script:ActText)"
    $script:CheckActLabel.ForeColor = $script:ActColor
}

$btnCheck.Add_Click({ Show-Checklist })

# 윈도우 업데이트 재부팅: 묻지 않고 카운트다운 후 자동 재부팅 (취소만 가능)
function Show-RebootCountdown([int]$Seconds) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'PC 셋팅 - 자동 재부팅'
    $f.ClientSize = New-Object System.Drawing.Size(440, 170)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.TopMost = $true
    $f.Font = $Font
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(14, 12)
    $lbl.Size = New-Object System.Drawing.Size(412, 104)
    $btnNow = New-Object System.Windows.Forms.Button
    $btnNow.Text = '지금 재부팅'
    $btnNow.Location = New-Object System.Drawing.Point(206, 126)
    $btnNow.Size = New-Object System.Drawing.Size(110, 32)
    $btnNow.DialogResult = 'Yes'
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '재부팅 취소'
    $btnCancel.Location = New-Object System.Drawing.Point(322, 126)
    $btnCancel.Size = New-Object System.Drawing.Size(104, 32)
    $btnCancel.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($lbl, $btnNow, $btnCancel))
    $script:RebootLeft = $Seconds
    $script:RebootLabel = $lbl
    $script:RebootForm = $f
    $script:RebootSetText = {
        $script:RebootLabel.Text = "윈도우 업데이트를 적용하기 위해 $($script:RebootLeft)초 후 자동으로 재부팅합니다.`n설치 중인 프로그램이 없는 것을 확인했습니다.`n`n재부팅 후 로그인하면 남은 작업을 자동으로 이어서 진행합니다.`n(USB 는 꽂아둔 채로 두세요)"
    }
    & $script:RebootSetText
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = 1000
    $t.Add_Tick({
        $script:RebootLeft--
        if ($script:RebootLeft -le 0) { $script:RebootForm.DialogResult = 'Yes'; return }
        & $script:RebootSetText
    })
    $t.Start()
    $r = $f.ShowDialog()
    $t.Stop()
    $t.Dispose()
    $f.Dispose()
    return ($r -ne 'Cancel')
}
$tvTasks.Add_AfterCheck({ Update-OrderWindow })

# 끝난 뒤 아직 '대기/진행 중' 으로 남은 줄 정리 (중지 → 중지됨, 재부팅 → 재부팅 후 계속)
function Close-StatusView([string]$Leftover) {
    foreach ($pair in @(@($lvTasks, $script:Sync.TaskStates), @($lvPrograms, $script:Sync.ProgStates))) {
        foreach ($it in $pair[0].Items) {
            if ($it.Name -match '^(pending|running|manual|waitAck)') { $pair[1][[string]$it.Tag] = "$Leftover|" }
        }
    }
    Update-StatusView
}

function Show-StatusView([bool]$On) {
    $tvTasks.Visible = -not $On
    $lvTasks.Visible = $On
    $clbPrograms.Visible = -not $On
    $lvPrograms.Visible = $On
    foreach ($b in @($btnPick, $btnRescan, $btnAdd, $btnRemove, $btnTasksAll, $btnTasksNone)) { $b.Visible = -not $On }
    if (-not $On) {
        $grpTasks.Text = '1. 실행할 작업 (분류별)'
        $grpApps.Text = '6. 설치할 프로그램'
        $btnStart.Text = '셋팅 시작'
    }
}

# --- 시작 ---
$script:Running = $false
$script:ResumeState = $null
# 진행 상황 표시판이 회색으로 흐려지지 않도록 그룹 대신 개별 컨트롤만 잠금
$controlsToLock = @($tvTasks, $btnTasksAll, $btnTasksNone, $grpNet, $grpSite, $grpPrinter, $grpName, $grpUsb, $clbPrograms, $btnPick, $btnRescan, $btnAdd, $btnRemove, $btnStart, $btnConfig, $btnReload, $btnSaveStart)

function Start-Setup([bool]$Auto = $false) {
    # 지난 결과를 보고 있는 중이면 먼저 선택 화면으로 돌아감
    if ($lvTasks.Visible -and -not $Auto) {
        Show-StatusView $false
        $lblStatus.Text = '실행할 작업과 프로그램을 확인한 뒤 [셋팅 시작] 을 누르세요.'
        return
    }
    $steps = @($TaskDefs | Where-Object { Test-TaskChecked $_.Id })
    $resume = $script:ResumeState
    if ($steps.Count -eq 0 -and -not $resume) { [System.Windows.Forms.MessageBox]::Show('실행할 작업을 하나 이상 선택하세요.') | Out-Null; return }
    $ids = @($steps | ForEach-Object { $_.Id })

    # 네트워크 입력 확인
    $network = $null
    if ($ids -contains 'network' -and $chkDhcp.Checked) {
        if ($cmbAdapter.SelectedIndex -lt 0) { [System.Windows.Forms.MessageBox]::Show('이더넷 어댑터를 찾지 못했습니다. 랜카드 드라이버를 확인하세요.') | Out-Null; return }
        $network = @{ IfIndex = $script:Adapters[$cmbAdapter.SelectedIndex].ifIndex; Dhcp = $true }
    }
    elseif ($ids -contains 'network') {
        $prefix = Get-PrefixLength $txtSubnet.Text.Trim()
        if ($cmbAdapter.SelectedIndex -lt 0) { [System.Windows.Forms.MessageBox]::Show('이더넷 어댑터를 찾지 못했습니다. 랜카드 드라이버를 확인하세요.') | Out-Null; return }
        if (-not (Test-IPv4 $txtIp.Text.Trim())) { [System.Windows.Forms.MessageBox]::Show('IP 주소를 끝까지 입력하세요. (예: 192.168.0.25)') | Out-Null; $txtIp.Focus(); return }
        if ($prefix -lt 1) { [System.Windows.Forms.MessageBox]::Show('서브넷 마스크가 올바르지 않습니다.') | Out-Null; return }
        if (-not (Test-IPv4 $txtGateway.Text.Trim())) { [System.Windows.Forms.MessageBox]::Show('게이트웨이 주소가 올바르지 않습니다.') | Out-Null; return }
        $network = @{
            IfIndex = $script:Adapters[$cmbAdapter.SelectedIndex].ifIndex
            IP      = $txtIp.Text.Trim()
            Subnet  = $txtSubnet.Text.Trim()
            Prefix  = $prefix
            Gateway = $txtGateway.Text.Trim()
            Dns     = @($txtDns1.Text.Trim()) | Where-Object { Test-IPv4 $_ }
        }
    }

    $needUsb = @('programs', 'fonts', 'printer', 'docCentral') | Where-Object { $ids -contains $_ }
    if ($needUsb -and -not $script:AppRoot) {
        [System.Windows.Forms.MessageBox]::Show("USB 설치파일 폴더를 찾지 못했습니다.`n'$($Config.usb.label)' USB 를 꽂고 [다시 찾기] 를 누르거나 [찾아보기] 로 폴더를 선택한 뒤 [셋팅 시작] 을 누르세요.") | Out-Null
        return
    }

    $newName = $txtName.Text.Trim()
    if ($newName -and $ids -contains 'misc' -and $newName -notmatch '^[A-Za-z0-9-]{1,15}$') {
        [System.Windows.Forms.MessageBox]::Show('PC 이름은 영문, 숫자, 하이픈(-)만 사용해 15자 이내로 입력하세요.') | Out-Null
        return
    }

    $allPrograms = @($script:Config.programs)
    $selectedPrograms = @(foreach ($i in $clbPrograms.CheckedIndices) { $allPrograms[$i] })
    $allPrinters = @($script:Config.printer.printers)
    $selectedPrinters = @(foreach ($i in $clbPrinters.CheckedIndices) { $allPrinters[$i] })

    $site = Get-SelectedSite
    if ($resume -and $resume.Site) { $site = $resume.Site }
    $needSite = ($ids -contains 'programs' -and @($selectedPrograms | Where-Object { "$($_.clipboard)$($_.guide)" -match '\{erpServer\}' }).Count -gt 0)
    if ($needSite -and -not $site) {
        [System.Windows.Forms.MessageBox]::Show('지점(부산/김해)을 선택하세요. ERP 서버 주소가 지점에 따라 다릅니다.') | Out-Null
        return
    }

    if (-not $Auto) {
        $summary = ($steps | ForEach-Object { " - $($_.Title)" }) -join "`n"
        $extra = ''
        if ($network -and $network.Dhcp) { $extra += "`nIP: 자동으로 받기 (DHCP)" }
        elseif ($network) { $extra += "`nIP: $($network.IP) / 게이트웨이: $($network.Gateway)" }
        if ($site) { $extra += "`n지점: $($site.name) (ERP $($site.erpServer))" }
        $extra += "`n프로그램: $($selectedPrograms.Count)개 / 프린터: $(($selectedPrinters | ForEach-Object { $_.name }) -join ', ')"
        $ans = [System.Windows.Forms.MessageBox]::Show("다음 작업을 시작합니다.`n`n$summary`n$extra`n`n진행할까요?", 'PC 셋팅', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
    }

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $logFile = Join-Path $LogDir ('setup_{0}_{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($resume -and $resume.LogFile -and (Test-Path -LiteralPath (Split-Path $resume.LogFile))) { $logFile = $resume.LogFile }

    $plan = @{
        Root         = $Root
        AppRoot      = $script:AppRoot
        Config       = $script:Config
        CommonCode   = $Common.ToString()
        ResumePath   = $ResumePath
        Steps        = $steps
        Network      = $network
        Programs     = $selectedPrograms
        Printers     = $selectedPrinters
        Site         = $site
        UpdateRound  = $(if ($resume) { [int]$resume.UpdateRound } else { 0 })
        WorkerCode   = $Worker.ToString()
        LauncherExe  = $LauncherExe
        ComputerName = $newName
        LogFile      = $logFile
    }

    $script:Sync = [hashtable]::Synchronized(@{
        Queue           = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Notices         = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Status          = '시작 중...'
        Percent         = 0
        StepCount       = 1
        Done            = $false
        RebootRequired  = $false
        ResumeRequested = $false
        Guide           = ''
        GuideWait       = ''
        GuideAck        = ''
        TaskStates      = [hashtable]::Synchronized(@{})
        ProgStates      = [hashtable]::Synchronized(@{})
        ErrorCount      = 0
        WarnCount       = 0
        Cancel          = $false
        LogLock         = New-Object System.Object
        Bg              = $null
        BgPS            = $null
    })
    if ($resume) { foreach ($n in @($resume.Notices)) { if ($n) { [void]$script:Sync.Notices.Add($n) } } }
    $script:ResumeState = $null

    # 진행 상황 표시판 준비
    $lvTasks.Items.Clear()
    $lvTasks.Groups.Clear()
    foreach ($cat in $TaskCategories.Keys) {
        foreach ($st in @($steps | Where-Object { (Get-TaskCategory $_.Id) -eq $cat })) { Add-StatusRow $lvTasks $st.Id $st.Title $cat }
    }
    $lvPrograms.Items.Clear()
    if ($ids -contains 'programs') { foreach ($p in $selectedPrograms) { Add-StatusRow $lvPrograms $p.name $p.name } }
    Show-StatusView $true
    Update-StatusView

    $txtLog.Clear()
    $script:RunStart = Get-Date
    foreach ($c in $controlsToLock) { $c.Enabled = $false }
    $btnStop.Enabled = $true
    $script:Running = $true

    $script:Runspace = [runspacefactory]::CreateRunspace()
    $script:Runspace.ApartmentState = 'STA'
    $script:Runspace.Open()
    $script:PS = [powershell]::Create()
    $script:PS.Runspace = $script:Runspace
    [void]$script:PS.AddScript($Worker.ToString()).AddArgument($script:Sync).AddArgument($plan)
    $script:Handle = $script:PS.BeginInvoke()
    $timer.Start()
}

$btnStart.Add_Click({ Start-Setup $false })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    $line = $null
    while ($script:Sync.Queue.TryDequeue([ref]$line)) { $txtLog.AppendText($line + "`r`n") }
    $progress.Value = [Math]::Min(100, [Math]::Max(0, [int]$script:Sync.Percent))
    # 줄마다 길이를 잘라서 두 줄이 서로 밀리지 않게 (전체 내용은 마우스를 올리면 보임)
    $cut = { param($t) $t = [string]$t; if ($t.Length -gt 85) { $t.Substring(0, 84) + '…' } else { $t } }
    $full = [string]$script:Sync.Status
    if ($script:RunStart -and $script:Running) {
        $el = (Get-Date) - $script:RunStart
        $full = ('[경과 {0}:{1:00}:{2:00}]  ' -f [int][math]::Floor($el.TotalHours), $el.Minutes, $el.Seconds) + $full
    }
    $status = & $cut $full
    $bg = $script:Sync.Bg
    if ($bg -and -not $bg.Done) {
        $full += "`n업데이트: $($bg.Status)"
        $status += "`n" + (& $cut "업데이트: $($bg.Status)")
    }
    if ($StatusTip.GetToolTip($lblStatus) -ne $full) { $StatusTip.SetToolTip($lblStatus, $full) }
    $lblStatus.Text = $status
    Update-GuideWindow
    Update-StatusView

    if (-not $script:Sync.Done) { return }

    $timer.Stop()
    $script:Sync.Guide = ''
    Update-GuideWindow
    try { $script:PS.EndInvoke($script:Handle) } catch { $txtLog.AppendText("[오류] $($_.Exception.Message)`r`n") }
    foreach ($e in $script:PS.Streams.Error) { $txtLog.AppendText("[오류] $e`r`n") }
    $script:PS.Dispose()
    $script:Runspace.Dispose()
    $script:Running = $false
    foreach ($c in $controlsToLock) { $c.Enabled = $true }
    $btnStop.Enabled = $false
    $btnStop.Text = '중지'
    if ($script:Sync.Cancel) { Close-StatusView 'stopped' }
    elseif ($script:Sync.ResumeRequested) { Close-StatusView 'reboot' }
    else { Update-StatusView }
    $btnStart.Text = '다시 선택'
    Update-ProgramList
    Update-Activation

    if ($script:Sync.Cancel) {
        [System.Windows.Forms.MessageBox]::Show("중지했습니다.`n`n이미 실행된 설치 창이나 진행 중이던 윈도우 업데이트는 그대로 남아 있을 수 있습니다.`n다시 시작하려면 [셋팅 시작] 을 누르세요. (이미 설치된 프로그램은 건너뜁니다)", 'PC 셋팅', 'OK', 'Information') | Out-Null
        return
    }

    $errors = @($txtLog.Lines | Where-Object { $_ -like '*`[ERROR`]*' }).Count

    # 윈도우 업데이트 재부팅: 로그인하면 자동으로 이어서 진행
    if ($script:Sync.ResumeRequested) {
        $sec = if ($Config.windowsUpdate.autoRebootSeconds) { [int]$Config.windowsUpdate.autoRebootSeconds } else { 15 }
        if (Show-RebootCountdown $sec) { Restart-Computer -Force }
        else {
            [System.Windows.Forms.MessageBox]::Show("재부팅을 취소했습니다.`n직접 재부팅하면 로그인 후 남은 작업을 자동으로 이어서 진행합니다.", 'PC 셋팅', 'OK', 'Information') | Out-Null
        }
        return
    }

    $msg = if ($errors -gt 0) { "셋팅이 끝났습니다. 실패한 항목이 $errors 개 있습니다. 로그를 확인하세요." } else { '셋팅이 모두 끝났습니다.' }
    if ($script:Sync.Notices.Count -gt 0) {
        $msg += "`n`n[확인이 필요한 항목]`n" + (($script:Sync.Notices | ForEach-Object { "• $_" }) -join "`n")
    }

    # 직접 해야 할 일 체크리스트 (메인 화면의 [마무리 체크리스트] 로 언제든 다시 열 수 있음)
    if (@($Config.finishChecklist).Count -gt 0) { Show-Checklist }

    if ($script:Sync.RebootRequired) {
        $ans = [System.Windows.Forms.MessageBox]::Show("$msg`n`n재부팅이 필요한 항목이 있습니다. 지금 재부팅할까요?`n(마무리 체크리스트를 먼저 확인하세요)", 'PC 셋팅', 'YesNo', 'Question')
        if ($ans -eq 'Yes') { Restart-Computer -Force }
    }
    else {
        [System.Windows.Forms.MessageBox]::Show($msg, 'PC 셋팅', 'OK', 'Information') | Out-Null
    }
})

# 중지: 진행 중인 작업을 멈추고 재부팅 후 이어하기 예약도 취소
# (이미 실행된 설치 프로그램은 강제로 끄지 않음 - 설치 중에 끄면 프로그램이 망가질 수 있음)
function Stop-Setup {
    if (-not $script:Running) { return }
    $ans = [System.Windows.Forms.MessageBox]::Show("진행 중인 작업을 중지할까요?`n`n이미 실행된 설치 창은 그대로 두니 필요하면 직접 닫아주세요.`n재부팅 후 이어하기 예약도 취소됩니다.", 'PC 셋팅 - 중지', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    $script:Sync.Cancel = $true
    $script:Sync.GuideAck = $script:Sync.GuideWait
    if ($script:Sync.Bg) { $script:Sync.Bg.Cancel = $true }
    try { [void]$script:PS.BeginStop($null, $null) } catch { }
    try { if ($script:Sync.BgPS) { [void]$script:Sync.BgPS.BeginStop($null, $null) } } catch { }
    Unregister-ScheduledTask -TaskName 'PCSetupResume' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ResumePath -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
    $btnStop.Enabled = $false
    $btnStop.Text = '중지하는 중...'
}

$btnStop.Add_Click({ Stop-Setup })

$form.Add_FormClosing({
    param($s, $e)
    if ($script:Running) {
        [System.Windows.Forms.MessageBox]::Show('작업이 진행 중입니다. 멈추려면 [중지] 버튼을 누르세요.', 'PC 셋팅', 'OK', 'Warning') | Out-Null
        $e.Cancel = $true
    }
})

# 재부팅 전에 저장한 상태 불러오기
function Read-ResumeState {
    if (-not (Test-Path -LiteralPath $ResumePath)) { return $null }
    try { return (Get-Content -LiteralPath $ResumePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Apply-ResumeState($State) {
    $ids = @($State.Steps)
    foreach ($id in $TaskNodes.Keys) { $TaskNodes[$id].Checked = ($ids -contains $id) }
    Update-CategoryChecks
    # 지점을 먼저 고른 뒤(지점 기본 프린터가 체크됨) 저장된 프린터 선택으로 덮어씀
    if ($State.Site) {
        $sites = @($Config.sites)
        for ($i = 0; $i -lt $sites.Count; $i++) { if ($sites[$i].name -eq $State.Site.name) { $SiteRadios[$i].Checked = $true } }
    }
    $names = @($State.Printers | ForEach-Object { $_.name })
    $all = @($script:Config.printer.printers)
    for ($j = 0; $j -lt $all.Count; $j++) { $clbPrinters.SetItemChecked($j, ($names -contains $all[$j].name)) }
}

# 창이 뜬 뒤에 USB / 어댑터 / 정품 인증 확인
$form.Add_Shown({
    $form.Cursor = 'WaitCursor'
    $lblStatus.Text = 'USB 와 PC 상태를 확인하는 중...'
    $form.Refresh()
    Update-Adapters
    Update-PrinterList
    Find-Usb
    Update-ProgramList
    Update-Activation
    $lblStatus.Text = '대기 중'
    $form.Cursor = 'Default'
    $txtIp.Focus()
    $txtIp.SelectionStart = $txtIp.Text.Length

    $state = Read-ResumeState
    if (-not $state) {
        if ($Resume) {
            Unregister-ScheduledTask -TaskName 'PCSetupResume' -Confirm:$false -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
        }
        return
    }
    if (-not $Resume) {
        $ans = [System.Windows.Forms.MessageBox]::Show("재부팅 전에 진행하던 작업이 남아 있습니다.`n($($state.Steps -join ', '))`n`n이어서 진행할까요?`n[아니요] 를 누르면 처음부터 새로 진행합니다.", 'PC 셋팅', 'YesNo', 'Question')
        if ($ans -ne 'Yes') {
            Unregister-ScheduledTask -TaskName 'PCSetupResume' -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ResumePath -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
            return
        }
    }
    $script:ResumeState = $state
    Apply-ResumeState $state
    $lblStatus.Text = '재부팅 후 남은 작업을 이어서 진행합니다.'
    Start-Setup $true
})

[void]$form.ShowDialog()
