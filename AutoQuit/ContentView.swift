// The heart of AutoQuit. This one file holds the engine that watches your
// running apps and quits the ones left idle too long, plus everything you see:
// the menu-bar popover (a row and countdown per app) and the Settings window.

import AppKit
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os
import ServiceManagement
import SwiftUI
import UserNotifications

// The built-in idle time (8 hours), kept in one place so every part of the app
// agrees on the same default.
enum AppDefaults {
    // Stored as Double so sub-hour limits (30 min = 0.5h) fit alongside whole hours.
    static let hoursUntilClose: Double = 8
}

// Lets the user pick between English and Simplified Chinese without
// changing the system language. `Bundle.preferredLocalizations` is read-only
// in Swift, so we do a manual lookup: open the matching lproj bundle and
// call `localizedString(forKey:table:)`. English is the source language, so
// the "translation" is the key itself — no file lookup needed.
//
// Backed by an ObservableObject so that changing the language re-renders
// every view that observes it (the popover AND the Settings window).
final class AppLocale: ObservableObject {
    static let key = "appLanguage"

    static let choices: [(id: String, label: String)] = [
        ("en", "English"),
        ("zh-Hans", "简体中文"),
    ]

    private(set) static var shared = AppLocale()

    @Published var language: String {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language, forKey: Self.key)
            bundle = language == "en"
                ? nil
                : Bundle(path: Bundle.main.path(forResource: language, ofType: "lproj") ?? "")
        }
    }

    private var bundle: Bundle?

    private init() {
        language = UserDefaults.standard.string(forKey: Self.key) ?? "en"
        if language != "en" {
            bundle = Bundle(path: Bundle.main.path(forResource: language, ofType: "lproj") ?? "")
        }
    }

    static func current() -> String { shared.language }

    // Plain key lookup. Falls back to the key itself when the language is
    // English or the .strings file is missing the key.
    static func L(_ key: String) -> String {
        let shared = Self.shared
        guard shared.language != "en", let bundle = shared.bundle else { return key }
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    // Formatted lookup: pulls the template, then runs it through
    // `String(format:)` with the supplied arguments.
    static func Lf(_ key: String, _ args: CVarArg...) -> String {
        String(format: L(key), locale: .autoupdatingCurrent, arguments: args)
    }
}

// A stable name tag for each app — its hidden bundle id, or its visible name if
// it has none. We use this to remember an app's settings even after it, or the
// whole Mac, has restarted.
extension NSRunningApplication {
    var toggleKey: String { bundleIdentifier ?? localizedName ?? "" }
}

// The single yes/no rule: should this app be quit right now? Kept separate and
// simple so it can be checked by automated tests.
enum QuitDecision {
    // Quit only if you haven't excluded it, it has finished starting up, and it
    // has now been idle longer than its time limit.
    static func shouldQuit(idle: TimeInterval, thresholdHours: Double,
                           isFinishedLaunching: Bool, optedOut: Bool) -> Bool {
        !optedOut && isFinishedLaunching && idle > thresholdHours * 3600
    }

    /// Per-app override wins; otherwise the global timeout. Pure, so it's unit-tested.
    /// Doubles so sub-hour limits (the 30-minute choice) fit; a stored whole hour
    /// still decodes as a Double, so existing saved values keep working.
    static func effectiveHours(perApp: [String: Double], key: String, global: Double) -> Double {
        perApp[key] ?? global
    }

    /// Which expiry action this app uses — its own choice, or the default (quit).
    /// Pure, so it's unit-tested.
    static func effectiveAction(perApp: [String: String], key: String) -> AppAction {
        perApp[key].flatMap(AppAction.init(rawValue:)) ?? .defaultValue
    }
}

// What AutoQuit does when an app's countdown runs out: close it, or close it
// and bring it straight back. "Restart" suits apps that bloat over time — a
// fresh launch reclaims the memory, yet the app is right there when you return.
enum AppAction: String {
    case quit
    case restart

    static let defaultValue = AppAction.quit
}

// The pause ("do not disturb") rule. While paused, nothing is quit and every
// idle clock stands still, resuming where it left off once the pause is over.
enum PauseDecision {
    static func isPaused(now: Date, until: Date?) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// The next 9:00 in the morning: today's if it's still ahead, otherwise
    /// tomorrow's. Calendar is injected so tests stay deterministic.
    static func nextMorning(after now: Date, hour: Int = 9, minute: Int = 0,
                            calendar: Calendar = .current) -> Date? {
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }
}

// The power rule: with "only on battery" switched on, being plugged in stands
// auto-quit down the same way an explicit pause does.
enum PowerDecision {
    /// True when auto-quit should hold off: the option is on, but the Mac is on
    /// power (or has no battery at all, like a desktop).
    static func suppressed(batteryOnly: Bool, onBattery: Bool) -> Bool {
        batteryOnly && !onBattery
    }
}

// Turns a byte count into short, readable text like "345 MB" or "1.2 GB" — the
// number shown under each app and in the "freed" notification. Binary units
// (1 GB = 1024 MB), one decimal only once we're in gigabytes.
enum MemoryFormat {
    private static let mib = 1024.0 * 1024.0

    static func short(_ bytes: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let gib = Double(bytes) / (mib * 1024.0)
        let inGigabytes = gib >= 1
        let value = inGigabytes ? gib : Double(bytes) / mib

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.decimalSeparator = locale.decimalSeparator
        formatter.maximumFractionDigits = inGigabytes ? 1 : 0
        formatter.minimumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        return "\(number) \(inGigabytes ? "GB" : "MB")"
    }
}

// An app's footprint is its own memory plus the memory of every process it
// spawned: Electron-style apps keep almost all of theirs in helper processes, so
// the main process alone badly understates them. The walk is pure so it can be
// unit-tested; the system-wide pid scan that feeds it lives in the manager.
enum ProcessTree {
    /// root and every descendant reachable through the parent → children map.
    static func allPIDs(of root: pid_t, in tree: [pid_t: [pid_t]]) -> [pid_t] {
        var all = [root]
        var queue = [root]
        while let current = queue.popLast() {
            let children = tree[current, default: []]
            all.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return all
    }
}

// The engine. It watches every running app, counts how long each has sat unused,
// warns you, and quits the ones idle past their limit. Everything else in the
// app is just buttons and labels sitting on top of this.
class RunningAppsManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    // Every app we're tracking, each paired with the last time it was in front.
    // "Idle" simply means how long ago that was.
    @Published var runningApps: [NSRunningApplication: Date] = [:]
    private var timer: Timer?
    private var deactivateToken: NSObjectProtocol?
    private var lastChecked = Date.distantPast
    // True while a window (the popover, or Settings) is on screen. Memory is
    // only re-read then — the footprint scan touches every process on the system.
    private var windowIsOpen = false
    // Your saved preferences. These survive quitting and reopening the app.
    // Stored as Double so a 30-minute (0.5h) global limit fits alongside whole hours.
    @AppStorage("hoursUntilClose") var hoursUntilClose: Double = AppDefaults.hoursUntilClose
    @AppStorage("forceQuit") var forceQuit: Bool = false
    @AppStorage("skipBusyApps") var skipBusyApps: Bool = true
    @AppStorage("warnBeforeQuit") var warnBeforeQuit: Bool = true
    @AppStorage("batteryOnlyQuit") var batteryOnlyQuit: Bool = false
    @AppStorage("notifyFreedMemory") var notifyFreedMemory: Bool = true
    // The apps you've switched off (excluded from auto-quit). Saved automatically
    // the moment it changes.
    @Published var toggleStatus: [String: Bool] = [:] {
        didSet { saveToggleStatus() }
    }
    // Per-app custom time limits (e.g. quit this one after 2h instead of the
    // default). Doubles so a 30-minute limit fits; whole-hour values saved before
    // the change still decode. Also saved automatically.
    @Published var perAppHours: [String: Double] = [:] {
        didSet { savePerAppHours() }
    }
    // Per-app expiry actions (quit, or quit-and-restart), stored as AppAction
    // raw values. Saved automatically, same as the two lists above.
    @Published var perAppActions: [String: String] = [:] {
        didSet { savePerAppActions() }
    }

    // Where those three per-app lists are actually stored between launches.
    @AppStorage("com.AutoQuit.toggleStatus") var toggleStatusData: Data = Data()
    @AppStorage("com.AutoQuit.perAppHours") var perAppHoursData: Data = Data()
    @AppStorage("com.AutoQuit.perAppActions") var perAppActionsData: Data = Data()

    // Pause ("do not disturb"): until this moment nothing is quit and every
    // idle clock stands still. Kept in UserDefaults so a pause survives a
    // relaunch of AutoQuit; published so the menu-bar icon and popover react.
    @Published var pauseUntil: Date? {
        didSet {
            UserDefaults.standard.set(pauseUntil?.timeIntervalSince1970 ?? 0, forKey: "pauseUntil")
        }
    }
    // Current power source, refreshed on every check. Published so the popover
    // can show its "on power — paused" chip without polling on its own.
    @Published private(set) var onBattery = false

    // Live resident memory per tracked app (pid → bytes), refreshed on every
    // check so the rows show real numbers while the popover is open. phys_footprint
    // includes every descendant process, so a row shows one number — the summary.
    @Published var memoryUsage: [pid_t: Int] = [:]
    // Pids that are mid-quit (grace period after a graceful request). While a
    // pid is here, don't re-add it to tracking — otherwise a stuck confirmation
    // dialog re-adds the app with a fresh idle clock and never auto-quits again.
    private var quitingPIDs: Set<pid_t> = []

    // Quit-warning state, in-memory only: pid → when we posted the heads-up.
    private var warnedAt: [pid_t: Date] = [:]
    private var notificationAuthChecked = false
    private var notificationsDenied = false
    private static let warningCategory = "AUTOQUIT_WARNING"
    private let warningGrace: TimeInterval = 60   // ponytail: 60s lead is hardcoded; add a stepper only if asked

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "RunningAppsManager")

    override init() {
        super.init()
        // Load saved settings, then seed the list with apps that are already open.
        syncToggleStatus()
        syncPerAppHours()
        syncPerAppActions()
        // A pause survives a relaunch — restore it (and drop it if it has since expired).
        let savedPause = UserDefaults.standard.double(forKey: "pauseUntil")
        let restoredPause = savedPause > 0 ? Date(timeIntervalSince1970: savedPause) : nil
        pauseUntil = PauseDecision.isPaused(now: Date(), until: restoredPause) ? restoredPause : nil
        onBattery = isOnBattery()
        addCurrentRunningApps()

        log.debug("Init")
        // Whenever an app loses focus, stamp that as its "last used" time — that's
        // how we know how long it has been sitting idle.
        let center = NSWorkspace.shared.notificationCenter
        deactivateToken = center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                             object: nil,
                                             queue: .main) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.log.debug("didDeactivate: \(app.localizedName ?? "Unknown", privacy: .public)")
            if !self.isBlockedApp(app) {
                self.runningApps[app] = Date()
            }
        }
        // Look once a second, but only do the real work when the menu is open (so
        // the countdowns tick live) or roughly once a minute otherwise. The rest
        // of the time it barely lifts a finger, to save battery.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let hasOpenWindow = NSApplication.shared.windows.contains { $0.isKeyWindow || $0.isMainWindow }
            self.windowIsOpen = hasOpenWindow

            if hasOpenWindow || Date().timeIntervalSince(self.lastChecked) >= 60 {
                self.checkOpenApps()
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let deactivateToken {
            NSWorkspace.shared.notificationCenter.removeObserver(deactivateToken)
        }
        log.debug("RunningAppsManager is being deallocated")
    }

    // Load your saved per-app on/off choices back in when the app starts.
    private func syncToggleStatus() {
        guard !toggleStatusData.isEmpty else { return }   // first launch: nothing saved yet, not a failure
        do {
            toggleStatus = try JSONDecoder().decode([String: Bool].self, from: toggleStatusData)
        } catch {
            log.error("Failed to decode toggleStatus (opt-outs lost): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Write the per-app on/off choices out so they survive a relaunch.
    func saveToggleStatus() {
        do {
            toggleStatusData = try JSONEncoder().encode(toggleStatus)
        } catch {
            log.error("Failed to encode toggleStatus (opt-outs not saved): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Load your saved per-app time limits back in when the app starts.
    private func syncPerAppHours() {
        guard !perAppHoursData.isEmpty else { return }   // first launch: nothing saved yet, not a failure
        do {
            perAppHours = try JSONDecoder().decode([String: Double].self, from: perAppHoursData)
        } catch {
            log.error("Failed to decode perAppHours (per-app timeouts lost): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Write the per-app time limits out so they survive a relaunch.
    func savePerAppHours() {
        do {
            perAppHoursData = try JSONEncoder().encode(perAppHours)
        } catch {
            log.error("Failed to encode perAppHours (per-app timeouts not saved): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Load your saved per-app expiry actions back in when the app starts.
    private func syncPerAppActions() {
        guard !perAppActionsData.isEmpty else { return }   // first launch: nothing saved yet, not a failure
        do {
            perAppActions = try JSONDecoder().decode([String: String].self, from: perAppActionsData)
        } catch {
            log.error("Failed to decode perAppActions (per-app expiry actions lost): \(error.localizedDescription, privacy: .public)")
        }
    }

    // Write the per-app expiry actions out so they survive a relaunch.
    func savePerAppActions() {
        do {
            perAppActionsData = try JSONEncoder().encode(perAppActions)
        } catch {
            log.error("Failed to encode perAppActions (per-app expiry actions not saved): \(error.localizedDescription, privacy: .public)")
        }
    }

    // This app's idle limit: its own custom setting if you've set one, otherwise
    // the shared default.
    func effectiveHours(for app: NSRunningApplication) -> Double {
        QuitDecision.effectiveHours(perApp: perAppHours, key: app.toggleKey, global: hoursUntilClose)
    }

    // This app's expiry action: quit-and-restart if you've chosen that, otherwise quit.
    func effectiveAction(for app: NSRunningApplication) -> AppAction {
        QuitDecision.effectiveAction(perApp: perAppActions, key: app.toggleKey)
    }

    // MARK: Pause ("do not disturb")

    // Are we inside a pause right now? Computed fresh so it also flips to false
    // the moment an expired pause is noticed (checkOpenApps clears it).
    var isPaused: Bool { PauseDecision.isPaused(now: Date(), until: pauseUntil) }

    func pause(for interval: TimeInterval) {
        pauseUntil = Date().addingTimeInterval(interval)
        log.notice("Paused for \(Int(interval), privacy: .public)s")
    }

    func pauseUntilTomorrowMorning() {
        guard let morning = PauseDecision.nextMorning(after: Date()) else { return }
        pauseUntil = morning
        log.notice("Paused until \(morning, privacy: .public)")
    }

    func resume() {
        pauseUntil = nil
        log.notice("Resumed")
    }

    // MARK: Power & memory

    // True when the Mac is running on battery. Reads the power-source list once;
    // a Mac with no battery (desktops, or no battery installed) reports false.
    private func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
               let state = description[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }

    /// Physical footprint of one process, in bytes — the same value Activity
    /// Monitor shows in its "Memory" column. This is what the process is itself
    /// responsible for (anonymous + compressed + IOKit-mapped pages), not RSS:
    /// RSS also counts read-only file-backed pages (dyld shared cache, framework
    /// binaries) that every process maps, which would be double-counted once you
    /// sum an app's main process with its helpers. Read via proc_pid_rusage, which
    /// needs no task port or entitlement (flavor 4 = RUSAGE_INFO_V4; the constant
    /// is a plain #define and doesn't import into Swift).
    private func residentMemory(of pid: pid_t) -> Int? {
        var info = rusage_info_v4()
        let kr = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            proc_pid_rusage(pid, 4, UnsafeMutableRawPointer(p)
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self))
        }
        guard kr == 0 else {
            // Last resort: proc_taskinfo's resident_size field is RSS. It includes
            // the shared read-only pages, so sums across an app's processes can
            // double-count shared libraries — but it beats showing nothing.
            var ti = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { return nil }
            return Int(ti.pti_resident_size)
        }
        return Int(info.ri_phys_footprint)
    }

    // parent → children for every process on the system, in a single syscall.
    // Building this table is the expensive part of a real footprint, so it's done
    // once per refresh rather than once per app.
    private func processTree() -> [pid_t: [pid_t]] {
        processTable().tree
    }

    // Same as processTree() but also returns the flat list of every pid seen, so
    // callers that need to look up non-child processes (by path or command line)
    // don't have to re-read the kernel table.
    private func processTable() -> (tree: [pid_t: [pid_t]], allPIDs: [pid_t]) {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 0 else { return ([:], []) }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: length / stride)
        guard sysctl(&mib, 3, &procs, &length, nil, 0) == 0 else { return ([:], []) }

        var tree: [pid_t: [pid_t]] = [:]
        var pids: [pid_t] = []
        for proc in procs.prefix(length / stride) {
            let pid = pid_t(proc.kp_proc.p_pid)
            let parent = pid_t(proc.kp_eproc.e_ppid)
            guard pid > 0 else { continue }
            pids.append(pid)
            if parent > 0 { tree[parent, default: []].append(pid) }
        }
        return (tree, pids)
    }

    // An app plus everything it spawned, in bytes. `nil` when nothing could be read.
    private func residentMemoryIncludingChildren(of pid: pid_t, in tree: [pid_t: [pid_t]]) -> Int? {
        var total = 0
        var readAny = false
        for child in ProcessTree.allPIDs(of: pid, in: tree) {
            if let bytes = residentMemory(of: child) {
                total += bytes
                readAny = true
            }
        }
        return readAny ? total : nil
    }

    // Every process's on-disk executable path, via proc_pidpath. Called once per
    // refresh (only while a window is open) so the responsible-process heuristic
    // below can match subprocesses whose PPID no longer points at the app.
    private func processPaths(for pids: [pid_t]) -> [pid_t: String] {
        var paths: [pid_t: String] = [:]
        for pid in pids {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let size = MemoryLayout<CChar>.stride * buf.count
            if proc_pidpath(pid, &buf, UInt32(size)) > 0 {
                paths[pid] = String(cString: buf)
            }
        }
        return paths
    }

    // Every process's full command line, captured once per refresh via `ps`. The
    // kernel doesn't expose argv through any public API, but the command line is
    // the only reliable signal for subprocesses whose executable lives outside
    // the app's bundle (e.g. a Hermes python invoked through a uv venv).
    private func processCommandLines() -> [pid_t: String] {
        let pipe = Pipe()
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-e", "-o", "pid,args"]
        task.standardOutput = pipe
        task.launch()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            task.waitUntilExit()
            return [:]
        }
        task.waitUntilExit()

        var cmdlines: [pid_t: String] = [:]
        var first = true
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Skip the header line ("PID ARGS").
            if first { first = false; continue }
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int(trimmed[..<space]) else { continue }
            let start = trimmed.index(space, offsetBy: 1)
            cmdlines[pid_t(pid)] = String(trimmed[start...])
        }
        return cmdlines
    }

    // The set of pids that belong to an app: its PPID-tree descendants plus any
    // processes whose path or command line shows they were launched from the app's
    // installation tree. PPID alone misses subprocesses that get reparented to
    // launchd (PPID=1); the path/cmdline heuristics recover them.
    private func responsiblePIDs(for app: NSRunningApplication, in tree: [pid_t: [pid_t]],
                                 paths: [pid_t: String], cmdlines: [pid_t: String]) -> Set<pid_t> {
        var pids = Set(ProcessTree.allPIDs(of: app.processIdentifier, in: tree))

        guard let bundleURL = app.bundleURL,
              let appName = app.localizedName,
              appName.count >= 3 else { return pids }

        let appNameLower = appName.lowercased()
        var dirs = [bundleURL.path]
        var cur = bundleURL
        for _ in 0..<12 {
            let parent = cur.deletingLastPathComponent()
            guard parent.path != cur.path, parent.path != "/" else { break }
            dirs.append(parent.path); cur = parent
        }
        let prefixes: [String] = dirs.lazy.map { $0.lowercased() + "/" }.map { $0 }

        for (pid, path) in paths where !pids.contains(pid) {
            let pl = path.lowercased()
            if pl.contains(appNameLower), prefixes.contains { prefix in pl.hasPrefix(prefix) } {
                pids.insert(pid); continue
            }
            if let cl = cmdlines[pid] {
                let clLower = cl.lowercased()
                if clLower.contains(appNameLower), prefixes.contains { prefix in clLower.hasPrefix(prefix) } {
                    pids.insert(pid)
                }
            }
        }
        return pids
    }

    // Total footprint of every pid responsible for an app, in bytes.
    private func residentMemoryIncludingResponsible(of pid: pid_t, in tree: [pid_t: [pid_t]],
        for app: NSRunningApplication, paths: [pid_t: String], cmdlines: [pid_t: String]) -> Int? {
        let responsible = responsiblePIDs(for: app, in: tree, paths: paths, cmdlines: cmdlines)
        var total = 0
        var readAny = false
        for child in responsible {
            if let bytes = residentMemory(of: child) { total += bytes; readAny = true }
        }
        return readAny ? total : nil
    }

    // Finds apps that are actively doing something — playing video or music,
    // downloading, or holding the Mac awake — so we never quit them mid-task.
    /// pids currently asserting "don't sleep" — media playback, downloads, renders.
    /// One IOKit call, no entitlement; the single signal that an app is doing real work.
    private func busyPIDs() -> Set<pid_t> {
        var assertionsRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertionsRef) == kIOReturnSuccess,
              let byProcess = assertionsRef?.takeRetainedValue() as? [Int: [[String: Any]]]
        else { return [] }
        let busyTypes: Set<String> = [kIOPMAssertionTypePreventUserIdleSystemSleep,
                                      kIOPMAssertionTypePreventSystemSleep,
                                      kIOPMAssertionTypePreventUserIdleDisplaySleep]
        return Set(byProcess.compactMap { pid, list in
            list.contains { ($0[kIOPMAssertionTypeKey] as? String).map(busyTypes.contains) ?? false }
                ? pid_t(pid) : nil
        })
    }

    // Should this app be auto-quit at all? Yes by default, unless you've switched
    // it off. (Also checks an older-style saved setting so choices made before an
    // update still count.)
    func willAutoQuit(_ app: NSRunningApplication) -> Bool {
        toggleStatus[app.toggleKey] ?? toggleStatus[app.localizedName ?? ""] ?? true
    }

    // The safety list: apps AutoQuit must never touch. Background helpers and
    // menu-bar tools, AutoQuit itself, and Apple's own system apps (Finder, Dock,
    // Spotlight, Siri…) are always left alone. This filter exists because quitting
    // them caused real bugs — e.g. menu-bar utilities like Bartender getting
    // killed by mistake.
    private func isBlockedApp(_ app: NSRunningApplication) -> Bool {
        let currentAppBundleIdentifier = Bundle.main.bundleIdentifier
        let excludedIdentifiers = ["com.apple.loginwindow",
                                   "com.apple.systemuiserver",
                                   "com.apple.dock",
                                   "com.apple.finder",
                                   "com.apple.coreautha",
                                   "com.apple.Spotlight",
                                   "com.apple.notificationcenterui",
                                   "com.apple.Siri"
        ]
        if app.activationPolicy == .regular && app.bundleIdentifier != currentAppBundleIdentifier && !excludedIdentifiers.contains(app.bundleIdentifier ?? "") {
            return false
        }
        return true
    }

    // Add any apps that are already open (and allowed to be tracked) to the list,
    // starting their idle clock from now.
    private func addCurrentRunningApps() {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        let currentDate = Date()

        for app in apps where !isBlockedApp(app) && runningApps[app] == nil
                              && !quitingPIDs.contains(app.processIdentifier) {
            runningApps[app] = currentDate
        }
    }

    // The core loop, run on the timer. One pass: refresh the list of apps, work
    // out how long each has been idle, skip the ones we must leave alone or that
    // are busy, warn you, and finally quit anything past its limit.
    private func checkOpenApps() {
        let workspace = NSWorkspace.shared
        let currentDate = Date()
        lastChecked = currentDate

        // Forget any apps that have since quit on their own.
        let running = Set(workspace.runningApplications)
        runningApps = runningApps.filter { running.contains($0.key) }
        let runningPIDs = Set(running.map(\.processIdentifier))
        warnedAt = warnedAt.filter { runningPIDs.contains($0.key) }   // drop warnings for dead pids

        // Stop tracking anything that now belongs on the safety list.
        for app in runningApps.keys.filter({ isBlockedApp($0) }) {
            runningApps[app] = nil
        }

        // The app you're using right now counts as active — reset its idle clock.
        if let activeApp = workspace.frontmostApplication, !isBlockedApp(activeApp) {
            runningApps[activeApp] = currentDate
        }

        // Pick up any newly opened apps.
        addCurrentRunningApps()

        // Drop the rows whose process is gone. The footprint itself is only read
        // while a window is open: summing an app's helper processes means scanning
        // every process on the system, which isn't worth doing every minute.
        memoryUsage = memoryUsage.filter { runningPIDs.contains($0.key) }
        if windowIsOpen {
            let table = processTable()
            let paths = processPaths(for: table.allPIDs)
            let cmdlines = processCommandLines()
            for app in runningApps.keys {
                let pid = app.processIdentifier
                memoryUsage[pid] = residentMemoryIncludingResponsible(of: pid, in: table.tree,
                    for: app, paths: paths, cmdlines: cmdlines)
            }
        }

        // A pause that has run out clears itself the moment we notice.
        if let until = pauseUntil, currentDate >= until { pauseUntil = nil }

        // While paused — explicitly, or because "battery only" is on and the Mac
        // is plugged in — nothing is quit and every idle clock stands still, so
        // countdowns pick up where they left off when the pause lifts.
        onBattery = isOnBattery()
        if isPaused || PowerDecision.suppressed(batteryOnly: batteryOnlyQuit, onBattery: onBattery) {
            for app in runningApps.keys { runningApps[app] = currentDate }
            warnedAt.removeAll()   // a fresh warning round once auto-quit resumes
            return
        }

        // Find which apps are busy (unless you've turned that option off), then go
        // through everything we're tracking.
        let busy = skipBusyApps ? busyPIDs() : []
        let tracked = runningApps
        for (app, startDate) in tracked {
            let pid = app.processIdentifier
            let idle = currentDate.timeIntervalSince(startDate)
            let threshold = effectiveHours(for: app)
            // Is this app actually due to be quit? If not (still in use, opted
            // out, or just reset), clear any pending warning and move on.
            guard QuitDecision.shouldQuit(idle: idle,
                                          thresholdHours: threshold,
                                          isFinishedLaunching: app.isFinishedLaunching,
                                          optedOut: !willAutoQuit(app))
            else { warnedAt[pid] = nil; continue }   // not eligible (idle reset / opted out) → drop any warning

            // 1. Busy (media, downloads, holding the Mac awake) → skip, don't reset the timer.
            if skipBusyApps && busy.contains(pid) {
                log.debug("Skipped \(app.localizedName ?? "?", privacy: .public) — busy (idle \(Int(idle))s)")
                continue
            }

            // 2. Warn first; quit only after the grace period lapses with no reprieve.
            if warnBeforeQuit && !notificationsDenied {
                if let warned = warnedAt[pid] {
                    if currentDate.timeIntervalSince(warned) < warningGrace { continue }
                } else {
                    warnedAt[pid] = currentDate
                    warn(app)
                    log.notice("Warned \(app.localizedName ?? "?", privacy: .public) (\(Int(self.warningGrace))s grace)")
                    continue
                }
            }

            // 3. Execute the expiry action (quit, or quit-and-restart). Keep the
            // rule: only stop tracking on a successful terminate.
            let action = effectiveAction(for: app)
            if performExpiryAction(for: app) {
                log.notice("\(action == .restart ? "Restarted" : "Quit", privacy: .public) \(app.localizedName ?? "?", privacy: .public) — idle \(Int(idle))s ≥ \(threshold)h")
            } else {
                log.error("Quit FAILED for \(app.localizedName ?? "?", privacy: .public) — idle \(Int(idle))s")
            }
        }
    }

    // Terminate the app and carry out its expiry action: just quit, or quit and
    // relaunch it straight afterwards. Returns whether the terminate call was
    // accepted, and posts the "freed memory" notice when that's switched on.
    private func performExpiryAction(for app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let name = app.localizedName
        let bundleURL = app.bundleURL
        // memoryUsage is only kept fresh while a window is open, so fall back to
        // a fresh read — including helper processes and other responsible subprocesses,
        // to match what the row showed.
        let table = processTable()
        let paths = processPaths(for: table.allPIDs)
        let cmdlines = processCommandLines()
        let freedBytes = memoryUsage[pid] ?? residentMemoryIncludingResponsible(of: pid, in: table.tree,
            for: app, paths: paths, cmdlines: cmdlines) ?? 0
        let wantsRestart = effectiveAction(for: app) == .restart && bundleURL != nil

        let accepted: Bool
        if forceQuit {
            accepted = app.forceTerminate()
        } else {
            accepted = app.terminate()
            // Graceful requests can be intercepted (e.g. "Save & Quit?" dialogs),
            // in which case the app keeps running and would be re-added to tracking
            // with a fresh idle clock on the next tick, effectively immortal. Watch
            // for that: after a short grace the app should be gone, and if it isn't
            // we escalate to a force quit. Tracking it in quitingPIDs also keeps
            // addCurrentRunningApps from putting it back while we wait.
            quitingPIDs.insert(pid)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                DispatchQueue.main.async {
                    self.quitingPIDs.remove(pid)
                    let stillRunning = NSWorkspace.shared.runningApplications
                        .contains { $0.processIdentifier == pid }
                    if stillRunning {
                        self.log.error("Graceful quit stuck for \(name ?? "?", privacy: .public) (pid \(pid)) — force-quitting")
                        _ = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?
                            .forceTerminate() ?? false
                    }
                }
            }
        }
        guard accepted else { return false }

        runningApps[app] = nil
        warnedAt[pid] = nil
        memoryUsage[pid] = nil

        if wantsRestart, let bundleURL {
            relaunch(name: name, bundleURL: bundleURL)
        }
        if notifyFreedMemory && !notificationsDenied {
            notifyOutcome(name: name, freedBytes: freedBytes, restarted: wantsRestart)
        }
        return true
    }

    // Bring an app back once its old instance has really exited. The quit takes
    // a moment, so poll briefly before opening it again; give up with a log line
    // if the old instance hangs around.
    private func relaunch(name: String?, bundleURL: URL) {
        let deadline = Date().addingTimeInterval(15)
        func poll() {
            let stillRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleURL == bundleURL }
            if stillRunning, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
                return
            }
            if stillRunning {
                log.error("Relaunch of \(name ?? bundleURL.lastPathComponent, privacy: .public) aborted — old instance never exited")
                return
            }
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                if let error {
                    self?.log.error("Relaunch of \(name ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self?.log.notice("Relaunched \(name ?? "?", privacy: .public)")
                }
            }
        }
        poll()
    }

    // The after-the-fact notice: "Quit Xcode — freed 1.2 GB of memory."
    private func notifyOutcome(name: String?, freedBytes: Int, restarted: Bool) {
        let appName = name ?? AppLocale.L("an app")
        let content = UNMutableNotificationContent()
        content.title = restarted
            ? AppLocale.Lf("Restarted %@", appName)
            : AppLocale.Lf("Quit %@", appName)
        content.body = AppLocale.Lf("Freed %@ of memory.", MemoryFormat.short(freedBytes))
        content.sound = .default
        let request = UNNotificationRequest(identifier: "autoquit.outcome.\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Quit warning (UserNotifications). Delegate is the manager itself; wired in AutoQuitApp.

    // Set up the two buttons that appear on the warning notice: "Keep" (leave the
    // app running) and "Quit now".
    func registerNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let keep = UNNotificationAction(
            identifier: "KEEP",
            title: AppLocale.L("Keep"),
            options: [])
        let quitNow = UNNotificationAction(
            identifier: "QUIT_NOW",
            title: AppLocale.L("Quit now"),
            options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.warningCategory, actions: [keep, quitNow],
                                   intentIdentifiers: [], options: [])
        ])
    }

    // Post the heads-up that an app is about to be quit. The very first time this
    // is needed it asks your permission to send notifications; if you decline,
    // AutoQuit simply quits idle apps without warning from then on.
    private func warn(_ app: NSRunningApplication) {
        let content = UNMutableNotificationContent()
        content.title = AppLocale.Lf("Quitting %@", app.localizedName ?? AppLocale.L("an app"))
        content.body = effectiveAction(for: app) == .restart
            ? AppLocale.Lf("Idle too long — restarting in %lld seconds. Keep it open?", Int(warningGrace))
            : AppLocale.Lf("Idle too long — closing in %lld seconds. Keep it open?", Int(warningGrace))
        content.sound = .default
        content.categoryIdentifier = Self.warningCategory
        content.userInfo = ["toggleKey": app.toggleKey, "pid": Int(app.processIdentifier)]
        let request = UNNotificationRequest(identifier: app.toggleKey, content: content, trigger: nil)

        let center = UNUserNotificationCenter.current()
        guard !notificationAuthChecked else { center.add(request); return }
        // Lazy first-time authorization. Denial falls back to quitting without a
        // warning. The flag is set up front so a burst of warnings can't each
        // trigger their own permission prompt.
        notificationAuthChecked = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error {
                    self?.log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
                if granted {
                    center.add(request)
                } else {
                    self?.notificationsDenied = true
                    self?.log.notice("Notifications denied — quitting without warning")
                }
            }
        }
    }

    // Show the warning as a banner even while AutoQuit is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Handle your tap on the warning: "Quit now" quits immediately, while "Keep"
    // (or tapping the notice itself) resets the idle clock so the app stays open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let pid = pid_t(info["pid"] as? Int ?? -1)
        DispatchQueue.main.async { [weak self] in
            guard let self else { completionHandler(); return }
            let app = self.runningApps.keys.first { $0.processIdentifier == pid }
            switch response.actionIdentifier {
            case "QUIT_NOW":
                // Honors a per-app restart choice — "Quit now" means "do it now".
                if let app { _ = self.performExpiryAction(for: app) }
                self.warnedAt[pid] = nil
            case "KEEP", UNNotificationDefaultActionIdentifier:
                if let app { self.runningApps[app] = Date() }   // reset idle timer, like the row's reset button
                self.warnedAt[pid] = nil
            default:
                break   // dismissed/ignored → leave warnedAt so the grace period proceeds to quit
            }
            completionHandler()
        }
    }
}

private extension View {
    @ViewBuilder
    func glassCard<S: InsettableShape>(_ shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.quaternary, lineWidth: 1) }
        }
    }
}

// The popover that drops down from the menu-bar icon: the list of tracked apps
// (or a friendly empty state), with Settings and Quit buttons at the bottom.
struct ContentView: View {
    @ObservedObject private var manager: RunningAppsManager
    @ObservedObject private var locale = AppLocale.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("batteryOnlyQuit") private var batteryOnlyQuit = false

    init(manager: RunningAppsManager) {
        self.manager = manager
    }

    // Sorted by total footprint (the app + its helper processes), largest first.
    // Apps that haven't been measured yet fall to the bottom; ties break by name
    // so the list stays deterministic even between refreshes.
    private var sortedApps: [NSRunningApplication] {
        manager.runningApps.keys.sorted {
            let a = manager.memoryUsage[$0.processIdentifier] ?? 0
            let b = manager.memoryUsage[$1.processIdentifier] ?? 0
            if a != b { return a > b }
            return ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            if manager.runningApps.isEmpty {
                EmptyTrackingView()
            } else {
                appList
            }
            footer
        }
        .frame(width: 400)
    }

    // The strip above the list, shown only while auto-quit is standing down:
    // an explicit pause (with its remaining time and a Resume button), or the
    // "battery only" hold-off while the Mac is plugged in.
    @ViewBuilder
    private var statusBar: some View {
        if manager.isPaused {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(AppLocale.L("Auto-quit paused"))
                        .font(.callout)
                        .fontWeight(.medium)
                    Spacer(minLength: 4)
                    Text(IdleTime.short(Int(max(0, manager.pauseUntil?.timeIntervalSince(context.date) ?? 0))))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button(AppLocale.L("Resume")) { manager.resume() }
                        .buttonStyle(.borderless)
                        .help(AppLocale.L("Start auto-quitting idle apps again"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
        } else if powerSuppressed {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(AppLocale.L("On power — auto-quit paused"))
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }

    // "Only on battery" is switched on and the Mac is plugged in (or has no
    // battery at all): auto-quit holds off until it's running on battery again.
    private var powerSuppressed: Bool {
        PowerDecision.suppressed(batteryOnly: batteryOnlyQuit, onBattery: manager.onBattery)
    }

    private var appList: some View {
        // Redraw once a second so every countdown stays live while the menu is open.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let apps = sortedApps
            let list = VStack(spacing: 2) {
                ForEach(apps, id: \.self) { app in
                    AppRow(app: app,
                           lastActive: manager.runningApps[app] ?? context.date,
                           now: context.date,
                           manager: manager)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(8)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                       value: apps.map(\.processIdentifier))

            // Cap the scrollable list at two-thirds the screen height; grow inline until apps would exceed it.
            let maxHeight = (NSScreen.main?.frame.height ?? 800) * 2 / 3
            let contentHeight = CGFloat(apps.count) * 46 + 16   // ponytail: ~46pt/row estimate (name + memory line); retune if AppRow height changes
            if contentHeight > maxHeight {
                ScrollView { list }.frame(height: maxHeight)
            } else {
                list
            }
        }
    }

    private var footer: some View {
        Group {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 6) {
                    VStack(spacing: 6) {
                        commandButton(LocalizedStringKey(AppLocale.L("Close all selected")), "xmark.circle") { closeSelected(force: false) }
                            .disabled(!hasSelection)
                        commandButton(LocalizedStringKey(AppLocale.L("Force close all selected")), "xmark.octagon", iconColor: .red) { closeSelected(force: true) }
                            .disabled(!hasSelection)
                        pauseMenu
                        commandButton(LocalizedStringKey(AppLocale.L("Settings")), "gearshape") { SettingsWindowController.show() }
                        commandButton(LocalizedStringKey(AppLocale.L("Quit AutoQuit")), "power") { NSApplication.shared.terminate(nil) }
                    }
                }
            } else {
                VStack(spacing: 2) {
                    MenuCommandButton(title: LocalizedStringKey(AppLocale.L("Close all selected")), systemImage: "xmark.circle") {
                        closeSelected(force: false)
                    }
                    .disabled(!hasSelection)
                    MenuCommandButton(title: LocalizedStringKey(AppLocale.L("Force close all selected")), systemImage: "xmark.octagon", iconColor: .red) {
                        closeSelected(force: true)
                    }
                    .disabled(!hasSelection)
                    pauseMenu
                    MenuCommandButton(title: LocalizedStringKey(AppLocale.L("Settings")), systemImage: "gearshape") {
                        SettingsWindowController.show()
                    }
                    MenuCommandButton(title: LocalizedStringKey(AppLocale.L("Quit AutoQuit")), systemImage: "power") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .padding(8)
    }

    // "Pause auto-quit" styled exactly like its footer siblings. On macOS 26 the
    // row is a real glass Button (same construction as the Settings button, so the
    // rendering is pixel-identical) and the three durations are presented as a
    // native NSMenu anchored at the mouse — SwiftUI has no glass MenuStyle, and a
    // hand-drawn glass card on a Menu label can't match the button style's shape
    // and hover behavior. On older macOS both branches share the same hover row.
    @ViewBuilder
    private var pauseMenu: some View {
        if #available(macOS 26, *) {
            Button {
                openPauseMenu()
            } label: {
                footerLabel(LocalizedStringKey(AppLocale.L("Pause auto-quit")), "pause.circle")
            }
            .buttonStyle(.glass)
            .accessibilityLabel(Text(AppLocale.L("Pause auto-quit")))
            .help(AppLocale.L("Pause auto-quit for a while — nothing is quit until you resume"))
        } else {
            MenuCommandMenu(title: "Pause auto-quit", systemImage: "pause.circle") {
                pauseItems
            }
        }
    }

    // Presents the pause durations as a native menu right where the user clicked.
    private func openPauseMenu() {
        let target = PauseMenuTarget(manager: manager)
        let menu = NSMenu(title: AppLocale.L("Pause auto-quit"))
        menu.autoenablesItems = false
        let entries: [(String, Selector)] = [
            (AppLocale.L("For 1 hour"), #selector(PauseMenuTarget.pauseOneHour)),
            (AppLocale.L("For 4 hours"), #selector(PauseMenuTarget.pauseFourHours)),
            (AppLocale.L("Until tomorrow morning"), #selector(PauseMenuTarget.pauseTomorrowMorning)),
        ]
        for (title, selector) in entries {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        // `in: nil` interprets the point in screen coordinates; the button action
        // fires on mouse-up, so the mouse is still over the row that was clicked.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @ViewBuilder
    private var pauseItems: some View {
        Button(AppLocale.L("For 1 hour")) { manager.pause(for: 3600) }
        Button(AppLocale.L("For 4 hours")) { manager.pause(for: 4 * 3600) }
        Button(AppLocale.L("Until tomorrow morning")) { manager.pauseUntilTomorrowMorning() }
    }

    /// One row of the footer: icon + title, full width, uniform padding. Shared by
    /// the glass buttons and the "Pause auto-quit" menu so they look identical.
    private func footerLabel(_ title: LocalizedStringKey, _ systemImage: String,
                             iconColor: Color? = nil) -> some View {
        Label {
            Text(title)
        } icon: {
            if let iconColor {
                Image(systemName: systemImage).foregroundStyle(iconColor)
            } else {
                Image(systemName: systemImage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
    }

    @available(macOS 26, *)
    private func commandButton(_ title: LocalizedStringKey, _ systemImage: String,
                               iconColor: Color? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            footerLabel(title, systemImage, iconColor: iconColor)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(Text(title))
    }

    private var hasSelection: Bool {
        manager.runningApps.keys.contains { manager.willAutoQuit($0) }
    }

    private func closeSelected(force: Bool) {
        for app in Array(manager.runningApps.keys) where manager.willAutoQuit(app) {
            _ = force ? app.forceTerminate() : app.terminate()
        }
        // No manual cleanup: the 1s timer in RunningAppsManager prunes apps that
        // have quit, same as the per-row close buttons rely on.
    }
}

// NSMenu target for the pause durations (macOS 26 footer). NSMenuItem's
// target/action needs an NSObject; the actual pause logic lives on the manager.
private final class PauseMenuTarget: NSObject {
    private let manager: RunningAppsManager
    init(manager: RunningAppsManager) { self.manager = manager }

    @objc func pauseOneHour() { manager.pause(for: 3600) }
    @objc func pauseFourHours() { manager.pause(for: 4 * 3600) }
    @objc func pauseTomorrowMorning() { manager.pauseUntilTomorrowMorning() }
}

// A row-style button used in the popover footer on older macOS versions.
private struct MenuCommandButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var iconColor: Color? = nil
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                if let iconColor {
                    Image(systemName: systemImage).foregroundStyle(iconColor)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Color.white : Color.primary)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityLabel(Text(title))
    }
}

// A row-style Menu for the popover footer on older macOS versions: identical
// look to MenuCommandButton, so "Pause auto-quit" matches its siblings.
private struct MenuCommandMenu<Items: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let items: Items
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: LocalizedStringKey, systemImage: String, @ViewBuilder items: () -> Items) {
        self.title = title
        self.systemImage = systemImage
        self.items = items()
    }

    var body: some View {
        Menu {
            items
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(isHovering ? Color.white : Color.primary)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityLabel(Text(title))
    }
}

// The friendly placeholder shown when there are no apps to track yet.
private struct EmptyTrackingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 76, height: 76)
                .glassCard(Circle())
            VStack(spacing: 4) {
                Text(AppLocale.L("No apps to track"))
                    .font(.headline)
                Text(AppLocale.L("Apps you open appear here with a countdown until they’re auto-quit."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

// The custom look of the on/off switch shown next to each app.
private struct AutoQuitToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private let trackW: CGFloat = 32
        private let trackH: CGFloat = 18
        private let knob: CGFloat = 14

        var body: some View {
            let on = configuration.isOn
            Button {
                configuration.isOn.toggle()
            } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? AnyShapeStyle(Color.accentColor.gradient)
                            : AnyShapeStyle(Color.primary.opacity(0.16)))
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(on ? 0 : 0.07), lineWidth: 0.5)
                        }
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                        .padding(2)
                        .scaleEffect(hovering ? 1.08 : 1)
                }
                .frame(width: trackW, height: trackH)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: on)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

// One row in the popover for a single app: its on/off switch, icon, name, the
// countdown pill (which also opens a menu to set a custom limit), a reset button,
// and an optional quit-now button.
struct AppRow: View {
    let app: NSRunningApplication
    let lastActive: Date
    let now: Date
    @ObservedObject var manager: RunningAppsManager
    @AppStorage("forceQuit") private var forceQuit = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayName: String {
        app.localizedName ?? AppLocale.L("Unknown")
    }
    private var willQuit: Bool { manager.willAutoQuit(app) }

    private var secondsLeft: Int {
        max(0, Int(manager.effectiveHours(for: app) * 3600 - now.timeIntervalSince(lastActive)))
    }

    private var shouldQuitCheckbox: Binding<Bool> {
        Binding(
            get: { manager.willAutoQuit(app) },
            set: { newValue in
                manager.toggleStatus[app.toggleKey] = newValue
            }
        )
    }

    // 0 = "use the global default"; any other value is a per-app override.
    private var globalTimeout: Double { manager.hoursUntilClose }

    private var globalTimeoutLabel: String {
        globalTimeout == 0.5 ? "30 min" : "\(Int(globalTimeout))h"
    }

    private var defaultTimeoutText: String {
        if globalTimeout == 0.5 {
            return AppLocale.L("Use default (30 min)")
        }
        return AppLocale.Lf("Use default (%lldh)", Int(globalTimeout))
    }

    private var timeoutBinding: Binding<Double> {
        Binding(
            get: { manager.perAppHours[app.toggleKey] ?? 0 },
            set: { manager.perAppHours[app.toggleKey] = $0 == 0 ? nil : $0 }
        )
    }

    // The per-app expiry action ("quit" / "restart"). Only stored when it
    // differs from the default, so the saved list stays small.
    private var expiryActionBinding: Binding<String> {
        Binding(
            get: { manager.perAppActions[app.toggleKey] ?? AppAction.quit.rawValue },
            set: { newValue in
                manager.perAppActions[app.toggleKey] = newValue == AppAction.quit.rawValue ? nil : newValue
            }
        )
    }

    private var statusColor: Color {
        guard willQuit else { return .secondary }
        if secondsLeft <= 300 { return .red }
        if secondsLeft <= 3600 { return .orange }
        return .secondary
    }

    private var statusText: String {
        willQuit
            ? IdleTime.short(secondsLeft)
            : AppLocale.L("Excluded")
    }

    private var statusAccessibility: String {
        willQuit
            ? AppLocale.Lf("Quits in %@", IdleTime.verbose(secondsLeft))
            : AppLocale.L("Excluded from auto-quit")
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: shouldQuitCheckbox) {
                Text(AppLocale.Lf("Auto-quit %@", displayName))
            }
            .toggleStyle(AutoQuitToggleStyle())
            .help(willQuit ? AppLocale.Lf("Stop auto-quitting %@", displayName) : AppLocale.Lf("Auto-quit %@ when idle", displayName))

            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .opacity(willQuit ? 1 : 0.5)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(willQuit ? .primary : .secondary)
                if let total = manager.memoryUsage[app.processIdentifier] {
                    Text(MemoryFormat.short(total))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(AppLocale.Lf("%@ uses %@ of memory, including helper processes", displayName, MemoryFormat.short(total)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Picker(AppLocale.L("Idle timeout"), selection: timeoutBinding) {
                    Text(defaultTimeoutText).tag(0.0)
                    Text(AppLocale.L("30 min")).tag(0.5)
                    // ponytail: fixed timeout choices; no custom-value entry unless asked
                    ForEach([1, 2, 4, 8, 12, 24, 48], id: \.self) { Text(AppLocale.Lf("%lldh", $0)).tag(Double($0)) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker(AppLocale.L("When timer ends"), selection: expiryActionBinding) {
                    Text(AppLocale.L("Quit")).tag(AppAction.quit.rawValue)
                    Text(AppLocale.L("Restart")).tag(AppAction.restart.rawValue)
                }
                .pickerStyle(.inline)
            } label: {
                CountdownPill(text: statusText,
                              color: statusColor,
                              accessibility: statusAccessibility,
                              symbol: willQuit && manager.effectiveAction(for: app) == .restart
                                  ? "arrow.triangle.2.circlepath" : nil)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: statusColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(AppLocale.Lf("Set how long %@ can stay idle before quitting, and whether it is quit or restarted", displayName))

            Button {
                manager.runningApps[app] = Date()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!willQuit)
            .help(AppLocale.Lf("Reset the idle timer for %@", displayName))
            .accessibilityLabel(AppLocale.Lf("Reset idle timer for %@", displayName))

            Button {
                app.terminate()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help(AppLocale.Lf("Quit %@", displayName))
            .accessibilityLabel(AppLocale.Lf("Quit %@", displayName))

            Button {
                app.forceTerminate()
            } label: {
                Image(systemName: "xmark.octagon")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(AppLocale.Lf("Force quit %@ — discards unsaved changes", displayName))
            .accessibilityLabel(AppLocale.Lf("Force quit %@ — discards unsaved changes", displayName))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// The small colored pill showing the time left (or "Excluded"). Apps set to
// restart get a little ↻ symbol so that choice is visible at a glance.
private struct CountdownPill: View {
    let text: String
    let color: Color
    let accessibility: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.callout)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .accessibilityLabel(accessibility)
    }
}

// Turns a number of seconds into short, readable text like "2h" or "45s".
enum IdleTime {
    // Locale-aware duration rendering. Behavior preserved from the old hand-rolled
    // version: show seconds only when under a minute, otherwise hours/minutes with
    // zero units dropped. We pre-truncate to whole minutes so the formatter never
    // rounds 1h0m59s up to "1h 1m" (integer division did the same before).
    // `locale` defaults to the user's current locale (the UI wants that); tests pin
    // it to en_US so the asserted strings are deterministic on any host/CI.
    private static func format(_ seconds: Int, width: Duration.UnitsFormatStyle.UnitWidth,
                               locale: Locale) -> String {
        let s = max(0, seconds)
        if s < 60 {
            return Duration.seconds(s).formatted(
                .units(allowed: [.seconds], width: width, zeroValueUnits: .show(length: 1))
                    .locale(locale))
        }
        let wholeMinutes = (s / 60) * 60
        return Duration.seconds(wholeMinutes).formatted(
            .units(allowed: [.hours, .minutes], width: width).locale(locale))
    }

    static func short(_ seconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        format(seconds, width: .narrow, locale: locale)
    }
    static func verbose(_ seconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        format(seconds, width: .wide, locale: locale)
    }
}

// Manages the Settings window. It remembers the one already open, so clicking
// Settings again just brings it back to the front instead of opening a second.
class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var current: SettingsWindowController?

    convenience init(rootView: SettingsView) {
        // Fit the window to its content, but never taller than two-thirds of the screen.
        // fixedSize stops the grouped Form greedily filling, so sizeThatFits reports the real content height.
        let cap = (NSScreen.main?.frame.height ?? 800) * 2 / 3
        let ideal = NSHostingController(
            rootView: rootView.frame(width: 480).fixedSize(horizontal: false, vertical: true)
        ).sizeThatFits(in: CGSize(width: 480, height: CGFloat.greatestFiniteMagnitude)).height
        let hostingController = NSHostingController(rootView: rootView.frame(width: 480, height: min(ideal, cap)))
        let window = NSWindow(contentViewController: hostingController)
        window.title = AppLocale.L("Settings")
        self.init(window: window)
        window.delegate = self
        SettingsWindowController.current = self
    }

    // Open Settings (or re-focus it if already open). While it's open the app
    // briefly takes on a normal Dock presence so the window can come forward.
    static func show() {
        NSApp.setActivationPolicy(.regular)
        let existing = current
        let controller = existing ?? SettingsWindowController(rootView: SettingsView())
        if existing != nil, let window = controller.window {
            // Swap in a fresh view on reopen: settings live in @AppStorage, and a
            // fresh identity re-reads live state (e.g. the login toggle), which may
            // have changed elsewhere since the window was last open.
            let size = window.contentViewController?.view.frame.size ?? CGSize(width: 480, height: 480)
            window.contentViewController = NSHostingController(
                rootView: SettingsView().frame(width: size.width, height: size.height))
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // When Settings closes, slip back to menu-bar-only (no Dock icon).
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    deinit {
        // Only clear the slot if it still points at us — replacing `current`
        // deallocated this controller, and must not clobber its successor.
        if SettingsWindowController.current === self {
            SettingsWindowController.current = nil
        }
    }
}

// The Settings window's contents: launch-at-login, the idle timeout, and the
// options for how idle apps are handled.
struct SettingsView: View {
    @ObservedObject private var locale = AppLocale.shared
    @AppStorage("hoursUntilClose") private var hoursUntilClose = AppDefaults.hoursUntilClose
    @AppStorage("forceQuit") private var forceQuit = false
    @AppStorage("skipBusyApps") private var skipBusyApps = true
    @AppStorage("warnBeforeQuit") private var warnBeforeQuit = true
    @AppStorage("batteryOnlyQuit") private var batteryOnlyQuit = false
    @AppStorage("notifyFreedMemory") private var notifyFreedMemory = true

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var appBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            Form {
                Section(AppLocale.L("General")) {
                    LaunchAtLoginToggle()
                }

                Section {
                    Picker(AppLocale.L("Language"), selection: $locale.language) {
                        ForEach(Array(AppLocale.choices), id: \.id) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                    }
                } header: {
                    Text(AppLocale.L("Language"))
                } footer: {
                    Text(AppLocale.L("Choose English or Simplified Chinese. The change applies immediately."))
                }

                Section {
                    Picker(AppLocale.L("Idle timeout"), selection: $hoursUntilClose) {
                        ForEach(Self.idleTimeouts, id: \.self) { hours in
                            Text(hours == 0.5 ? AppLocale.L("30 min") : AppLocale.Lf("%lldh", Int(hours))).tag(hours)
                        }
                    }
                } header: {
                    Text(AppLocale.L("Idle timeout"))
                } footer: {
                    Text(AppLocale.L("Set per-app exceptions from the menu bar list."))
                }

                Section {
                    Toggle(AppLocale.L("Don’t quit busy apps"), isOn: $skipBusyApps)
                    Toggle(AppLocale.L("Warn before quitting"), isOn: $warnBeforeQuit)
                    Toggle(AppLocale.L("Only quit on battery power"), isOn: $batteryOnlyQuit)
                } header: {
                    Text(AppLocale.L("When idle"))
                } footer: {
                    Text(AppLocale.L("“Busy” means playing media, downloading, or keeping the Mac awake. A warning lets you keep an app before it’s quit. With “battery only”, auto-quit stands down while the Mac is plugged in; idle clocks resume where they left off."))
                }

                Section {
                    Toggle(AppLocale.L("Force quit without saving"), isOn: $forceQuit)
                    Toggle(AppLocale.L("Notify about freed memory"), isOn: $notifyFreedMemory)
                } header: {
                    Text(AppLocale.L("Quitting"))
                } footer: {
                    Text(forceQuit
                        ? AppLocale.L("Force quit ends apps immediately and discards unsaved changes.")
                        : AppLocale.L("Apps are asked to quit normally, so you can save your work. Per app, the countdown menu also offers quit-and-restart instead of plain quitting."))
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: locale.language) { _ in
            NSApp.keyWindow?.title = AppLocale.L("Settings")
        }
    }

    // Fixed preset order for the Idle timeout picker.
    private static let idleTimeouts: [Double] = [0.5, 1, 2, 4, 8, 12, 24, 48]

    private var hero: some View {
        HStack(spacing: 14) {
            Image("Image")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocale.L("AutoQuit"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(AppLocale.Lf("Version %@ (%@)", appVersion, appBuildNumber))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(manager: runningAppsManager)
    }
}

// The "Launch at login" switch. Flipping it asks macOS to start (or stop
// starting) AutoQuit automatically when you log in.
struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle(AppLocale.L("Launch at login"), isOn: Binding(
            get: { isEnabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    isEnabled = newValue
                } catch {
                    isEnabled = SMAppService.mainApp.status == .enabled
                }
            }
        ))
    }
}
