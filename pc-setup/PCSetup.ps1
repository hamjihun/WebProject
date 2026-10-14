#Requires -Version 5.1
<#
    사내 PC 자동 셋팅 도구
    - Setup.bat 으로 실행하세요. (관리자 권한 자동 요청)
    - 설치할 프로그램, 프린터, 각종 설정 값은 config.json 에서 관리합니다.
    - 설치파일은 USB(이름: 프로그램USB)의 【 Application 】 폴더에서 자동으로 찾습니다.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
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
    function Find-Installer([string]$AppRoot, $Files, $P) {
        if ($P.path) {
            $full = $P.path
            if (-not [IO.Path]::IsPathRooted($full) -and $AppRoot) { $full = Join-Path $AppRoot $full }
            if (Test-Path -LiteralPath $full) { return $full }
        }
        if (-not $AppRoot) { return $null }
        foreach ($pattern in @($P.find)) {
            if (-not $pattern) { continue }
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

    . ([scriptblock]::Create($Plan.CommonCode))

    $Cfg     = $Plan.Config
    $AppRoot = $Plan.AppRoot
    $State   = @{ Step = 0; RestartExplorer = $false }
    $IsWin11 = [Environment]::OSVersion.Version.Build -ge 22000

    function Write-Log([string]$Message, [string]$Level = 'INFO') {
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
        $Sync.Queue.Enqueue($line)
        Add-Content -LiteralPath $Plan.LogFile -Value $line -Encoding UTF8
    }

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

    # 설치파일 실행. 설치 프로그램이 띄운 다른 프로그램(카톡 실행 등)은 기다리지 않음
    function Start-Installer([string]$Path, [string]$Arguments) {
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
        $proc.WaitForExit()
        return $proc.ExitCode
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

    # --- 2. 프로그램 설치 ------------------------------------------------------
    function Install-Programs {
        $list = @($Plan.Programs)
        if ($list.Count -eq 0) { Write-Log '선택된 프로그램이 없습니다.'; return }
        $files = Get-AppFiles $AppRoot

        for ($i = 0; $i -lt $list.Count; $i++) {
            $p = $list[$i]
            Set-StepProgress $i $list.Count
            Set-Status "프로그램 설치 중 ($($i + 1)/$($list.Count)): $($p.name)"
            try {
                if (Test-Installed $p) { Write-Log "$($p.name): 이미 설치되어 있어 건너뜀" 'OK'; continue }

                if ($p.winget) {
                    Write-Log "$($p.name): 설치 시작 (winget: $($p.winget))"
                    & winget.exe install --id $p.winget -e --silent --accept-package-agreements --accept-source-agreements *> $null
                    $code = $LASTEXITCODE
                }
                else {
                    $path = Find-Installer $AppRoot $files $p
                    if (-not $path) { throw '설치파일을 찾지 못했습니다. 화면에서 [설치파일 지정] 으로 선택하세요.' }
                    if ($p.args) { Write-Log "$($p.name): 자동 설치 시작 ($path)" }
                    else {
                        Write-Log "$($p.name): 설치 화면이 뜨면 직접 진행해 주세요. ($path)"
                        Set-Status "$($p.name): 설치 화면에서 직접 진행해 주세요 (끝나면 자동으로 다음 단계)"
                    }
                    $code = Start-Installer $path $p.args
                }

                if ($code -eq 0) { Write-Log "$($p.name): 설치 완료" 'OK' }
                elseif ($code -eq 3010 -or $code -eq 1641) {
                    Write-Log "$($p.name): 설치 완료 (재부팅 필요)" 'OK'
                    $Sync.RebootRequired = $true
                }
                else { Write-Log "$($p.name): 설치 종료 코드 $code (실패했을 수 있으니 확인하세요)" 'ERROR' }
            }
            catch { Write-Log "$($p.name): $($_.Exception.Message)" 'ERROR' }
        }
    }

    # --- 3. 폰트 --------------------------------------------------------------
    function Install-Fonts {
        $f = $Cfg.fonts
        $folder = Resolve-AppDir $AppRoot $f.folder $f.search
        if (-not $folder) { throw "폰트 폴더를 찾지 못했습니다: $($f.folder)" }

        Add-Type -AssemblyName System.Drawing
        if (-not ('PCSetup.FontApi' -as [type])) {
            Add-Type -Namespace PCSetup -Name FontApi -MemberDefinition '[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResource(string file);'
        }

        $fontsDir = Join-Path $env:windir 'Fonts'
        $regPath  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        $used = @{}
        $fonts = @(Get-ChildItem -LiteralPath $folder -Recurse -File | Where-Object { $_.Extension -in '.ttf', '.otf' })
        if ($fonts.Count -eq 0) { throw "폰트 파일(.ttf)이 없습니다: $folder" }

        foreach ($font in $fonts) {
            try {
                $dest = Join-Path $fontsDir $font.Name
                if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $font.FullName -Destination $dest -Force -ErrorAction Stop }

                $pfc = New-Object System.Drawing.Text.PrivateFontCollection
                $pfc.AddFontFile($font.FullName)
                $family = $pfc.Families[0].Name
                $pfc.Dispose()

                $type = if ($font.Extension -eq '.otf') { 'OpenType' } else { 'TrueType' }
                $regName = "$family ($type)"
                if ($used.ContainsKey($regName)) { $regName = "$($font.BaseName) ($type)" }
                $used[$regName] = $true

                Set-ItemProperty -Path $regPath -Name $regName -Value $font.Name -ErrorAction Stop
                [void][PCSetup.FontApi]::AddFontResource($dest)
                Write-Log "폰트 설치: $($font.Name)" 'OK'
            }
            catch { Write-Log "폰트 설치 실패: $($font.Name) - $($_.Exception.Message)" 'ERROR' }
        }
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
        $State.RestartExplorer = $true
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
        Write-Log '엣지를 다시 열면 적용됩니다.'
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
        Write-Log '크롬을 다시 열면 적용됩니다.'
    }

    function Wait-Process2($Proc, [int]$Seconds) {
        if (-not $Proc.WaitForExit($Seconds * 1000)) { Write-Log '업데이트가 오래 걸려 기다리지 않고 다음으로 넘어갑니다. (백그라운드에서 계속 진행)' 'WARN' }
    }

    function Update-Browsers {
        Set-Status '엣지 최신 버전으로 업데이트 중...'
        $edgeUpd = "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe"
        if (Test-Path -LiteralPath $edgeUpd) {
            Wait-Process2 (Start-Process $edgeUpd -ArgumentList '/ua /installsource scheduler' -PassThru) 600
            Write-Log '엣지 업데이트 확인 완료' 'OK'
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
    function Invoke-WindowsUpdate([string]$Criteria, [string]$Label) {
        Set-Status "$Label 검색 중... (몇 분 걸릴 수 있습니다)"
        Write-Log "$Label 검색 시작"
        try {
            $session  = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $result   = $searcher.Search($Criteria)
        }
        catch { Write-Log "${Label} 검색 실패: $($_.Exception.Message)" 'ERROR'; return }

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
                if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) { Write-Log "설치 완료: $($u.Title)" 'OK' }
                else { Write-Log "설치 실패 (결과 코드 $($r.ResultCode)): $($u.Title)" 'ERROR' }
                if ($r.RebootRequired) { $Sync.RebootRequired = $true }
            }
            catch { Write-Log "설치 오류: $($u.Title) - $($_.Exception.Message)" 'ERROR' }
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

        if ($d.windowsUpdate) { Invoke-WindowsUpdate "IsInstalled=0 and IsHidden=0 and Type='Driver'" '드라이버 업데이트' }
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
        $folder = Resolve-AppDir $AppRoot $dc.folder $dc.search
        if (-not $folder) { throw "문서중앙화 폴더를 찾지 못했습니다: $($dc.folder)" }

        $path = $null
        if ($dc.file) { $path = Join-Path $folder $dc.file }
        else {
            $files = @(Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.Extension -in '.exe', '.msi' -and $_.Name -notmatch '^unins' })
            $preferred = @($files | Where-Object { $_.Name -match 'setup|install|설치' })
            if ($preferred.Count) { $files = $preferred }
            $path = ($files | Sort-Object { $_.FullName.Length } | Select-Object -First 1).FullName
        }
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw "문서중앙화 설치파일을 찾지 못했습니다: $folder" }

        Write-Log "문서중앙화 설치 시작: $path (설치 화면에서 직접 진행, 재부팅이 여러 번 될 수 있습니다)"
        Set-Status '문서중앙화: 설치 화면에서 직접 진행해 주세요 (재부팅이 여러 번 될 수 있습니다)'
        $code = Start-Installer $path $dc.args
        Write-Log "문서중앙화 설치 프로그램 종료 (코드 $code)" 'OK'
        Add-Notice '문서중앙화: 설치 중 재부팅이 요청되면 그대로 진행하세요.'
    }

    # --- 실행 ----------------------------------------------------------------
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Write-Log "셋팅 시작 - PC: $env:COMPUTERNAME / 사용자: $env:USERNAME / $($os.Caption) (빌드 $($os.BuildNumber))"
        Write-Log "USB 폴더: $AppRoot"
        $Sync.StepCount = [Math]::Max(1, $Plan.Steps.Count)

        for ($s = 0; $s -lt $Plan.Steps.Count; $s++) {
            $State.Step = $s
            Set-StepProgress 0 1
            $step = $Plan.Steps[$s]
            if ($step.Id -eq 'docCentral') { Restart-Explorer }
            Write-Log "===== $($step.Title) ====="
            Set-Status $step.Title
            try {
                switch ($step.Id) {
                    'network'     { Set-Network }
                    'programs'    { Install-Programs }
                    'fonts'       { Install-Fonts }
                    'taskbar'     { Set-Taskbar }
                    'desktop'     { Set-DesktopIcons }
                    'officeLinks' { New-OfficeShortcuts }
                    'misc'        { Set-Misc }
                    'power'       { Set-Power }
                    'startmenu'   { Set-StartMenu }
                    'edge'        { Set-EdgeSettings }
                    'chrome'      { Set-ChromeSettings }
                    'extensions'  { Install-BrowserExtensions }
                    'printer'     { Install-Printers }
                    'drivers'     { Install-Drivers }
                    'update'      { Invoke-WindowsUpdate "IsInstalled=0 and IsHidden=0 and Type='Software'" '윈도우 업데이트' }
                    'activation'  { Test-Activation }
                    'docCentral'  { Install-DocCentral }
                }
            }
            catch { Write-Log "$($step.Title) 중 오류: $($_.Exception.Message)" 'ERROR' }
        }

        Restart-Explorer
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

# 실행 순서대로 (오래 걸리는 업데이트와 재부팅되는 문서중앙화는 마지막)
$TaskDefs = @(
    @{ Id = 'network';     Title = '이더넷 IP 설정';                    Default = $true },
    @{ Id = 'programs';    Title = '프로그램 설치 (USB)';               Default = $true },
    @{ Id = 'fonts';       Title = '폰트 설치 (LG스마트체)';            Default = $true },
    @{ Id = 'taskbar';     Title = '작업표시줄 (뉴스 끄기, 검색 아이콘)'; Default = $true },
    @{ Id = 'desktop';     Title = '바탕화면 아이콘 표시';              Default = $true },
    @{ Id = 'officeLinks'; Title = '엑셀·파워포인트·워드 바로가기';      Default = $true },
    @{ Id = 'misc';        Title = '파일 확장명 표시 / PC 이름';        Default = $true },
    @{ Id = 'power';       Title = '전원 설정';                         Default = $true },
    @{ Id = 'startmenu';   Title = '시작화면 정리 (엣지만)';            Default = $true },
    @{ Id = 'edge';        Title = '엣지 설정';                         Default = $true },
    @{ Id = 'chrome';      Title = '크롬 설정';                         Default = $true },
    @{ Id = 'extensions';  Title = '크롬·엣지 업데이트 + ClouDoc 확장';  Default = $true },
    @{ Id = 'printer';     Title = '프린터 설치';                       Default = $true },
    @{ Id = 'drivers';     Title = '드라이버 확인 및 설치';             Default = $false },
    @{ Id = 'update';      Title = '윈도우 업데이트';                   Default = $false },
    @{ Id = 'activation';  Title = '정품 인증 확인';                    Default = $true },
    @{ Id = 'docCentral';  Title = '문서중앙화 설치 (재부팅 여러 번)';   Default = $true }
)

# --- 왼쪽: 작업 선택 ---
$grpTasks = New-Group '1. 실행할 작업 (위에서부터 순서대로)' 12 8 330 340
$clbTasks = New-Control 'CheckedListBox' '' 10 22 310 308
$clbTasks.CheckOnClick = $true
foreach ($t in $TaskDefs) { [void]$clbTasks.Items.Add($t.Title, $t.Default) }
$grpTasks.Controls.Add($clbTasks)

$btnConfig    = New-Control 'Button' '설정 파일 열기' 12 356 160 30
$btnReload    = New-Control 'Button' '설정 다시 불러오기' 182 356 160 30
$btnLogs      = New-Control 'Button' '로그 폴더 열기' 12 390 160 30
$btnDump      = New-Control 'Button' 'USB 폴더 목록 저장' 182 390 160 30
$btnSaveStart = New-Control 'Button' '시작화면 저장 (Win11)' 12 424 160 30
$form.Controls.AddRange(@($btnConfig, $btnReload, $btnLogs, $btnDump, $btnSaveStart))

# --- 가운데: 네트워크 / 프린터 / PC 이름 / 정품 인증 ---
$grpNet = New-Group '2. 이더넷 IP (수동 입력)' 354 8 400 214
$rows = @('어댑터', 'IP', '서브넷 마스크', '게이트웨이', 'DNS 1', 'DNS 2')
for ($i = 0; $i -lt $rows.Count; $i++) {
    $grpNet.Controls.Add((New-Control 'Label' $rows[$i] 12 (25 + $i * 30) 90 20))
}
$cmbAdapter = New-Control 'ComboBox' '' 104 22 286 24
$cmbAdapter.DropDownStyle = 'DropDownList'
$txtIp      = New-Control 'TextBox' $Config.network.ip 104 52 160 24
$txtSubnet  = New-Control 'TextBox' $Config.network.subnet 104 82 160 24
$txtGateway = New-Control 'TextBox' '192.168.0.1' 104 112 160 24
$txtDns1    = New-Control 'TextBox' $Config.network.dns1 104 142 160 24
$txtDns2    = New-Control 'TextBox' $Config.network.dns2 104 172 160 24
$lblGwHint  = New-Control 'Label' 'IP 입력 시 자동 변경' 270 115 125 20
$lblGwHint.ForeColor = $Gray
$grpNet.Controls.AddRange(@($cmbAdapter, $txtIp, $txtSubnet, $txtGateway, $txtDns1, $txtDns2, $lblGwHint))

$grpPrinter = New-Group '3. 설치할 프린터' 354 228 400 112
$clbPrinters = New-Control 'CheckedListBox' '' 10 22 380 80
$clbPrinters.CheckOnClick = $true
$grpPrinter.Controls.Add($clbPrinters)

$grpName = New-Group 'PC 이름 변경 (선택)' 354 346 400 56
$txtName = New-Control 'TextBox' '' 10 22 150 24
$txtName.MaxLength = 15
$lblName = New-Control 'Label' "현재: $env:COMPUTERNAME  (비워두면 변경 안 함)" 168 25 225 20
$lblName.ForeColor = $Gray
$grpName.Controls.AddRange(@($txtName, $lblName))

$grpAct = New-Group 'Windows 정품 인증' 354 408 400 50
$lblAct = New-Control 'Label' '확인 중...' 10 22 270 22
$btnAct = New-Control 'Button' '정품 인증 설정' 284 17 108 27
$grpAct.Controls.AddRange(@($lblAct, $btnAct))

# --- 오른쪽: USB / 프로그램 ---
$grpUsb = New-Group '4. USB 설치파일 폴더' 766 8 402 84
$txtUsb = New-Control 'TextBox' '' 10 22 300 24
$txtUsb.ReadOnly = $true
$btnUsb = New-Control 'Button' '찾아보기' 316 21 76 26
$lblUsb = New-Control 'Label' '' 10 54 382 20
$grpUsb.Controls.AddRange(@($txtUsb, $btnUsb, $lblUsb))

$grpApps = New-Group '5. 설치할 프로그램' 766 98 402 360
$clbPrograms = New-Control 'CheckedListBox' '' 10 22 382 290
$clbPrograms.CheckOnClick = $true
$clbPrograms.HorizontalScrollbar = $true
$btnPick   = New-Control 'Button' '설치파일 지정' 10 320 100 30
$btnRescan = New-Control 'Button' '다시 찾기' 116 320 80 30
$btnAdd    = New-Control 'Button' '+ 추가' 232 320 76 30
$btnRemove = New-Control 'Button' '삭제' 314 320 78 30
$grpApps.Controls.AddRange(@($clbPrograms, $btnPick, $btnRescan, $btnAdd, $btnRemove))

# --- 아래: 진행 상황 ---
$lblStatus = New-Control 'Label' '대기 중' 12 466 1156 22
$lblStatus.Font = $BoldFont
$progress = New-Control 'ProgressBar' '' 12 490 1156 20
$txtLog = New-Control 'TextBox' '' 12 516 1156 190
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$btnStart = New-Control 'Button' '셋팅 시작' 1018 714 150 36
$btnStart.Font = $BoldFont
$form.Controls.AddRange(@($lblStatus, $progress, $txtLog, $btnStart))

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
        if ($p.winget) { $where = "winget: $($p.winget)" }
        else {
            $path = Find-Installer $script:AppRoot $script:AppFiles $p
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

$script:Running = $false
$controlsToLock = @($grpTasks, $grpNet, $grpPrinter, $grpName, $grpUsb, $grpApps, $btnStart, $btnConfig, $btnReload, $btnSaveStart)

$btnStart.Add_Click({
    $steps = @(for ($i = 0; $i -lt $TaskDefs.Count; $i++) { if ($clbTasks.GetItemChecked($i)) { $TaskDefs[$i] } })
    if ($steps.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('실행할 작업을 하나 이상 선택하세요.') | Out-Null; return }
    $ids = @($steps | ForEach-Object { $_.Id })

    # 네트워크 입력 확인
    $network = $null
    if ($ids -contains 'network') {
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
            Dns     = @($txtDns1.Text.Trim(), $txtDns2.Text.Trim()) | Where-Object { Test-IPv4 $_ }
        }
    }

    $needUsb = @('programs', 'fonts', 'printer', 'docCentral') | Where-Object { $ids -contains $_ }
    if ($needUsb -and -not $script:AppRoot) {
        [System.Windows.Forms.MessageBox]::Show("USB 설치파일 폴더를 찾지 못했습니다.`n'$($Config.usb.label)' USB 를 꽂고 [다시 찾기] 를 누르거나 [찾아보기] 로 폴더를 선택하세요.") | Out-Null
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

    $summary = ($steps | ForEach-Object { " - $($_.Title)" }) -join "`n"
    $extra = ''
    if ($network) { $extra += "`nIP: $($network.IP) / 게이트웨이: $($network.Gateway)" }
    $extra += "`n프로그램: $($selectedPrograms.Count)개 / 프린터: $(($selectedPrinters | ForEach-Object { $_.name }) -join ', ')"
    $ans = [System.Windows.Forms.MessageBox]::Show("다음 작업을 시작합니다.`n`n$summary`n$extra`n`n진행할까요?", 'PC 셋팅', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $logFile = Join-Path $LogDir ('setup_{0}_{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))

    $plan = @{
        Root         = $Root
        AppRoot      = $script:AppRoot
        Config       = $script:Config
        CommonCode   = $Common.ToString()
        Steps        = $steps
        Network      = $network
        Programs     = $selectedPrograms
        Printers     = $selectedPrinters
        ComputerName = $newName
        LogFile      = $logFile
    }

    $script:Sync = [hashtable]::Synchronized(@{
        Queue          = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Notices        = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
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
    Update-ProgramList
    Update-Activation

    $errors = @($txtLog.Lines | Where-Object { $_ -like '*`[ERROR`]*' }).Count
    $msg = if ($errors -gt 0) { "셋팅이 끝났습니다. 실패한 항목이 $errors 개 있습니다. 로그를 확인하세요." } else { '셋팅이 모두 끝났습니다.' }
    if ($script:Sync.Notices.Count -gt 0) {
        $msg += "`n`n[확인이 필요한 항목]`n" + (($script:Sync.Notices | ForEach-Object { "• $_" }) -join "`n")
    }

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
})

[void]$form.ShowDialog()
