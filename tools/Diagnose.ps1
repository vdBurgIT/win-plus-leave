<#
    Win+Leave diagnostics. Collects everything needed to see why a pulled key
    did or did not lock, and writes it to one text file on your Desktop.

    How to run: right-click this file > "Run with PowerShell". No admin needed.
    Result: Desktop\WinPlusLeave-diagnose.txt (opens in Notepad when done).
    It only READS: nothing is changed, nothing is sent anywhere.
#>
$ErrorActionPreference = 'Continue'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'WinPlusLeave-diagnose.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Add-Section([string] $Title) { $lines.Add(''); $lines.Add("===== $Title =====") }
function Add-Text($Value) { foreach ($l in (($Value | Out-String -Width 250) -split "`r?`n")) { $lines.Add($l.TrimEnd()) } }

Add-Section 'System'
Add-Text ("Date: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Add-Text ("Windows: {0} (build {1})" -f (Get-CimInstance Win32_OperatingSystem).Caption, [Environment]::OSVersion.Version)
Add-Text ("PowerShell: {0}; user: {1}; session: {2}" -f $PSVersionTable.PSVersion, [Environment]::UserName, (Get-Process -Id $PID).SessionId)

Add-Section 'Installed files'
$installDir = Join-Path $env:ProgramFiles 'WinPlusLeave'
Add-Text (Get-ChildItem -Path $installDir -Recurse -File -ErrorAction SilentlyContinue | Select-Object FullName, Length, LastWriteTime)

Add-Section 'Scheduled task'
$task = Get-ScheduledTask -TaskName 'WinPlusLeave' -ErrorAction SilentlyContinue
if ($task) {
    Add-Text ("State: {0}" -f $task.State)
    Add-Text ($task.Actions | Select-Object Execute, Arguments)
    Add-Text ($task.Principal | Select-Object GroupId, UserId, RunLevel, LogonType)
    Add-Text (Get-ScheduledTaskInfo -TaskName 'WinPlusLeave' -ErrorAction SilentlyContinue | Select-Object LastRunTime, LastTaskResult, NextRunTime)
}
else { Add-Text 'Task WinPlusLeave NOT found.' }

Add-Section 'Running monitor processes'
$procs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'conhost.exe'" |
    Where-Object { $_.CommandLine -like '*WinPlusLeave.ps1*' }
if ($procs) {
    foreach ($p in $procs) {
        $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction SilentlyContinue
        Add-Text ("PID {0} ({1}) session {2} started {3} owner {4}\{5}" -f $p.ProcessId, $p.Name, $p.SessionId, $p.CreationDate, $owner.Domain, $owner.User)
    }
}
else { Add-Text 'NO monitor process is running.' }

Add-Section 'Config (ProgramData\WinPlusLeave\config.json)'
$cfgPath = Join-Path $env:ProgramData 'WinPlusLeave\config.json'
if (Test-Path -LiteralPath $cfgPath) { Add-Text (Get-Content -LiteralPath $cfgPath -Raw) } else { Add-Text 'config.json NOT found (defaults apply).' }

Add-Section 'USB devices plugged in right now (trusted = matches the config)'
$module = Join-Path $installDir 'WinPlusLeave\WinPlusLeave.psm1'
$usb = Get-CimInstance -ClassName Win32_PnPEntity -Filter "DeviceID LIKE 'USB\\VID_%'" -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceID -notmatch '&MI_' }
if (Test-Path -LiteralPath $module) {
    Import-Module $module -Force
    $config = $null
    try { $config = Get-WplConfig -Path $cfgPath } catch { Add-Text "Config error: $($_.Exception.Message)" }
    foreach ($d in $usb) {
        $trusted = $false
        if ($config) { $trusted = @(Find-WplTrustedDevice -Devices @([pscustomobject]@{ InstanceId = $d.DeviceID; Name = $d.Name }) -Rules $config.Devices).Count -gt 0 }
        Add-Text ("{0}  {1}  [{2}]" -f $(if ($trusted) { 'TRUSTED' } else { '       ' }), $d.Name, $d.DeviceID)
    }
}
else {
    Add-Text 'Module not found; listing devices without the trust check.'
    Add-Text ($usb | Select-Object Name, DeviceID)
}

Add-Section 'Monitor log (last 80 lines)'
$log = Join-Path $env:LOCALAPPDATA 'WinPlusLeave\WinPlusLeave.log'
if (Test-Path -LiteralPath $log) { Add-Text (Get-Content -LiteralPath $log -Tail 80) } else { Add-Text "No log at $log (the monitor never ran as this user)." }

Add-Section 'Recent USB removals according to Windows (last 2 hours, Kernel-PnP)'
$since = (Get-Date).AddHours(-2)
Add-Text (Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'VID_1050|USB\\VID' } | Select-Object -First 30 TimeCreated, Id, @{ n = 'Message'; e = { ($_.Message -split "`n")[0] } })

$lines | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host "Written to $out"
Start-Process notepad.exe -ArgumentList "`"$out`""
