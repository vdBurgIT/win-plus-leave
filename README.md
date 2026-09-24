# UsbDeadman 🔌🔒

**Pull your YubiKey, your screen locks.** A small, dependency-free deadman switch for Windows: it watches a trusted USB device (a YubiKey, a USB stick, a magnetic breakaway cable with a stick on the end) and locks the workstation the moment that device disappears.

Inspired by [BusKill](https://www.buskill.in/) and YubiKill, built for the way Windows fleets are actually managed: a scheduled task, a protected config, and an Intune-friendly install.

```
 key in  ──►  ARMED  ──(key pulled)──►  🔒 LockWorkStation  ──►  DISARMED
   ▲                                                               │
   └──────────────────────(key back in: re-arm)────────────────────┘
```

## How it works

- **A logon task, not a service.** `Install.ps1` registers a scheduled task (`\UsbDeadman`) that starts at every logon, for every user, *in the user's own session*. Locking a workstation only works from inside that session, which is why this is not a SYSTEM service.
- **Event-driven, with a safety net.** The monitor subscribes to `Win32_DeviceChangeEvent` (USB arrival and removal) and re-checks the trusted devices on every event, plus a slow poll every few seconds in case an event is missed.
- **Arms itself.** It only fires when a trusted device *was* present and is now gone. Insert the key and it arms; pull it and it locks, once; insert it again and it re-arms. No key at logon means it waits quietly instead of locking you out.
- **Debounced.** A key that re-enumerates for a moment (a touch, a flaky hub) is checked twice before anything happens.
- **Protected config.** `%ProgramData%\UsbDeadman\config.json` is writable by administrators only, so a user cannot switch the deadman off by editing a text file.

## Install

Run in an elevated PowerShell on the device:

```powershell
.\Install.ps1        # copies to Program Files, writes the config, registers + starts the task
.\Enroll.ps1         # optional: pin it to one specific key instead of "any YubiKey"
```

Out of the box it trusts **any YubiKey** (USB vendor id `1050`). `Enroll.ps1` lists the USB devices that are plugged in and asks which one to trust.

```powershell
.\Enroll.ps1 -List                     # what is plugged in, and what is trusted
.\Enroll.ps1 -AnyYubiKey -Replace      # back to "any YubiKey"
.\Enroll.ps1 -InstanceId 'USB\VID_0781&PID_5581\4C530001' -Name 'Red stick'
```

> **About YubiKey serials.** Many YubiKeys do not report their serial over USB by default. Windows then only knows *which port* the key is in, and a port is not an identity, so the rule falls back to "any key of this model". To pin one physical key, make the serial visible in the USB descriptor with YubiKey Manager and enroll again.

Uninstall:

```powershell
.\Uninstall.ps1                 # keeps the config (enrolled keys)
.\Uninstall.ps1 -RemoveConfig   # removes everything
```

## Configuration

`%ProgramData%\UsbDeadman\config.json`

| Setting | Default | What it does |
|---|---|---|
| `Devices` | any YubiKey | Rules: `VendorId`, `ProductId`, `Serial` (wildcards `*` and `?`). Any match arms the switch. |
| `Action` | `Lock` | `Lock`, `Logoff`, `Hibernate`, `Shutdown` or `None` (log only, for testing). |
| `DebounceMilliseconds` | `750` | How long a removal must last before it counts. |
| `PollSeconds` | `5` | Safety-net poll between events. |
| `LockIfMissingAtStart` | `false` | Fire at logon when no trusted device is present. Only for kiosks where the key must always be in. |
| `LogPath` | `%LOCALAPPDATA%\UsbDeadman\UsbDeadman.log` | Rotates at `LogMaxKB`. |

Changes apply at the next logon, or restart the task.

## Deploy with Intune (Win32 app)

1. Package the repo folder with the [Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) (`Install.ps1` as setup file).
2. **Install command:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -NoStart`
3. **Uninstall command:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1`
4. **Install behaviour:** System.
5. **Detection:** custom script, [`intune/Detect.ps1`](intune/Detect.ps1).
6. To pin specific keys fleet-wide, ship your own `config.example.json` in the package (it is only copied when no config exists yet).

With `-NoStart` the monitor starts at each user's next logon.

## Do I even need this? 🤔

Windows has two built-in cousins. Check them first:

- **Smart card removal behaviour.** If users sign in with the YubiKey as a **PIV smart card**, the policy *Interactive logon: Smart card removal behavior = Lock Workstation* (Intune settings catalog, Local Policies Security Options) plus the *Smart Card Removal Policy* service does exactly this, natively. It does **not** fire for FIDO2/Windows Hello sign-ins or when the key is only used for MFA, which is the gap UsbDeadman fills.
- **Dynamic Lock** locks when a paired Bluetooth phone walks away. Convenient, but it waits about 30 seconds after the phone goes out of range, and phones wander.

## Limits (read this before you rely on it)

- **It is a walk-away control, not an anti-tamper control.** It runs as the signed-in user; someone already at the unlocked keyboard can end the process. Its job is the moment you walk away, or the moment someone yanks the laptop off the desk while the key on your lanyard stays with you.
- **A lock is only as good as the unlock.** Make sure unlocking needs a PIN, Windows Hello or a password.
- **`Shutdown`, `Hibernate` and `Logoff` lose unsaved work.** That is the point for some people and a disaster for others. `Lock` is the default for a reason.
- Windows only. PowerShell 5.1 (built in) is all it needs.

## Development

```powershell
Invoke-Pester ./tests                                         # the decision logic, no Windows needed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
.\src\UsbDeadman.ps1 -ConfigPath .\config.example.json -Verbose   # foreground run on Windows
```

Tip: set `"Action": "None"` in a test config and watch the log arm and fire without actually locking.

CI runs both on `windows-latest` for every push.

## License

MIT, see [LICENSE](LICENSE).
