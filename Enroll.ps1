#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
    .SYNOPSIS
    Pins WinPlusLeave to a specific USB device (your YubiKey, a USB stick, a
    BusKill-style magnetic cable with a stick on the end).

    .DESCRIPTION
    Without arguments it lists the USB devices that are plugged in right now and
    asks which one to trust. The rule it writes uses vendor and product id, plus
    the serial when the device reports one over USB.

    Many YubiKeys do NOT report their serial over USB by default. Windows then
    only knows the port it sits in, which is no identity, so the rule falls back
    to "any key of this model". To pin one physical key, make the serial visible
    in the USB descriptor with YubiKey Manager and enroll again.

    .PARAMETER InstanceId
    Enroll this device without the menu (e.g. USB\VID_1050&PID_0407\0012345678).

    .PARAMETER AnyYubiKey
    Trust any YubiKey (vendor 1050). The installer's default.

    .PARAMETER Replace
    Replace all existing rules instead of adding to them.

    .PARAMETER List
    Only show the present USB devices and which of them the config trusts.
#>
[CmdletBinding(DefaultParameterSetName = 'Menu')]
param(
    [Parameter(ParameterSetName = 'Id', Mandatory)] [string] $InstanceId,
    [Parameter(ParameterSetName = 'Any', Mandatory)] [switch] $AnyYubiKey,
    [Parameter(ParameterSetName = 'List', Mandatory)] [switch] $List,
    [string] $Name,
    [switch] $Replace,
    [string] $ConfigPath = (Join-Path $env:ProgramData 'WinPlusLeave\config.json')
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src\WinPlusLeave\WinPlusLeave.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path $env:ProgramFiles 'WinPlusLeave\WinPlusLeave\WinPlusLeave.psm1'
}
Import-Module $modulePath -Force

$present = @(Get-WplPresentUsbDevice | Sort-Object Name)
$config = Get-WplConfig -Path $ConfigPath

if ($List) {
    foreach ($d in $present) {
        $trusted = @(Find-WplTrustedDevice -Devices @($d) -Rules $config.Devices).Count -gt 0
        '{0}  {1,-45} {2}' -f ($(if ($trusted) { '[trusted]' } else { '         ' })), $d.Name, $d.InstanceId
    }
    return
}

switch ($PSCmdlet.ParameterSetName) {
    'Any' { $rule = [pscustomobject]@{ Name = 'Any YubiKey'; VendorId = '1050'; ProductId = '*'; Serial = '*' } }
    'Id' { $rule = New-WplRuleFromInstanceId -InstanceId $InstanceId -Name $Name }
    default {
        if ($present.Count -eq 0) { throw 'No USB devices found. Plug in the key you want to trust and run this again.' }
        Write-Host 'USB devices plugged in right now:'
        for ($i = 0; $i -lt $present.Count; $i++) {
            Write-Host ('  [{0}] {1}  ({2})' -f ($i + 1), $present[$i].Name, $present[$i].InstanceId)
        }
        $pick = Read-Host 'Which one do you trust? (number)'
        $n = 0
        if (-not [int]::TryParse($pick, [ref]$n) -or $n -lt 1 -or $n -gt $present.Count) { throw "Not a number from the list: $pick" }
        $chosen = $present[$n - 1]
        if (-not $Name) { $Name = $chosen.Name }
        $rule = New-WplRuleFromInstanceId -InstanceId $chosen.InstanceId -Name $Name
    }
}

if ($rule.Serial -eq '*' -and $rule.VendorId -ne '*') {
    Write-Warning (("This device reports no USB serial, so the rule trusts every {0}:{1} device of this model. " -f $rule.VendorId, $rule.ProductId) +
        'For a YubiKey: make the serial visible in the USB descriptor with YubiKey Manager, then enroll again.')
}

$rules = @()
if (-not $Replace) {
    # Enrolling a specific key should retire the catch-all default, otherwise
    # any YubiKey still arms the switch and the enrolment changes nothing.
    $rules = @($config.Devices | Where-Object { -not ($_.VendorId -eq '1050' -and $_.ProductId -eq '*' -and $_.Serial -eq '*' -and $rule.Serial -ne '*') })
}
$rules = @($rules | Where-Object { -not ($_.VendorId -eq $rule.VendorId -and $_.ProductId -eq $rule.ProductId -and $_.Serial -eq $rule.Serial) }) + $rule

$raw = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$raw.Devices = $rules
$raw | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
Write-Host ("Trusted: {0} ({1}:{2}:{3}). Sign out and in, or restart the task, to apply." -f $rule.Name, $rule.VendorId, $rule.ProductId, $rule.Serial)
