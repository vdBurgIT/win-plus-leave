#Requires -Version 5.1
<#
    UsbDeadman: lock the workstation the moment your key walks away.

    The module is split in two on purpose. The top half is pure logic (config,
    device matching, the arm/fire state machine) and runs anywhere, so it can be
    tested without a Windows box and without unplugging anything. The bottom
    half touches Windows (CIM, user32, scheduled task context) and is kept thin.
#>

Set-StrictMode -Version Latest

$script:ValidActions = @('Lock', 'Logoff', 'Hibernate', 'Shutdown', 'None')
$script:YubicoVendorId = '1050'

#region Config ------------------------------------------------------------------

function Get-UdDefaultConfig {
    <#
        .SYNOPSIS
        The configuration used when a setting is missing from config.json.
        The default device rule is "any YubiKey": vendor 1050, any product,
        any serial. Enroll.ps1 narrows it down to one specific key.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        Devices              = @([pscustomobject]@{ Name = 'Any YubiKey'; VendorId = $script:YubicoVendorId; ProductId = '*'; Serial = '*' })
        Action               = 'Lock'
        DebounceMilliseconds = 750
        PollSeconds          = 5
        LockIfMissingAtStart = $false
        LogPath              = '%LOCALAPPDATA%\UsbDeadman\UsbDeadman.log'
        LogMaxKB             = 1024
    }
}

function Get-UdConfig {
    <#
        .SYNOPSIS
        Reads config.json and fills anything missing from the defaults.
        An unknown Action or an empty device list is an error, not a silent
        fallback: a deadman switch that quietly does nothing is worse than one
        that refuses to start.
    #>
    [CmdletBinding()]
    param(
        [string] $Path
    )
    $config = Get-UdDefaultConfig
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($prop in $json.PSObject.Properties) {
            if ($config.PSObject.Properties.Name -contains $prop.Name) {
                $config.($prop.Name) = $prop.Value
            }
        }
    }

    if ($script:ValidActions -notcontains [string]$config.Action) {
        throw "Invalid Action '$($config.Action)'. Use one of: $($script:ValidActions -join ', ')."
    }
    $devices = @($config.Devices | Where-Object { $_ })
    if ($devices.Count -eq 0) {
        throw 'No devices configured. Run Enroll.ps1 or add a rule to Devices in config.json.'
    }
    foreach ($d in $devices) {
        foreach ($field in 'VendorId', 'ProductId', 'Serial') {
            if (-not ($d.PSObject.Properties.Name -contains $field) -or [string]::IsNullOrWhiteSpace([string]$d.$field)) {
                $d | Add-Member -NotePropertyName $field -NotePropertyValue '*' -Force
            }
        }
        if (-not ($d.PSObject.Properties.Name -contains 'Name')) {
            $d | Add-Member -NotePropertyName Name -NotePropertyValue "USB $($d.VendorId):$($d.ProductId)" -Force
        }
    }
    $config.Devices = $devices
    $config.DebounceMilliseconds = [int][math]::Max(0, [int]$config.DebounceMilliseconds)
    $config.PollSeconds = [int][math]::Max(1, [int]$config.PollSeconds)
    $config.LogMaxKB = [int][math]::Max(64, [int]$config.LogMaxKB)
    $config.LogPath = [Environment]::ExpandEnvironmentVariables([string]$config.LogPath)
    $config
}

#endregion

#region Device matching ---------------------------------------------------------

function ConvertFrom-UdInstanceId {
    <#
        .SYNOPSIS
        Splits a USB device instance id into vendor, product and the last part.
        USB\VID_1050&PID_0407\0012345678  -> 1050, 0407, 0012345678 (a serial)
        USB\VID_1050&PID_0407\5&2A1B&0&2  -> 1050, 0407, 5&2A1B&0&2 (a port location)
        Returns $null for anything that is not a top-level USB device.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $InstanceId
    )
    $m = [regex]::Match($InstanceId, '^USB\\VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})\\([^\\]+)$')
    if (-not $m.Success) { return $null }
    $last = $m.Groups[3].Value
    [pscustomobject]@{
        VendorId  = $m.Groups[1].Value.ToUpperInvariant()
        ProductId = $m.Groups[2].Value.ToUpperInvariant()
        Last      = $last
        # Windows writes a port location (with '&') when the device reports no
        # USB serial. A location changes with the port, so it is not an identity.
        HasSerial = ($last -notmatch '&')
    }
}

function Test-UdDeviceMatch {
    <#
        .SYNOPSIS
        Does this device instance id satisfy this rule? Wildcards (* and ?) are
        allowed in VendorId, ProductId and Serial; matching is case-insensitive.
        A rule with a specific Serial never matches a device that only reports a
        port location.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $InstanceId,
        [Parameter(Mandatory)] $Rule
    )
    $id = ConvertFrom-UdInstanceId -InstanceId $InstanceId
    if (-not $id) { return $false }
    if ($id.VendorId -notlike ([string]$Rule.VendorId)) { return $false }
    if ($id.ProductId -notlike ([string]$Rule.ProductId)) { return $false }
    $serial = [string]$Rule.Serial
    if ($serial -eq '*' -or $serial -eq '') { return $true }
    if (-not $id.HasSerial) { return $false }
    return ($id.Last -like $serial)
}

function Find-UdTrustedDevice {
    <#
        .SYNOPSIS
        Returns the present devices that match any configured rule.
        -Devices takes objects with an InstanceId (and optionally a Name).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Devices,
        [Parameter(Mandatory)] [object[]] $Rules
    )
    foreach ($dev in $Devices) {
        foreach ($rule in $Rules) {
            if (Test-UdDeviceMatch -InstanceId ([string]$dev.InstanceId) -Rule $rule) {
                $dev
                break
            }
        }
    }
}

function New-UdRuleFromInstanceId {
    <#
        .SYNOPSIS
        Builds the tightest reliable rule for a device: vendor and product always,
        the serial only when the device actually reports one.
    #>
    # Builds an object, changes nothing: ShouldProcess would only add noise.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $InstanceId,
        [string] $Name
    )
    $id = ConvertFrom-UdInstanceId -InstanceId $InstanceId
    if (-not $id) { throw "Not a top-level USB device: $InstanceId" }
    if (-not $Name) { $Name = "USB $($id.VendorId):$($id.ProductId)" }
    $serial = '*'
    if ($id.HasSerial) { $serial = $id.Last }
    [pscustomobject]@{ Name = $Name; VendorId = $id.VendorId; ProductId = $id.ProductId; Serial = $serial }
}

#endregion

#region State machine -----------------------------------------------------------

function Get-UdNextStep {
    <#
        .SYNOPSIS
        One tick of the deadman switch. Pure: given the state and whether a
        trusted device is present, returns the next state and whether to fire.

        Disarmed + present  -> Armed           (key inserted: now we watch it)
        Armed    + absent   -> Disarmed + Fire (key pulled: lock, once)
        anything else       -> unchanged

        Firing disarms, so a pulled key locks once instead of every tick, and the
        switch re-arms by itself when the key comes back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Disarmed', 'Armed')] [string] $State,
        [Parameter(Mandatory)] [bool] $Present
    )
    if ($State -eq 'Disarmed' -and $Present) { return [pscustomobject]@{ State = 'Armed'; Fire = $false; Changed = $true } }
    if ($State -eq 'Armed' -and -not $Present) { return [pscustomobject]@{ State = 'Disarmed'; Fire = $true; Changed = $true } }
    [pscustomobject]@{ State = $State; Fire = $false; Changed = $false }
}

#endregion

#region Logging -----------------------------------------------------------------

function Write-UdLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [string] $Path,
        [int] $MaxKB = 1024
    )
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt ($MaxKB * 1KB))) {
            Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
        }
        $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
    catch {
        # A log that cannot be written must never stop the switch itself.
        Write-Verbose "log write failed: $($_.Exception.Message)"
    }
}

#endregion

#region Windows ---------------------------------------------------------------

function Get-UdPresentUsbDevice {
    <#
        .SYNOPSIS
        Top-level USB devices currently present, as InstanceId + Name.
        CIM rather than Get-PnpDevice: it is several times faster, which matters
        for a check that runs on every device event.
    #>
    [CmdletBinding()]
    param()
    # WQL escapes a literal backslash as \\ (PowerShell leaves both characters alone).
    Get-CimInstance -ClassName Win32_PnPEntity -Filter "DeviceID LIKE 'USB\\VID_%'" -ErrorAction Stop |
        Where-Object { $_.DeviceID -notmatch '&MI_' } |
        ForEach-Object { [pscustomobject]@{ InstanceId = $_.DeviceID; Name = $_.Name } }
}

function Invoke-UdAction {
    <#
        .SYNOPSIS
        Carries out the configured action in the current user's session.
        Lock needs to run inside that session, which is why UsbDeadman runs as a
        logon task in user context and not as a SYSTEM service.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidateSet('Lock', 'Logoff', 'Hibernate', 'Shutdown', 'None')] [string] $Action
    )
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, $Action)) { return }
    switch ($Action) {
        'Lock' {
            if (-not ('UsbDeadman.NativeMethods' -as [type])) {
                Add-Type -Namespace UsbDeadman -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool LockWorkStation();
'@
            }
            if (-not [UsbDeadman.NativeMethods]::LockWorkStation()) {
                # Fallback for the odd environment where the P/Invoke is blocked.
                Start-Process -FilePath "$env:WINDIR\System32\rundll32.exe" -ArgumentList 'user32.dll,LockWorkStation' -WindowStyle Hidden
            }
        }
        'Logoff' { Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList '/l' -WindowStyle Hidden }
        'Hibernate' { Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList '/h' -WindowStyle Hidden }
        'Shutdown' { Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList '/s', '/f', '/t', '0' -WindowStyle Hidden }
        'None' { }
    }
}

function Start-UdMonitor {
    <#
        .SYNOPSIS
        The main loop. Listens for USB arrival and removal events, re-checks the
        trusted devices on every event and on a slow poll (the safety net for a
        missed event), and fires the action when the armed key disappears.
    #>
    # A monitor loop, not a one-off change; -WhatIf belongs on Invoke-UdAction.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config
    )
    $log = { param($m) Write-UdLog -Message $m -Path $Config.LogPath -MaxKB $Config.LogMaxKB }
    $sourceId = 'UsbDeadman.DeviceChange'
    $isPresent = {
        $found = @(Find-UdTrustedDevice -Devices @(Get-UdPresentUsbDevice) -Rules $Config.Devices)
        [pscustomobject]@{ Present = ($found.Count -gt 0); Devices = $found }
    }

    $first = & $isPresent
    $state = 'Disarmed'
    if ($first.Present) {
        $state = 'Armed'
        & $log ("started, armed on: " + (($first.Devices | ForEach-Object { $_.Name }) -join ', '))
    }
    elseif ($Config.LockIfMissingAtStart) {
        & $log 'started without a trusted device and LockIfMissingAtStart is set: firing'
        Invoke-UdAction -Action $Config.Action
    }
    else {
        & $log 'started, disarmed: waiting for a trusted device'
    }

    # EventType 2 = arrival, 3 = removal. Both matter: arrival re-arms.
    Register-CimIndicationEvent -Query 'SELECT * FROM Win32_DeviceChangeEvent WHERE EventType = 2 OR EventType = 3' -SourceIdentifier $sourceId | Out-Null
    try {
        while ($true) {
            $evt = Wait-Event -SourceIdentifier $sourceId -Timeout $Config.PollSeconds
            if ($evt) {
                # Windows raises a burst of events per device; drain them so one
                # insertion is one check.
                Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Remove-Event
            }
            $now = & $isPresent
            if ($state -eq 'Armed' -and -not $now.Present -and $Config.DebounceMilliseconds -gt 0) {
                # A USB hub hiccup or a key re-enumerating after a touch can look
                # like a removal for a few hundred milliseconds. Look twice.
                Start-Sleep -Milliseconds $Config.DebounceMilliseconds
                $now = & $isPresent
            }
            $step = Get-UdNextStep -State $state -Present $now.Present
            if ($step.Changed) {
                if ($step.Fire) {
                    & $log "trusted device removed: $($Config.Action)"
                    try { Invoke-UdAction -Action $Config.Action }
                    catch { & $log "action failed: $($_.Exception.Message)" }
                }
                else {
                    & $log ("armed on: " + (($now.Devices | ForEach-Object { $_.Name }) -join ', '))
                }
                $state = $step.State
            }
        }
    }
    finally {
        Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
        & $log 'stopped'
    }
}

#endregion

Export-ModuleMember -Function Get-UdDefaultConfig, Get-UdConfig, ConvertFrom-UdInstanceId, Test-UdDeviceMatch,
    Find-UdTrustedDevice, New-UdRuleFromInstanceId, Get-UdNextStep, Write-UdLog, Get-UdPresentUsbDevice,
    Invoke-UdAction, Start-UdMonitor
