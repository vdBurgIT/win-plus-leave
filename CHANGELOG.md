# Changelog

## 1.0.0 (2026-09-24)

First release of 🪟 + Leave.

- Locks Windows when a trusted USB key (any YubiKey by default) is removed.
- Logon task for every user, running in the user's own session; event-driven with a poll safety net.
- Never a lock loop: a lock disarms, a key must be in for 5 s before it arms, and 3 locks in 10 minutes stand the switch down until the next logon.
- Admin-only config in `%ProgramData%\WinPlusLeave\config.json`; `Enroll.ps1` pins it to specific keys.
- One-line install for your own PC (`get.ps1`), Win32 app + detection script for Intune.
