## Version 1.1.8 - 2026-09-04

### Fixes
- Popover text now actually updates when switching language. Root cause of the earlier failures: MenuBarExtra keeps its content view alive but hidden while the popover is closed, and an App struct's `body: some Scene` never re-evaluates on ObservableObject changes — so neither `@ObservedObject` (1.1.3), scene updates, nor the `isInserted` toggle (1.1.6) could reach the closed popover. Now `AppLocale` posts an `appLocaleDidChange` notification on language change, and the popover's wrapper view (`LocalePopover`) listens for it and bumps its `.id`, forcing SwiftUI to rebuild the content with fresh strings even while hidden.

## Version 1.1.7 - 2026-09-04

### Fixes
- Busy-app detection now catches download managers like Baidu Netdisk (百度网盘). Previously only checked for sleep-preventing assertions, but downloaders hold `NoIdleSleepAssertion` instead. Added `kIOPMAssertionTypeNoIdleSleep` and `kIOPMAssertionTypeNoDisplaySleep` to the busy types.

## Version 1.1.6 - 2026-09-04

### Fixes
- Popover text now updates when switching language. The `isInserted` binding is toggled off and on on language change to force MenuBarExtra to recreate its cached content. The binding ignores writes from MenuBarExtra, preventing the re-creation loop that caused the 1.1.4 freeze.

## Version 1.1.5 - 2026-09-04

### Fixes
- Reverted the `isInserted` toggle approach from 1.1.4 (caused a freeze when opening Settings). The popover language fix now uses a wrapper view (`LocalePopover`) that observes the locale and ties `.id()` to the current language, forcing SwiftUI to rebuild the popover content on language change.

## Version 1.1.4 - 2026-09-04

### Fixes
- Popover text now updates when switching language. MenuBarExtra caches its content closure, so @ObservedObject alone doesn't reach a closed popover. The menu-bar extra is now briefly removed and re-inserted on language change (`isInserted` toggle), forcing the content to rebuild with fresh strings.

## Version 1.1.3 - 2026-09-04

### Fixes
- Switching the language in Settings now updates the popover, the Settings window, and the window title immediately — no reopen needed. `AppLocale` is now an `ObservableObject` with a `@Published` language; views that read its strings re-render on change. The picker in Settings binds directly to the store, so there's no `.onChange` save step and no "reopen to refresh" note.

## Version 1.1.2 - 2026-09-04

### Features
- In-app language switcher (English / 简体中文) in the new "Language" section of Settings. The choice is saved to the app's own defaults and applies without changing the system language. Every visible string — menu rows, footers, per-app menus, tooltips, empty states, notifications, the settings form itself — now reads from the chosen language at runtime; English falls through to the source key so no translation table is needed for it.

### Fixes
- Per-app "Use default" label now follows the global idle timeout (was hard-coded to "0h" because the row read the setting as an Int while it is stored as a Double).

## Version 1.1.1 - 2026-09-03

### UI
- Global idle timeout in Settings now offers a 30-minute option via a native dropdown (was previously restricted to whole hours via a stepper). The setting is stored as a Double internally so both whole-hour and 30-minute values coexist; previously saved whole-hour values load unchanged.
- The dropdown uses the same macOS 26 inline style as the per-app timeout menu, so picking 30 min reads the same way in both places.
- The per-app "Use default" label now localizes (e.g. "使用默认（30 分钟）" in zh-Hans).

## Version 1.1.0 - 2026-09-03

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