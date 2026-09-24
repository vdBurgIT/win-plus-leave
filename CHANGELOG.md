# Changelog

## 1.1.0 (2026-09-24)

- **Fixed:** testing it a few times in a row switched it off until the next sign-in. The safety breaker counted every lock; now it only counts *bounces*, a key that comes back by itself within 10 seconds of a lock (a faulty key or port). People take longer than that.
- **Changed:** the breaker pauses for 15 minutes (`CooldownMinutes`) instead of until the next sign-in, and resumes by itself.
- **New:** Windows notifications when it first arms after sign-in, when it pauses and when it resumes (`ShowNotifications`).
- **Changed:** arms after 3 seconds instead of 5.
- **Fixed:** installing an update stopped nothing, so the old version kept running until sign-out. `Install.ps1` now stops the running monitor first.
- **New:** `tools/Diagnose.ps1` writes a one-click report to the Desktop.

## 1.0.0 (2026-09-24)

First release of 🪟 + Leave.

- Locks Windows when a trusted USB key (any YubiKey by default) is removed.
- Logon task for every user, running in the user's own session; event-driven with a poll safety net.
- Never a lock loop: a lock disarms, a key must be in for 5 s before it arms, and 3 locks in 10 minutes stand the switch down until the next logon.
- Admin-only config in `%ProgramData%\WinPlusLeave\config.json`; `Enroll.ps1` pins it to specific keys.
- One-line install for your own PC (`get.ps1`), Win32 app + detection script for Intune.
