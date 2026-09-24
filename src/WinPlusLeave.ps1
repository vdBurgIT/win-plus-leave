#Requires -Version 5.1
<#
    .SYNOPSIS
    WinPlusLeave monitor. Started by the "WinPlusLeave" scheduled task at logon, in
    the user's own session, and runs until sign-out.

    .PARAMETER ConfigPath
    Machine-wide config written by Install.ps1 / Enroll.ps1.

    .EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File WinPlusLeave.ps1 -Verbose
    Runs in the foreground, handy to watch it arm and fire while testing.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $env:ProgramData 'WinPlusLeave\config.json')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinPlusLeave\WinPlusLeave.psm1') -Force

# One monitor per session. A second copy (a double logon trigger, a manual
# start on top of the task) would lock twice and log everything double.
$mutex = New-Object System.Threading.Mutex($false, 'Local\WinPlusLeave')
if (-not $mutex.WaitOne(0)) {
    Write-Verbose 'WinPlusLeave is already running in this session.'
    exit 0
}

try {
    $config = Get-WplConfig -Path $ConfigPath
    Write-Verbose ("Action: {0}; rules: {1}" -f $config.Action, (($config.Devices | ForEach-Object { "$($_.VendorId):$($_.ProductId):$($_.Serial)" }) -join ', '))
    Start-WplMonitor -Config $config
}
catch {
    $fallbackLog = Join-Path $env:LOCALAPPDATA 'WinPlusLeave\WinPlusLeave.log'
    Write-WplLog -Message "fatal: $($_.Exception.Message)" -Path $fallbackLog
    throw
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
