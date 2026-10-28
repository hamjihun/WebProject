# Removes the TempCleaner scheduled task and its install folder.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit
}

Unregister-ScheduledTask -TaskName 'TempCleaner' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\TempCleaner' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'TempCleaner removed.'
Read-Host 'Press Enter to close'
