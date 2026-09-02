## Unreleased

### Features
- Pause ("do not disturb"): stand auto-quit down for 1 hour, 4 hours, or until tomorrow morning. The menu-bar icon switches to a pause symbol, the popover shows remaining time with a Resume button, and idle clocks resume where they left off. A pause survives a relaunch.
- Per-app expiry action: in each app's countdown menu, choose whether it is quit or quit-and-restarted when the timer runs out. Restarted apps show a ↻ symbol on their countdown pill, and the warning notification says so.
- Memory footprint now uses `phys_footprint` per process (the same value Activity Monitor shows in its "Memory" column), read via `proc_pid_rusage` — no task port or entitlement needed, so it works for every same-user process. The previous implementation fell back to resident-set size (RSS), which both double-counts shared library pages when summing an app's processes and misses compressed memory entirely (a long-idle process can show 59 MB RSS but 292 MB real footprint). Rows show a single total figure — the app plus its helper processes. The scan only runs while the popover is open, since it touches every process on the system. After an automatic quit or restart, a notification reports how much memory was freed (optional, on by default).
- Per-app timeout goes sub-hour: 30 minutes joins the countdown menu's choices (30 min, 1h, 2h, 4h, 8h, 12h, 24h, 48h). Per-app overrides are stored as doubles, so whole-hour values saved before this still load unchanged.
- Battery awareness: new "Only quit on battery power" setting. While the Mac is plugged in (or on desktops), auto-quit stands down and idle clocks freeze until it runs on battery again; the popover shows an "on power" strip.
- Simplified Chinese translation (String Catalogs).

### UI
- The "Pause auto-quit" footer row is now a real glass button on macOS 26 — the exact same construction as Settings and the other footer rows, so shape, height, and hover behavior match pixel-for-pixel. Its three durations open as a native menu anchored at the row. On macOS before 26 it keeps the same hover-row style as its siblings.

### Fixes
- Graceful quits that get stuck in a confirmation dialog (e.g. Eastmoney's "save & quit?" prompt) no longer make the app immortal — after a few seconds AutoQuit force-quits the offender instead of re-adding it with a fresh idle clock.
- The warning notification no longer hard-codes "60 seconds" in its text — the grace period is interpolated.
- First-run notification authorization is requested only once even when several warnings fire in the same second.
- The Launch-at-login switch re-reads its real status each time Settings reopens (it used to show a stale value if the status changed elsewhere).
- Replacing the Settings window's controller no longer clears the singleton slot of its successor.

## Version 1.0.0 - 2026-06-30

### Features
- Initial release