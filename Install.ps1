#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    .SYNOPSIS
    Installs UsbDeadman: copies it to Program Files, writes a protected config to
    ProgramData and registers the "UsbDeadman" logon task for every user.

    .DESCRIPTION
    The monitor runs as a scheduled task at logon, in the user's own session.
    That is deliberate: locking a workstation only works from inside the session
    that is being locked, which a SYSTEM service cannot do directly.

    The config folder is writable by administrators only. A deadman switch the
    user can switch off by editing a text file is a suggestion, not a control.

    .PARAMETER Action
    What happens when the trusted device is removed. Default: Lock.

    .PARAMETER NoStart
    Register the task but do not start it now. It starts at the next logon.

    .EXAMPLE
    .\Install.ps1
    .\Enroll.ps1          # optional: pin it to one specific key

    .EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1 -NoStart
    Silent install, e.g. as an Intune Win32 app in system context.
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:ProgramFiles 'UsbDeadman'),
    [ValidateSet('Lock', 'Logoff', 'Hibernate', 'Shutdown')] [string] $Action,
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
$TaskName = 'UsbDeadman'
$ConfigDir = Join-Path $env:ProgramData 'UsbDeadman'
$ConfigPath = Join-Path $ConfigDir 'config.json'

Write-Host "Installing UsbDeadman to $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'src\*') -Destination $InstallDir -Recurse -Force

# Config: keep an existing one (re-install and upgrade must not forget enrolled keys).
New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.example.json') -Destination $ConfigPath
    Write-Host "Config created: $ConfigPath (any YubiKey arms it; run Enroll.ps1 to pin one key)"
}
if ($Action) {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $cfg.Action = $Action
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

# Administrators and SYSTEM write, users only read. Built from SIDs so it also
# works on a Dutch Windows, where "Users" is called "Gebruikers".
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$none = [System.Security.AccessControl.PropagationFlags]::None
foreach ($entry in @(
        @{ Sid = 'S-1-5-18'; Rights = 'FullControl' },       # SYSTEM
        @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' },   # Administrators
        @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' } # Users
    )) {
    $sid = New-Object System.Security.Principal.SecurityIdentifier($entry.Sid)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $entry.Rights, $inherit, $none, 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $ConfigDir -AclObject $acl

# The task. conhost --headless keeps the console window from flashing up at
# every logon (Windows 10 1809 and later).
$script = Join-Path $InstallDir 'UsbDeadman.ps1'
$taskAction = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\conhost.exe') `
    -Argument ('--headless powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $script)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
# Parallel, not IgnoreNew: every signed-in user needs their own copy. The
# monitor itself refuses a second copy inside the same session.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances Parallel -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $taskAction -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description 'UsbDeadman: locks the workstation when the trusted USB key (e.g. a YubiKey) is removed.' | Out-Null
Write-Host "Scheduled task '$TaskName' registered (at logon, every user)."

if (-not $NoStart) {
    try {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host 'Started for the current session.'
    }
    catch {
        Write-Warning "Could not start it now ($($_.Exception.Message)). It starts at the next logon."
    }
}

Write-Host "Done. Log: %LOCALAPPDATA%\UsbDeadman\UsbDeadman.log"
