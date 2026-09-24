# ⊞+Leave 🚶🔒

**The Win+L you never forget.** Pull your key, walk away, locked.

Everybody knows <kbd>⊞ Win</kbd> + <kbd>L</kbd>. Almost nobody presses it every single time they get up for coffee. **Win+Leave** presses it for you: it watches a trusted USB key (your YubiKey, a USB stick, a magnetic breakaway cable with a stick on the end) and locks Windows the moment that key leaves the laptop. Take your key with you, and your screen is locked behind you. Every time.

It is the deadman switch Windows forgot to ship. Inspired by [BusKill](https://www.buskill.in/) and YubiKill, built for the way Windows fleets are actually managed: a scheduled task, a protected config, and an Intune rollout to every user.

```
 key in  ──►  ARMED  ──(key pulled)──►  🔒 Win+L  ──►  DISARMED
   ▲                                                      │
   └───────────────(key back in: re-arm)──────────────────┘
```

## The golden rule 🥇

> **Working outside the office? Your key is on your lanyard, not in the laptop.**
> **Get up, take your key, and your workplace is locked.**

The café, the train, the client's meeting room, the kitchen table at home: the moment you step away is the moment someone else can reach your keyboard. Win+Leave turns "remember to lock your screen" into something that happens because you took your key, which you were going to do anyway.

Rolled out through Intune to every user, it becomes a house rule instead of a hope: the same behaviour on every laptop, for every user, with nothing to install or configure per person.

## Wear it: the badge-lanyard trick 🪪

Hang the key on the **same lanyard as your building badge**. You never leave without the badge (you need it to get back in), so the key always leaves with you.

<!-- 📸 photo: YubiKey on a badge lanyard next to a building access card -->

For the full deadman effect, put the key on a **retractable badge reel** and keep it plugged in while you work. Stand up, walk away, and the cord pulls the key out for you. Locked, even when you forget. Keep the reel short enough that standing up actually pulls, and test your own key and port first: a USB-A key in a tight port can need more of a tug than a reel gives.

<!-- 📸 photo: retractable badge reel with the key plugged into the laptop -->

**Magnetic USB-C adapter.** Leave the small half in the laptop port and put the other half on the key. A tug snaps them apart cleanly: no bent key, no worn port, and the laptop stays on the table. Lanyard + reel + magnet is the BusKill idea without a special cable. Many cheap adapters are **charge-only**: the key needs data (USB 2.0 is enough), so pick one that carries data and check that Windows sees the key through it.

<!-- 📸 photo: magnetic USB-C adapter in the laptop, key on the lanyard side -->

## How it works

- **A logon task, not a service.** `Install.ps1` registers a scheduled task (`\WinPlusLeave`) that starts at every logon, for every user, *in the user's own session*. Locking a workstation only works from inside that session, which is why this is not a SYSTEM service.
- **Event-driven, with a safety net.** The monitor subscribes to `Win32_DeviceChangeEvent` (USB arrival and removal) and re-checks the trusted devices on every event, plus a slow poll every few seconds in case an event is missed.
- **Arms itself.** It only fires when a trusted device *was* present and is now gone. Insert the key and it arms; pull it and it locks, once; insert it again and it re-arms. No key at logon means it waits quietly instead of locking you out.
- **Debounced.** A key that re-enumerates for a moment (a touch, a flaky hub) is checked twice before anything happens.
- **Never a lock loop.** A key must be in for `ArmDelaySeconds` without a break before it arms, and after `MaxFiresPerWindow` locks in `FlapWindowMinutes` the switch stands down until the next logon. See *A bad day* below.
- **Protected config.** `%ProgramData%\WinPlusLeave\config.json` is writable by administrators only, so a user cannot switch the deadman off by editing a text file.

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

`%ProgramData%\WinPlusLeave\config.json`

| Setting | Default | What it does |
|---|---|---|
| `Devices` | any YubiKey | Rules: `VendorId`, `ProductId`, `Serial` (wildcards `*` and `?`). Any match arms the switch. |
| `Action` | `Lock` | `Lock`, `Logoff`, `Hibernate`, `Shutdown` or `None` (log only, for testing). |
| `DebounceMilliseconds` | `750` | How long a removal must last before it counts. |
| `PollSeconds` | `5` | Safety-net poll between events. |
| `LockIfMissingAtStart` | `false` | Fire at logon when no trusted device is present. Only for kiosks where the key must always be in. |
| `ArmDelaySeconds` | `5` | How long a key must be in, without a break, before it arms. Stops a broken key that blinks in and out. |
| `MaxFiresPerWindow` | `3` | After this many locks within `FlapWindowMinutes` the key is treated as faulty and the switch stands down until the next logon. `0` = never. |
| `FlapWindowMinutes` | `10` | The window for the rule above. |
| `LogPath` | `%LOCALAPPDATA%\WinPlusLeave\WinPlusLeave.log` | Rotates at `LogMaxKB`. |

Changes apply at the next logon, or restart the task.

## A bad day 🌧️ (and why it never locks you out)

1. **08:00** You sign in, YubiKey in. Five seconds later the switch is armed.
2. **12:30** You pull the key and walk to lunch. 🔒 Locked, once, and the switch disarms.
3. **13:15** You are back, but the key is broken. You unlock with your PIN or password.
   **Nothing happens.** A disarmed switch only re-arms when a trusted key is back in, so unlocking without one is fine for the rest of the day.
4. **Tomorrow** you sign in without a key (it is still broken). Nothing happens either: every logon starts disarmed and remembers nothing from earlier logons.

And the nasty version: the broken key is still in the laptop and blinks in and out. It never stays in for `ArmDelaySeconds`, so it never arms. If it does manage to arm and drop a few times, the switch stands down after three locks in ten minutes and says so in the log, instead of locking you out every time you unlock.

These exact scenarios are tests in [`tests/WinPlusLeave.Tests.ps1`](tests/WinPlusLeave.Tests.ps1).

The one setting that *would* lock a logon without a key is `LockIfMissingAtStart`. It is off by default and meant for kiosks where the key must always be in.

## Roll it out to everyone with Intune (Win32 app) ☁️

1. Package the repo folder with the [Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) (`Install.ps1` as setup file).
2. **Install command:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -NoStart`
3. **Uninstall command:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1`
4. **Install behaviour:** System.
5. **Detection:** custom script, [`intune/Detect.ps1`](intune/Detect.ps1).
6. To pin specific keys fleet-wide, ship your own `config.example.json` in the package (it is only copied when no config exists yet).

With `-NoStart` the monitor starts at each user's next logon. Assign the app to **All devices** (or all users) and the golden rule applies to everyone who signs in: the task runs for every user on the device, and the default rule trusts any YubiKey, so nobody has to enroll anything.

## Do I even need this? 🤔

Windows has two built-in cousins. Check them first:

- **Smart card removal behaviour.** If users sign in with the YubiKey as a **PIV smart card**, the policy *Interactive logon: Smart card removal behavior = Lock Workstation* (Intune settings catalog, Local Policies Security Options) plus the *Smart Card Removal Policy* service does exactly this, natively. It does **not** fire for FIDO2/Windows Hello sign-ins or when the key is only used for MFA, which is the gap WinPlusLeave fills.
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
.\src\WinPlusLeave.ps1 -ConfigPath .\config.example.json -Verbose   # foreground run on Windows
```

Tip: set `"Action": "None"` in a test config and watch the log arm and fire without actually locking.

CI runs both on `windows-latest` for every push.

## License

MIT, see [LICENSE](LICENSE).
