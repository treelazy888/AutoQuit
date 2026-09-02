import XCTest
@testable import AutoQuit

final class AutoQuitTests: XCTestCase {

    // MARK: Idle/terminate boundary (the "quit too early / too late" surface)

    func testShouldQuitBoundary() {
        let hours = 8
        let threshold = Double(hours * 3600)
        XCTAssertFalse(QuitDecision.shouldQuit(idle: threshold - 1, thresholdHours: hours,
                                               isFinishedLaunching: true, optedOut: false))
        XCTAssertFalse(QuitDecision.shouldQuit(idle: threshold, thresholdHours: hours,
                                               isFinishedLaunching: true, optedOut: false),
                       "exactly at the threshold must not quit (strict >)")
        XCTAssertTrue(QuitDecision.shouldQuit(idle: threshold + 1, thresholdHours: hours,
                                              isFinishedLaunching: true, optedOut: false))
    }

    func testShouldQuitRespectsOptOutAndLaunchState() {
        let over = Double(8 * 3600) + 60
        XCTAssertFalse(QuitDecision.shouldQuit(idle: over, thresholdHours: 8,
                                               isFinishedLaunching: true, optedOut: true),
                       "an opted-out app must never be quit")
        XCTAssertFalse(QuitDecision.shouldQuit(idle: over, thresholdHours: 8,
                                               isFinishedLaunching: false, optedOut: false),
                       "an app that hasn't finished launching must never be quit")
    }

    // MARK: Per-app timeout resolution

    func testEffectiveHoursResolution() {
        // Per-app override wins over the global timeout.
        XCTAssertEqual(QuitDecision.effectiveHours(perApp: ["com.x": 4], key: "com.x", global: 8), 4)
        // No override for this key → falls back to the global timeout.
        XCTAssertEqual(QuitDecision.effectiveHours(perApp: [:], key: "com.x", global: 8), 8)
        XCTAssertEqual(QuitDecision.effectiveHours(perApp: ["com.y": 4], key: "com.x", global: 8), 8)
        // Excluded app never quits, whatever its effective timeout resolves to.
        let hours = QuitDecision.effectiveHours(perApp: [:], key: "com.x", global: 8)
        XCTAssertFalse(QuitDecision.shouldQuit(idle: hours * 3600 + 60, thresholdHours: hours,
                                               isFinishedLaunching: true, optedOut: true),
                       "an excluded app must never quit regardless of its effective timeout")

        // Sub-hour choices are doubles, not fractions of an Int hour.
        XCTAssertEqual(QuitDecision.effectiveHours(perApp: ["com.x": 0.5], key: "com.x", global: 8), 0.5)
        // A per-app 30-minute limit actually binds at 1800s, not 0s.
        let half = QuitDecision.effectiveHours(perApp: ["com.x": 0.5], key: "com.x", global: 8)
        XCTAssertFalse(QuitDecision.shouldQuit(idle: 1800, thresholdHours: half,
                                               isFinishedLaunching: true, optedOut: false),
                       "exactly at a 30-minute limit must not quit (strict >)")
        XCTAssertTrue(QuitDecision.shouldQuit(idle: 1801, thresholdHours: half,
                                              isFinishedLaunching: true, optedOut: false),
                      "just past a 30-minute limit must quit")
    }

    // MARK: Countdown formatting
    //
    // IdleTime uses a locale-aware Duration formatter, so the tests pin en_US to keep
    // the asserted strings deterministic on any host/CI (an unpinned locale makes
    // nl/fr/de/en_CA hosts produce "1 m"/"1min" and fail). The behavior contract being
    // verified: seconds appear only under a minute, and zero units are dropped (no
    // "1h 0m"). The boundary points (0, 59, 60, 3600, 3661) are called out in the spec.

    private let en = Locale(identifier: "en_US")

    func testIdleTimeShort() {
        XCTAssertEqual(IdleTime.short(0, locale: en), "0s")
        XCTAssertEqual(IdleTime.short(59, locale: en), "59s")
        XCTAssertEqual(IdleTime.short(60, locale: en), "1m")
        XCTAssertEqual(IdleTime.short(3600, locale: en), "1h")
        XCTAssertEqual(IdleTime.short(3661, locale: en), "1h 1m")
        XCTAssertEqual(IdleTime.short(7 * 3600 + 32 * 60, locale: en), "7h 32m")
        XCTAssertEqual(IdleTime.short(8 * 3600, locale: en), "8h")
        XCTAssertEqual(IdleTime.short(45 * 60, locale: en), "45m")
        XCTAssertEqual(IdleTime.short(3600 + 59, locale: en), "1h", "leftover seconds under a minute are dropped, not rounded up")
        XCTAssertEqual(IdleTime.short(-100, locale: en), "0s")
    }

    func testIdleTimeVerbose() {
        XCTAssertEqual(IdleTime.verbose(0, locale: en), "0 seconds")
        XCTAssertEqual(IdleTime.verbose(59, locale: en), "59 seconds")
        XCTAssertEqual(IdleTime.verbose(60, locale: en), "1 minute")
        XCTAssertEqual(IdleTime.verbose(3600, locale: en), "1 hour")
        XCTAssertEqual(IdleTime.verbose(3600 + 60, locale: en), "1 hour, 1 minute")
        XCTAssertEqual(IdleTime.verbose(2 * 3600 + 5 * 60, locale: en), "2 hours, 5 minutes")
    }

    // MARK: Pause ("do not disturb")

    func testPauseDecision() {
        let now = Date()
        XCTAssertFalse(PauseDecision.isPaused(now: now, until: nil), "no pause set → not paused")
        XCTAssertTrue(PauseDecision.isPaused(now: now, until: now.addingTimeInterval(1)))
        XCTAssertFalse(PauseDecision.isPaused(now: now, until: now.addingTimeInterval(-1)),
                       "an expired pause must not hold")
        XCTAssertFalse(PauseDecision.isPaused(now: now, until: now),
                       "a pause ending exactly now is already over (strict <)")
    }

    func testNextMorning() {
        // UTC calendar so the assertions don't depend on the host's time zone.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }

        // Before 9:00 → today's 9:00.
        XCTAssertEqual(PauseDecision.nextMorning(after: date(2026, 8, 30, 8), hour: 9, calendar: cal),
                       date(2026, 8, 30, 9))
        // After 9:00 → tomorrow's 9:00.
        XCTAssertEqual(PauseDecision.nextMorning(after: date(2026, 8, 30, 10), hour: 9, calendar: cal),
                       date(2026, 8, 31, 9))
        // Exactly 9:00 is not "still ahead" (a zero-length pause would be useless) → tomorrow.
        XCTAssertEqual(PauseDecision.nextMorning(after: date(2026, 8, 30, 9), hour: 9, calendar: cal),
                       date(2026, 8, 31, 9))
        // Month rollover.
        XCTAssertEqual(PauseDecision.nextMorning(after: date(2026, 8, 31, 23), hour: 9, calendar: cal),
                       date(2026, 9, 1, 9))
    }

    // MARK: Power ("only on battery")

    func testPowerDecisionSuppressed() {
        // Option off → never suppressed, whatever the power source.
        XCTAssertFalse(PowerDecision.suppressed(batteryOnly: false, onBattery: false))
        XCTAssertFalse(PowerDecision.suppressed(batteryOnly: false, onBattery: true))
        // Option on → suppressed exactly while not on battery (plugged in, or a
        // desktop Mac with no battery at all).
        XCTAssertTrue(PowerDecision.suppressed(batteryOnly: true, onBattery: false))
        XCTAssertFalse(PowerDecision.suppressed(batteryOnly: true, onBattery: true))
    }

    // MARK: Memory formatting
    //
    // Binary units (1 GB = 1024 MB), one decimal only once we're in gigabytes.
    // Locale pinned to en_US for the same reason as IdleTime above.

    func testMemoryFormat() {
        XCTAssertEqual(MemoryFormat.short(0, locale: en), "0 MB")
        XCTAssertEqual(MemoryFormat.short(200 * 1024 * 1024, locale: en), "200 MB")
        XCTAssertEqual(MemoryFormat.short(512 * 1024 * 1024, locale: en), "512 MB")
        XCTAssertEqual(MemoryFormat.short(1024 * 1024 * 1024, locale: en), "1 GB")
        XCTAssertEqual(MemoryFormat.short(Int(1.5 * 1024 * 1024 * 1024), locale: en), "1.5 GB")
        XCTAssertEqual(MemoryFormat.short(2 * 1024 * 1024 * 1024, locale: en), "2 GB")
    }

    // Single summary figure per app; one decimal in gigabytes.

    func testMemoryFormatShort() {
        XCTAssertEqual(MemoryFormat.short(211 * 1024 * 1024, locale: en), "211 MB")
        XCTAssertEqual(MemoryFormat.short(2100 * 1024 * 1024, locale: en), "2.1 GB")
        XCTAssertEqual(MemoryFormat.short(0, locale: en), "0 MB")
    }

    // MARK: Per-app expiry action (quit vs. quit-and-restart)

    func testEffectiveActionResolution() {
        // Default: quit.
        XCTAssertEqual(QuitDecision.effectiveAction(perApp: [:], key: "com.x"), .quit)
        // Per-app override wins.
        XCTAssertEqual(QuitDecision.effectiveAction(perApp: ["com.x": "restart"], key: "com.x"), .restart)
        // Another app's override doesn't leak.
        XCTAssertEqual(QuitDecision.effectiveAction(perApp: ["com.y": "restart"], key: "com.x"), .quit)
        // Unknown stored values (older/wrong data) fall back to quit.
        XCTAssertEqual(QuitDecision.effectiveAction(perApp: ["com.x": "bogus"], key: "com.x"), .quit)
        // The action never gates the quit decision itself — a restart app is quit
        // when overdue too; the restart is layered on top.
        XCTAssertTrue(QuitDecision.shouldQuit(idle: Double(8 * 3600) + 60, thresholdHours: 8,
                                              isFinishedLaunching: true, optedOut: false))
    }

    // MARK: Process tree walk
    //
    // An app's footprint includes the helper processes it spawned — that's where
    // Electron-style apps keep most of their memory. The walk is pure, so the pid
    // scan that feeds it stays in the manager. Order isn't significant, hence the
    // Set comparisons.

    func testProcessTreeAllPIDs() {
        // 100 → 200 and 300, and 200 → 500 (two levels deep).
        let tree: [pid_t: [pid_t]] = [
            100: [200, 300],
            200: [500],
            999: [888],
        ]

        // The root is included, and descendants are followed as deep as they go.
        let all = ProcessTree.allPIDs(of: 100, in: tree)
        XCTAssertEqual(Set(all), Set([100, 200, 300, 500]))
        XCTAssertEqual(all.count, 4)   // no process counted twice

        // A process without children is just itself.
        XCTAssertEqual(Set(ProcessTree.allPIDs(of: 300, in: tree)), Set([300]))

        // Other parts of the tree don't leak in.
        XCTAssertEqual(Set(ProcessTree.allPIDs(of: 999, in: tree)), Set([999, 888]))
        XCTAssertEqual(Set(ProcessTree.allPIDs(of: 4242, in: tree)), Set([4242]))
    }
}
