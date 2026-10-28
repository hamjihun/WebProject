# Installs clean-temp.ps1 to C:\Scripts\TempCleaner and registers a scheduled task
# that runs it once a week on the given day and time.
param(
    [string]$DayOfWeek = 'Wednesday',
    [string]$At = '11:50',
    [int]$MinAgeHours = 0,
    [string]$TargetUser = "$env:USERDOMAIN\$env:USERNAME"
)

$ErrorActionPreference = 'Stop'

# Re-launch elevated (keeping the original user as the task owner)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-DayOfWeek', $DayOfWeek, '-At', $At, '-MinAgeHours', $MinAgeHours, '-TargetUser', "`"$TargetUser`"")
    exit
}

$installDir = 'C:\Scripts\TempCleaner'
$taskName = 'TempCleaner'

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'clean-temp.ps1') $installDir -Force

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass " +
    "-File `"$installDir\clean-temp.ps1`" -MinAgeHours $MinAgeHours")

$weekly = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $DayOfWeek -At $At

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $weekly `
    -Settings $settings -Principal $principal -Force | Out-Null

Write-Host "Installed. Task '$taskName' runs every $DayOfWeek at $At for $TargetUser."
Write-Host "Running once now..."
Start-ScheduledTask -TaskName $taskName
Write-Host "Log: $installDir\cleanup.log"
Read-Host 'Press Enter to close'
