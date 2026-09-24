#Requires -Version 5.1
<#
    .SYNOPSIS
    UsbDeadman monitor. Started by the "UsbDeadman" scheduled task at logon, in
    the user's own session, and runs until sign-out.

    .PARAMETER ConfigPath
    Machine-wide config written by Install.ps1 / Enroll.ps1.

    .EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File UsbDeadman.ps1 -Verbose
    Runs in the foreground, handy to watch it arm and fire while testing.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $env:ProgramData 'UsbDeadman\config.json')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsbDeadman\UsbDeadman.psm1') -Force

# One monitor per session. A second copy (a double logon trigger, a manual
# start on top of the task) would lock twice and log everything double.
$mutex = New-Object System.Threading.Mutex($false, 'Local\UsbDeadman')
if (-not $mutex.WaitOne(0)) {
    Write-Verbose 'UsbDeadman is already running in this session.'
    exit 0
}

try {
    $config = Get-UdConfig -Path $ConfigPath
    Write-Verbose ("Action: {0}; rules: {1}" -f $config.Action, (($config.Devices | ForEach-Object { "$($_.VendorId):$($_.ProductId):$($_.Serial)" }) -join ', '))
    Start-UdMonitor -Config $config
}
catch {
    $fallbackLog = Join-Path $env:LOCALAPPDATA 'UsbDeadman\UsbDeadman.log'
    Write-UdLog -Message "fatal: $($_.Exception.Message)" -Path $fallbackLog
    throw
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
