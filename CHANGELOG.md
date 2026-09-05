## Version 1.3.3 - 2026-09-05

### Features
- New Settings → 主面板 (Main panel) section controlling what the popover lists:
  - **显示的应用 (Apps shown)**: 普通应用 (regular apps only) or 全部应用 (regular + menu-bar apps).
  - **显示数量 (Display count)**: 5, 10 (default), or 全部 (all).
  - "关闭全部已选应用" acts on exactly the rows shown. Tracking and auto-quit continue for all apps regardless of display filtering; menu-bar apps still start excluded.

## Version 1.3.2 - 2026-09-05

### Changed
- Menu-bar (accessory) apps — like wallpaper engines WaifuX or WinDock — now appear in the list. Previously only regular apps were tracked, so apps without a Dock icon were invisible. For safety these default to auto-quit OFF (rows show 已排除): quitting a persistent utility breaks the setup it powers, so they're listed for visibility and memory, and only quit if you switch the row's toggle on. Apple's own system surfaces (Finder, Dock, Spotlight…) remain fully hidden.

## Version 1.3.1 - 2026-09-05

### Fixes
- Per-app memory usage (e.g. "2 GB" under each name) is back. The manager only measures memory while "a window is open", detected via the key/main window check — and the NSPopover-based popover's window doesn't reliably become key (unlike the old MenuBarExtra window), so after any relaunch memory was never measured again. PopoverController now sets an explicit `popoverIsOpen` flag the manager ORs into that check. Verified via AX: rows report memory values again.

## Version 1.3.0 - 2026-09-05

### Fixes
- The popover's five footer buttons respond to real mouse clicks again. The hover-highlight tint was drawn in an `.overlay` ABOVE the button — the moment the cursor was over a row (i.e. exactly when clicking) that tint intercepted the click and the action never fired, while accessibility presses (which bypass hit-testing) kept working, which is why it slipped through testing. Both the hover tint and the material pill background now set `.allowsHitTesting(false)`. Verified with real mouse events: Settings opens, Quit quits.

## Version 1.2.9 - 2026-09-05

### Fixes
- Settings no longer vanishes right after opening. The transient-close re-check fired 0.15s after the window lost key — too aggressive when the system is busy and key status hasn't settled yet (e.g. right after opening Settings from the popover, whose dismissal reshuffles focus). The check now retries for up to ~1.2s while the app is still active and nothing else holds key, and only closes once another app clearly holds focus.

## Version 1.2.8 - 2026-09-05

### Changed
- Popover text renders darker. Popover materials vibrant-blend semantic colors like `.primary` into washed-out gray, so popover text (app names, memory captions, countdown pills, footer) now uses an explicit adaptive near-black/white (`Color.popoverText`) that renders at full strength; secondary info still reads lighter on purpose.

## Version 1.2.6 - 2026-09-05

### Changed
- The popover's five footer options are now translucent material pills instead of near-opaque Liquid Glass buttons, so they match the popover's see-through background. Hover feedback kept (subtle darkening); disabled rows (no apps selected) stay dimmed.

## Version 1.2.5 - 2026-09-05

### Reverted
- Restored the popover's original translucent background after the fully-opaque experiment in 1.2.4 (never publicly released).

## Version 1.2.3 - 2026-09-05

### Fixes
- Popover footer text is back to full-strength black (label color) instead of gray. Inside the new NSPopover, the macOS 26 glass button style muted the label text; the footer labels now set `.foregroundStyle(.primary)` explicitly (black in light mode, white in dark mode; the red force-close icon is unaffected).

## Version 1.2.2 - 2026-09-05

### Fixes
- The popover now reliably closes when clicking anywhere outside it. NSPopover's built-in transient dismissal turned out to be unreliable for a status item in an accessory app (clicks in other apps often didn't dismiss it). The popover now installs its own global + local mouse monitors while shown: clicks outside the popover (excluding the status-item toggle and our own popup menus, e.g. the pause menu) close it. Verified live.

## Version 1.2.1 - 2026-09-05

### Features
- Settings now behaves like the popover: clicking anywhere outside the Settings window closes it. A local mouse monitor handles clicks inside the app (status item, popover) and `windowDidResignKey` handles clicks that go to other apps. Both hold off while one of the window's own popup menus is open (the language picker), and the resign-key path re-checks after a beat so the focus flap when Settings opens from the popover doesn't immediately close it. Verified live: outside click closes, picker open/select keeps it open, opening from the popover keeps it open.

## Version 1.2.0 - 2026-09-05

### Fixes
- Popover now reliably follows the in-app language, in both directions, verified end-to-end. Two root causes found by live UI testing:
  - **Double localization**: footer buttons rendered `AppLocale.L()` output wrapped in `LocalizedStringKey`, so SwiftUI looked the already-translated string up in the bundle again by *system* language — an English UI flipped back to Chinese on Chinese-system Macs. `commandButton`, `footerLabel`, `MenuCommandButton`, and `MenuCommandMenu` now take plain Strings and render them verbatim.
  - **System-locale formatters**: `IdleTime` (durations like "59分钟" vs "59m") and `MemoryFormat` followed the system locale; both now follow the in-app language via the new `AppLocale.locale`.

### Changed
- The popover is now a native `NSStatusItem` + `NSPopover` (content rebuilt fresh on every show) instead of `MenuBarExtra`, whose cached content view was unreachable by any SwiftUI invalidation while closed — the reason five earlier attempts failed. Also matches the Settings window, which always updated live.
- `LaunchAtLoginToggle` observes `AppLocale` so its label follows language changes.

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