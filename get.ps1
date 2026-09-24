<#
    Win+Leave one-line installer, for your own laptop.

      irm https://raw.githubusercontent.com/vdBurgIT/win-plus-leave/main/get.ps1 | iex

    Uninstall:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/vdBurgIT/win-plus-leave/main/get.ps1))) -Uninstall

    What it does: downloads the latest release from GitHub, asks once for
    administrator rights (Windows shows a UAC prompt), installs it for every
    user on this PC and starts it right away for you. Out of the box any
    YubiKey arms it; nothing else to configure.

    Rather read it before running it? Good instinct. Open the URL above in a
    browser, or download this file and run it with -File instead.
#>
param(
    [switch] $Uninstall,
    # A release tag (v1.0.0) or a branch (main). Default: the latest release.
    [string] $Ref
)

$ErrorActionPreference = 'Stop'
$repo = 'vdBurgIT/win-plus-leave'

if ($env:OS -ne 'Windows_NT') { throw 'Win+Leave is for Windows only.' }
# Windows PowerShell 5.1 still defaults to old TLS versions that GitHub refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Test-WplAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WplElevated {
    <# Runs a script file as administrator in a child process and waits for it.
       A child with -ExecutionPolicy Bypass, because the default policy on a
       Windows client (Restricted) would refuse to run the downloaded scripts. #>
    param([string] $File, [string[]] $Arguments = @())
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$File`"") + $Arguments
    $start = @{ FilePath = 'powershell.exe'; ArgumentList = $argList; Wait = $true; PassThru = $true }
    if (-not (Test-WplAdmin)) { $start.Verb = 'RunAs' }
    try { $p = Start-Process @start }
    catch { throw 'Administrator rights are needed (the UAC prompt was cancelled).' }
    if ($p.ExitCode -ne 0) { throw "$(Split-Path -Leaf $File) failed with exit code $($p.ExitCode)." }
}

$installDir = Join-Path $env:ProgramFiles 'WinPlusLeave'

if ($Uninstall) {
    $uninstaller = Join-Path $installDir 'Uninstall.ps1'
    if (-not (Test-Path -LiteralPath $uninstaller)) { Write-Host 'Win+Leave is not installed.'; return }
    Write-Host 'Removing Win+Leave (Windows will ask for administrator rights)...'
    # Run a copy: the uninstaller deletes the folder it would otherwise run from.
    $copy = Join-Path $env:TEMP "WinPlusLeave-uninstall-$([guid]::NewGuid()).ps1"
    Copy-Item -LiteralPath $uninstaller -Destination $copy
    try { Invoke-WplElevated -File $copy -Arguments @('-RemoveConfig') }
    finally { Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue }
    Write-Host 'Win+Leave removed.'
    return
}

# Which version: a pinned ref, or the latest release (falling back to main).
if (-not $Ref) {
    try {
        $Ref = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'win-plus-leave-installer' }).tag_name
    }
    catch { $Ref = 'main' }
}
Write-Host "Downloading Win+Leave ($Ref)..."

$work = Join-Path $env:TEMP "WinPlusLeave-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $zip = Join-Path $work 'win-plus-leave.zip'
    Invoke-WebRequest -Uri "https://codeload.github.com/$repo/zip/$Ref" -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
    $installer = Get-ChildItem -Path $work -Filter 'Install.ps1' -Recurse | Select-Object -First 1
    if (-not $installer) { throw 'The download does not contain Install.ps1.' }
    # Downloaded files carry the "from the internet" mark; the scripts are ours.
    Get-ChildItem -Path $installer.DirectoryName -Recurse -File | Unblock-File

    Write-Host 'Installing (Windows will ask for administrator rights)...'
    Invoke-WplElevated -File $installer.FullName -Arguments @('-NoStart')
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# Start it now, in THIS user's session (the logon task takes over from the next
# sign-in). The monitor refuses a second copy, so this is safe to repeat.
$monitor = Join-Path $installDir 'WinPlusLeave.ps1'
Start-Process -FilePath (Join-Path $env:WINDIR 'System32\conhost.exe') -WindowStyle Hidden -ArgumentList (
    '--headless powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $monitor)

Write-Host ''
Write-Host 'Win+Leave is running. Plug in your YubiKey, wait five seconds, pull it out: locked.'
Write-Host "Only your own key instead of any YubiKey? Run as administrator: $installDir\Enroll.ps1"
Write-Host "Log: $env:LOCALAPPDATA\WinPlusLeave\WinPlusLeave.log"
