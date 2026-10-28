# Permanently deletes everything inside the current user's %TEMP% folder.
# Files locked by running programs are skipped and retried on the next run.
param(
    # Only delete items older than this many hours (0 = delete everything)
    [int]$MinAgeHours = 0
)

$ErrorActionPreference = 'SilentlyContinue'
# Never ask "Are you sure?" - always delete without confirmation
$ConfirmPreference = 'None'

$temp = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
$logFile = Join-Path $PSScriptRoot 'cleanup.log'

# Safety guard: never run against a drive root or a non-Temp folder
if ((Split-Path $temp -Leaf) -ne 'Temp' -or $temp.Length -le 3) {
    Add-Content $logFile "$(Get-Date -Format s) ABORT: unexpected TEMP path '$temp'"
    exit 1
}

$cutoff = (Get-Date).AddHours(-$MinAgeHours)
$before = (Get-ChildItem $temp -Recurse -Force -File | Measure-Object Length -Sum).Sum

Get-ChildItem $temp -Force | Where-Object { $_.LastWriteTime -le $cutoff } | ForEach-Object {
    # Remove-Item deletes permanently (does not go to the Recycle Bin)
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -Confirm:$false
    # Fallback for items Remove-Item cannot handle (long paths, read-only trees); /q = quiet, no prompt
    if (Test-Path -LiteralPath $_.FullName) {
        if ($_.PSIsContainer) { cmd /c rd /s /q "`"$($_.FullName)`"" 2>$null }
        else { cmd /c del /f /q /a "`"$($_.FullName)`"" 2>$null }
    }
}

$after = (Get-ChildItem $temp -Recurse -Force -File | Measure-Object Length -Sum).Sum
$freedMB = [math]::Round(($before - $after) / 1MB, 1)
$left = (Get-ChildItem $temp -Force | Measure-Object).Count
Add-Content $logFile "$(Get-Date -Format s) path=$temp freed=${freedMB}MB remaining_items=$left"

# Keep the log small
$lines = Get-Content $logFile
if ($lines.Count -gt 500) { $lines | Select-Object -Last 500 | Set-Content $logFile }
