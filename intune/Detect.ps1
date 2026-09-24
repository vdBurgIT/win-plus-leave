# Intune Win32 app detection: installed when the task exists and the monitor is
# in place. Intune treats any STDOUT output with exit code 0 as "detected".
$task = Get-ScheduledTask -TaskName 'WinPlusLeave' -ErrorAction SilentlyContinue
$script = Join-Path $env:ProgramFiles 'WinPlusLeave\WinPlusLeave.ps1'
if ($task -and (Test-Path -LiteralPath $script)) {
    Write-Output 'WinPlusLeave installed'
    exit 0
}
exit 1
