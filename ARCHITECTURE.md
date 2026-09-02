# AutoQuit architecture

## What this is

AutoQuit is a **macOS menu bar app** (not iOS) that automatically quits apps which have been idle longer than a configurable threshold (default 8h). It lives in the menu bar only (`LSUIElement = YES`, no Dock icon) via SwiftUI's `MenuBarExtra`. Each running app shows a countdown and a per-app opt-out checkbox.

## Build & run

Open `AutoQuit.xcodeproj` in Xcode (scheme `AutoQuit`), or from CLI:

```bash
# Build (DEVELOPMENT_TEAM is blank, so a CLI build needs signing disabled)
xcodebuild -project AutoQuit.xcodeproj -scheme AutoQuit -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO

# Test the logic suite (single test: append /AutoQuitTests/testName)
xcodebuild test -project AutoQuit.xcodeproj -scheme AutoQuit \
  -destination 'platform=macOS' -only-testing:AutoQuitTests CODE_SIGNING_ALLOWED=NO
```

- Target: macOS 13.0+, Swift 5.0, bundle id `com.AutoQuit`.
- `Info.plist` is empty on disk — keys are generated from build settings (`GENERATE_INFOPLIST_FILE = YES`). Edit Info keys in the target build settings, not the plist.
- `AutoQuitTests` covers the pure logic — `QuitDecision.shouldQuit` (idle/opt-out/launch boundaries) and `effectiveAction`, `QuitDecision.effectiveHours`, `IdleTime` formatting, `MemoryFormat`, `PauseDecision` (incl. `nextMorning` with a pinned UTC calendar), `PowerDecision`, and `ProcessTree.allPIDs` (descendant walk over a hand-built parent→children map; locale pinned to `en_US` where asserted strings are exact). The UI-test targets are still Xcode-template stubs, and their runner can't launch unsigned — that's why the test command scopes to `-only-testing:AutoQuitTests`.

## Architecture

Almost everything lives in **`ContentView.swift`**; `AutoQuitApp.swift` is just the `@main` shell.

- **Single global manager.** `AutoQuitApp.swift` creates one file-scope `let runningAppsManager = RunningAppsManager()` and injects it into every view. There is no DI — this global is the source of truth.

- **`RunningAppsManager` (`ObservableObject`) is the whole engine** (`ContentView.swift:31`):
  - `runningApps: [NSRunningApplication: Date]` maps each app to its **last-active timestamp**. An app is quit when `now - timestamp > hoursUntilClose`, or `> perAppHours[toggleKey]` when that app has its own override — stored as `Double` so sub-hour limits (30 minutes) fit.
  - A 1-second `Timer` calls `checkOpenApps()` (`ContentView.swift:172`) — but only when one of the app's windows is key/main, or at least once every 60s otherwise (tracked via `lastChecked`). This keeps the countdown UI live while the menu is open without polling constantly in the background. **This is the core loop; the terminate decision is here.**
  - Subscribes to `NSWorkspace.didDeactivateApplicationNotification` to stamp the moment an app loses focus.
  - `isBlockedApp()` excludes background/menu-bar-only apps (`activationPolicy != .regular`), AutoQuit itself, and a hardcoded list of Apple system bundle ids (Finder, Dock, Spotlight, Siri, etc.). This is what the CHANGELOG fixes refer to — apps like Bartender/CleanShot were wrongly terminated before this filter.

- **Opt-out is keyed by `bundleIdentifier`** (falling back to `localizedName`, then `""`) via `NSRunningApplication.toggleKey`. Reads (`willAutoQuit`) also check a legacy `localizedName` key so opt-outs saved before this change still apply. `toggleStatus: [String: Bool]` is JSON-encoded into an `@AppStorage` `Data` blob (`com.AutoQuit.toggleStatus`). Mutating `toggleStatus` **auto-persists** via its `didSet` (which calls `saveToggleStatus()`) — callers no longer invoke `saveToggleStatus()` by hand. Per-app timeout overrides (`perAppHours`, `com.AutoQuit.perAppHours`) and expiry actions (`perAppActions`, `com.AutoQuit.perAppActions`) follow the same pattern. `perAppHours` is `[String: Double]`: a whole hour decodes identically to an `Int`, so overrides saved before the 30-minute option existed still load.

- **Expiry actions (quit vs. quit-and-restart).** Each app's countdown-pill menu picks an `AppAction` (`quit`, the default, or `restart`), resolved by `QuitDecision.effectiveAction`. At expiry, `performExpiryAction(for:)` terminates the app, then — for restart — `relaunch(...)` polls until the old instance is really gone before `NSWorkspace.openApplication` brings it back (15s deadline). The "Quit now" notification action goes through the same path so it honors a restart choice; the per-row and bulk close buttons always plain-quit.

  Stuck-quit handling: a graceful `terminate()` request can be intercepted by the app (for example, a "save & quit?" confirmation dialog), which means the app keeps running. If AutoQuit then re-added it to tracking on the next tick, the idle clock would reset to *now* and the app would effectively become immortal while the dialog sat there. To prevent that, the pid is added to a transient `quitingPIDs` set for the grace window — which `addCurrentRunningApps` skips — and a 5-second delayed check on the main thread verifies the pid is actually gone. If it isn't, AutoQuit escalates to `forceTerminate()` (SIGKILL) and logs a warning. The "force quit" toggle bypasses this entirely and SIGKILLs immediately.

- **Pause ("do not disturb").** `pauseUntil: Date?` is `@Published` and mirrored into UserDefaults (`pauseUntil`, seconds since 1970) so a pause survives relaunch. In `checkOpenApps`, a pause (explicit, or implicit via the battery rule below) stamps every tracked app's idle time to *now* — clocks stand still instead of being reset — and all pending warnings are cleared so resumed apps get a fresh warning round. An expired pause clears itself on the next tick. `PauseDecision` (incl. `nextMorning`, which computes the next 9:00) is pure and unit-tested. The menu-bar label (`MenuBarLabel` in `AutoQuitApp.swift`) swaps to a `pause.circle` symbol while paused.

- **Power awareness.** `isOnBattery()` reads IOPowerSources (`IOPSCopyPowerSourcesInfo`); desktops report "not on battery". With `batteryOnlyQuit` on, being on power suppresses auto-quit exactly like a pause. `PowerDecision.suppressed` is pure and unit-tested.

- **Memory footprint.** A row shows the app's *total* footprint — its own process plus every helper process and other subprocesses it launched — as a single figure (`211 MB` / `2.1 GB`). The per-process value is `phys_footprint` (the same figure Activity Monitor shows in its "Memory" column), so the rows here line up with what the user sees there. Per process it is read with `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` — a libproc call that needs no task port or entitlement, and therefore works for every same-user process (an earlier attempt through `task_for_pid` + `task_info(TASK_VM_INFO)` always failed without a debug entitlement and was removed). `phys_footprint` counts what the process is itself responsible for — anonymous pages, compressed memory, IOKit mappings — and deliberately excludes the read-only file-backed pages (dyld shared cache, framework binaries) that RSS also counts; summing RSS across an app's processes double-counts those shared pages, and missing compressed memory badly understates apps that have been paged (a long-idle Python process can show 59 MB RSS but 292 MB footprint). If `proc_pid_rusage` fails, the code falls back to `proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size` (RSS) — worse accounting, but better than showing nothing.

  **Responsible-process heuristic.** PPID alone misses subprocesses that get reparented to launchd (PPID=1) — common with Electron apps that shell out to a venv python through `uv`. To recover them, AutoQuit builds three sets per app on every refresh (only while a window is open):
  - the PPID tree (same as before — `processTree()` → `ProcessTree.allPIDs`),
  - `processPaths(for:)` via `proc_pidpath` — matches processes whose executable path contains the app name and lives under the app's bundle directory (or any of its 12 ancestor directories),
  - `processCommandLines()` via `ps -e -o pid,args` — matches processes whose command line contains the app name and starts with the bundle path.
  
  The union of those three sets is the app's *responsible* processes; `residentMemoryIncludingResponsible(of:in:for:paths:cmdlines:)` sums their footprint. `performExpiryAction` uses the same union when computing "freed X of memory" so the notification matches the row. Prefixes are suffixed with `/` to avoid matching unrelated paths that just happen to share a prefix (`/.hermesfoo` won't match `/.hermes/`). Bundle ancestor traversal stops at `/` or after 12 levels.

  The footprint is only refreshed while a window is open (`windowIsOpen`, set in the 1s timer from the same key/main-window check that drives live countdowns): building the table touches every process on the machine, so it isn't worth doing every minute. `performExpiryAction` snapshots the app's bytes before terminating — falling back to a fresh responsible-process read when `memoryUsage` has no entry — and posts an outcome notification ("Quit X / freed 1.2 GB") when `notifyFreedMemory` is on.

- **Settings** open in a separate `NSWindow` managed by `SettingsWindowController`, a singleton tracked via its static `.current` so a second click re-focuses the existing window instead of opening another. On reopen the window swaps in a fresh `SettingsView` so live state (e.g. the login toggle) is re-read; the singleton slot is only cleared in `deinit` if it still points at that controller.

- **Popover footer bulk actions.** *Close all selected* / *Force close all selected* (above *Settings* in the footer) terminate every app whose toggle is on — `runningApps.keys` filtered by `willAutoQuit` — via `terminate()` / `forceTerminate()`, the same calls the per-row buttons use. No manual cleanup: the 1s timer prunes apps once they've quit. Both disable when nothing is selected. The *Pause auto-quit* row between them offers the same three durations (1 hour / 4 hours / tomorrow morning): on macOS 26 it is a real glass `Button` — identical construction to the Settings row, so the rendering is pixel-identical — whose action presents the durations as a native `NSMenu` anchored at the mouse (`openPauseMenu` + `PauseMenuTarget`), because SwiftUI has no glass `MenuStyle` and a hand-drawn glass card on a `Menu` label can't match the button style's shape and hover behavior. On macOS before 26 it uses `MenuCommandMenu` — a copy of `MenuCommandButton`'s hover row — so the row looks like its siblings either way.

## Persistence

The rows are ordered by total footprint (app + helper processes), largest first. Apps whose memory hasn't been measured yet fall to the bottom, and ties break alphabetically by name so the list stays deterministic between refreshes. The sort is computed by `sortedApps` in `AppRow` from `memoryUsage`.

All state is `@AppStorage` (UserDefaults): `hoursUntilClose: Int`, `showCloseButton: Bool`, `skipBusyApps`, `warnBeforeQuit`, `batteryOnlyQuit`, `notifyFreedMemory`, `forceQuit`, and the encoded blobs (`toggleStatus`, `perAppHours` (hours as doubles), `perAppActions`). The pause deadline is plain UserDefaults (`pauseUntil`, a Double) behind a `@Published` property so SwiftUI reacts to it.

The default for `hoursUntilClose` lives in one place — `AppDefaults.hoursUntilClose` (8) — and every `@AppStorage("hoursUntilClose")` declaration (manager, `AppRow`, `SettingsView`) references it, so the defaults can't drift apart.

## Dependencies

None. Launch-at-login is handled by `LaunchAtLoginToggle` (`ContentView.swift`), a small native wrapper around `SMAppService.mainApp` (ServiceManagement, macOS 13+). This replaced the former `LaunchAtLogin-Modern` SPM package.
