#Requires -Version 5.1
<#
    WinPlusLeave: lock the workstation the moment your key walks away.

    The module is split in two on purpose. The top half is pure logic (config,
    device matching, the arm/fire state machine) and runs anywhere, so it can be
    tested without a Windows box and without unplugging anything. The bottom
    half touches Windows (CIM, user32, scheduled task context) and is kept thin.
#>

Set-StrictMode -Version Latest

$script:ValidActions = @('Lock', 'Logoff', 'Hibernate', 'Shutdown', 'None')
$script:YubicoVendorId = '1050'

#region Config ------------------------------------------------------------------

function Get-WplDefaultConfig {
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
        ArmDelaySeconds      = 3
        BounceSeconds        = 10
        MaxBouncesPerWindow  = 3
        FlapWindowMinutes    = 10
        CooldownMinutes      = 15
        ShowNotifications    = $true
        LogPath              = '%LOCALAPPDATA%\WinPlusLeave\WinPlusLeave.log'
        LogMaxKB             = 1024
    }
}

function Get-WplConfig {
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
    $config = Get-WplDefaultConfig
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
    $config.ArmDelaySeconds = [int][math]::Max(0, [int]$config.ArmDelaySeconds)
    $config.BounceSeconds = [int][math]::Max(1, [int]$config.BounceSeconds)
    $config.MaxBouncesPerWindow = [int][math]::Max(0, [int]$config.MaxBouncesPerWindow)
    $config.FlapWindowMinutes = [int][math]::Max(1, [int]$config.FlapWindowMinutes)
    $config.CooldownMinutes = [int][math]::Max(1, [int]$config.CooldownMinutes)
    $config.ShowNotifications = [bool]$config.ShowNotifications
    $config.LogPath = [Environment]::ExpandEnvironmentVariables([string]$config.LogPath)
    $config
}

#endregion

#region Device matching ---------------------------------------------------------

function ConvertFrom-WplInstanceId {
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

function Test-WplDeviceMatch {
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
    $id = ConvertFrom-WplInstanceId -InstanceId $InstanceId
    if (-not $id) { return $false }
    if ($id.VendorId -notlike ([string]$Rule.VendorId)) { return $false }
    if ($id.ProductId -notlike ([string]$Rule.ProductId)) { return $false }
    $serial = [string]$Rule.Serial
    if ($serial -eq '*' -or $serial -eq '') { return $true }
    if (-not $id.HasSerial) { return $false }
    return ($id.Last -like $serial)
}

function Find-WplTrustedDevice {
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
            if (Test-WplDeviceMatch -InstanceId ([string]$dev.InstanceId) -Rule $rule) {
                $dev
                break
            }
        }
    }
}

function New-WplRuleFromInstanceId {
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
    $id = ConvertFrom-WplInstanceId -InstanceId $InstanceId
    if (-not $id) { throw "Not a top-level USB device: $InstanceId" }
    if (-not $Name) { $Name = "USB $($id.VendorId):$($id.ProductId)" }
    $serial = '*'
    if ($id.HasSerial) { $serial = $id.Last }
    [pscustomobject]@{ Name = $Name; VendorId = $id.VendorId; ProductId = $id.ProductId; Serial = $serial }
}

#endregion

#region State machine -----------------------------------------------------------

function New-WplTickState {
    <#
        .SYNOPSIS
        The switch's memory for one session. It starts disarmed and holds
        nothing from earlier logons: that you had the key in this morning says
        nothing about this afternoon.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param()
    [pscustomobject]@{ State = 'Disarmed'; PresentSince = $null; LastFire = $null; Bounces = @(); SuspendedUntil = $null }
}

function Invoke-WplTick {
    <#
        .SYNOPSIS
        One tick of the deadman switch. Pure: given what it remembers, the time
        and whether a trusted device is present, returns the new memory and
        whether to fire.

        Disarmed + present for ArmDelaySeconds -> Armed
        Armed    + absent                      -> Disarmed, fire once
        MaxBouncesPerWindow bounces             -> Suspended for CooldownMinutes

        The rules that keep a bad day from turning into a lock loop:
        - Firing disarms. Unlocking without the key (it is at home, it broke)
          leaves the switch disarmed; only a key that is back in re-arms it.
        - A key has to be present without a break for ArmDelaySeconds before it
          arms, so a broken key that blinks in and out never arms at all.
        - A BOUNCE is a key that comes back by itself within BounceSeconds of a
          lock. A person pulls the key and plugs it back in after unlocking, well
          after that; a faulty key or a flaky port comes back on its own in a
          second or two. Only bounces count towards a pause, so testing it ten
          times in a row never switches it off. The pause ends by itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Tick,
        [Parameter(Mandatory)] [datetime] $Now,
        [Parameter(Mandatory)] [bool] $Present,
        [Parameter(Mandatory)] $Config
    )
    $wasPresent = [bool]$Tick.PresentSince
    $since = $Tick.PresentSince
    if ($Present) { if (-not $since) { $since = $Now } } else { $since = $null }
    $windowStart = $Now.AddMinutes(-[double]$Config.FlapWindowMinutes)
    $bounces = @($Tick.Bounces | Where-Object { $_ -gt $windowStart })
    $out = [pscustomobject]@{
        State = $Tick.State; PresentSince = $since; LastFire = $Tick.LastFire
        Bounces = $bounces; SuspendedUntil = $Tick.SuspendedUntil; Fire = $false; Event = ''
    }

    # A key that reappears right after a lock, before anyone could have unlocked
    # and plugged it back in, came back on its own.
    if ($Present -and -not $wasPresent -and $Tick.LastFire -and ($Now - $Tick.LastFire).TotalSeconds -le $Config.BounceSeconds) {
        $out.Bounces = @($bounces) + $Now
    }

    switch ($Tick.State) {
        'Suspended' {
            if ($Tick.SuspendedUntil -and $Now -ge $Tick.SuspendedUntil) {
                $out.State = 'Disarmed'; $out.SuspendedUntil = $null; $out.Bounces = @(); $out.Event = 'resumed'
            }
        }
        'Disarmed' {
            if ($Config.MaxBouncesPerWindow -gt 0 -and $out.Bounces.Count -ge $Config.MaxBouncesPerWindow) {
                $out.State = 'Suspended'; $out.SuspendedUntil = $Now.AddMinutes($Config.CooldownMinutes); $out.Event = 'suspended'
            }
            elseif ($Present -and ($Now - $since).TotalSeconds -ge $Config.ArmDelaySeconds) {
                $out.State = 'Armed'; $out.Event = 'armed'
            }
        }
        'Armed' {
            if (-not $Present) {
                $out.Fire = $true; $out.LastFire = $Now
                $out.State = 'Disarmed'; $out.Event = 'fired'
            }
        }
    }
    $out
}

#endregion

#region Logging -----------------------------------------------------------------

function Write-WplLog {
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

function Get-WplPresentUsbDevice {
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

function Invoke-WplAction {
    <#
        .SYNOPSIS
        Carries out the configured action in the current user's session.
        Lock needs to run inside that session, which is why WinPlusLeave runs as a
        logon task in user context and not as a SYSTEM service.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [ValidateSet('Lock', 'Logoff', 'Hibernate', 'Shutdown', 'None')] [string] $Action
    )
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, $Action)) { return }
    switch ($Action) {
        'Lock' {
            if (-not ('WinPlusLeave.NativeMethods' -as [type])) {
                Add-Type -Namespace WinPlusLeave -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool LockWorkStation();
'@
            }
            if (-not [WinPlusLeave.NativeMethods]::LockWorkStation()) {
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

function Show-WplNotification {
    <#
        .SYNOPSIS
        A Windows toast, so the switch never changes state behind your back.
        Uses the WinRT types that Windows PowerShell 5.1 can load; anywhere else
        it quietly does nothing. A notification that fails must never stop the
        switch itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Text
    )
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml(("<toast><visual><binding template='ToastGeneric'><text>{0}</text><text>{1}</text></binding></visual></toast>" -f
            [Security.SecurityElement]::Escape($Title), [Security.SecurityElement]::Escape($Text)))
        # Windows PowerShell's own app id: it is registered on every Windows box.
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    }
    catch {
        Write-Verbose "notification failed: $($_.Exception.Message)"
    }
}

function Start-WplMonitor {
    <#
        .SYNOPSIS
        The main loop. Listens for USB arrival and removal events, re-checks the
        trusted devices on every event and on a slow poll (the safety net for a
        missed event), and feeds each check through Invoke-WplTick.
    #>
    # A monitor loop, not a one-off change; -WhatIf belongs on Invoke-WplAction.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config
    )
    $log = { param($m) Write-WplLog -Message $m -Path $Config.LogPath -MaxKB $Config.LogMaxKB }
    $sourceId = 'WinPlusLeave.DeviceChange'
    $check = {
        $found = @(Find-WplTrustedDevice -Devices @(Get-WplPresentUsbDevice) -Rules $Config.Devices)
        [pscustomobject]@{ Present = ($found.Count -gt 0); Devices = $found }
    }

    $tick = New-WplTickState
    $toldArmed = $false
    $first = & $check
    if ($first.Present) {
        & $log ("started, trusted device present, arming in {0}s: {1}" -f $Config.ArmDelaySeconds, (($first.Devices | ForEach-Object { $_.Name }) -join ', '))
    }
    elseif ($Config.LockIfMissingAtStart) {
        & $log 'started without a trusted device and LockIfMissingAtStart is set: firing'
        Invoke-WplAction -Action $Config.Action
    }
    else {
        & $log 'started without a trusted device: staying disarmed until one is plugged in'
    }

    # EventType 2 = arrival, 3 = removal. Both matter: arrival starts arming.
    Register-CimIndicationEvent -Query 'SELECT * FROM Win32_DeviceChangeEvent WHERE EventType = 2 OR EventType = 3' -SourceIdentifier $sourceId | Out-Null
    try {
        $now = $first
        while ($true) {
            $step = Invoke-WplTick -Tick $tick -Now (Get-Date) -Present $now.Present -Config $Config
            switch ($step.Event) {
                'armed' {
                    & $log ("armed on: " + (($now.Devices | ForEach-Object { $_.Name }) -join ', '))
                    if ($Config.ShowNotifications -and -not $toldArmed) {
                        Show-WplNotification -Title 'Win+Leave is watching your key' -Text 'Pull it out and walk away: your PC locks behind you.'
                        $toldArmed = $true
                    }
                }
                'fired' { & $log "trusted device removed: $($Config.Action)" }
                'suspended' {
                    & $log ("the key came back by itself {0} times within {1} seconds of a lock, it looks faulty: pausing for {2} minutes" -f $step.Bounces.Count, $Config.BounceSeconds, $Config.CooldownMinutes)
                    if ($Config.ShowNotifications) {
                        Show-WplNotification -Title 'Win+Leave paused' -Text ("Your key keeps disconnecting by itself. Locking is paused for {0} minutes. Try another USB port or key." -f $Config.CooldownMinutes)
                    }
                }
                'resumed' {
                    & $log 'pause over: watching again'
                    if ($Config.ShowNotifications) { Show-WplNotification -Title 'Win+Leave is back' -Text 'Plug your key in and it arms again.' }
                }
            }
            if ($step.Fire) {
                try { Invoke-WplAction -Action $Config.Action }
                catch { & $log "action failed: $($_.Exception.Message)" }
            }
            $tick = $step

            # Waiting for a key to settle: look again every second so it arms
            # on time. Otherwise the slow poll is only the safety net.
            $timeout = $Config.PollSeconds
            if ($tick.State -eq 'Disarmed' -and $tick.PresentSince) { $timeout = 1 }
            $evt = Wait-Event -SourceIdentifier $sourceId -Timeout $timeout
            if ($evt) {
                # Windows raises a burst of events per device; drain them so one
                # insertion is one check.
                Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Remove-Event
            }
            $now = & $check
            if ($tick.State -eq 'Armed' -and -not $now.Present -and $Config.DebounceMilliseconds -gt 0) {
                # A hub hiccup or a key re-enumerating after a touch can look
                # like a removal for a few hundred milliseconds. Look twice.
                Start-Sleep -Milliseconds $Config.DebounceMilliseconds
                $now = & $check
            }
        }
    }
    finally {
        Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
        & $log 'stopped'
    }
}

#endregion

Export-ModuleMember -Function Get-WplDefaultConfig, Get-WplConfig, ConvertFrom-WplInstanceId, Test-WplDeviceMatch,
    Find-WplTrustedDevice, New-WplRuleFromInstanceId, New-WplTickState, Invoke-WplTick, Write-WplLog, Show-WplNotification, Get-WplPresentUsbDevice,
    Invoke-WplAction, Start-WplMonitor
