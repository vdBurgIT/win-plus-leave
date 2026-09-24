#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    .SYNOPSIS
    Removes UsbDeadman: stops every running monitor, unregisters the task and
    deletes the program folder. The config (with enrolled keys) stays unless
    -RemoveConfig is given, so a reinstall picks up where it left off.
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:ProgramFiles 'UsbDeadman'),
    [switch] $RemoveConfig
)

$ErrorActionPreference = 'Stop'
$TaskName = 'UsbDeadman'

Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\UsbDeadman.ps1*' } |
    ForEach-Object {
        Write-Host "Stopping monitor (PID $($_.ProcessId))"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed."
}

if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "Removed $InstallDir"
}

if ($RemoveConfig) {
    $configDir = Join-Path $env:ProgramData 'UsbDeadman'
    if (Test-Path -LiteralPath $configDir) {
        Remove-Item -LiteralPath $configDir -Recurse -Force
        Write-Host "Removed $configDir"
    }
}
