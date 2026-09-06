// AutoQuit's starting point. When the app launches this builds the menu-bar
// tiles and hands everything off to the engine that watches your apps. The
// real work lives in ContentView.swift.

import SwiftUI
import Combine
import AppKit

// The app's single "brain", created once and shared everywhere. It keeps track
// of every running app and decides when to quit the idle ones.
let runningAppsManager = RunningAppsManager()

// Owns the menu-bar tiles; created once at launch and kept alive for the whole
// run (touched from AutoQuitApp.init).
let popoverController = PopoverController(manager: runningAppsManager)

// One menu-bar tile: label ("CPU"/"MEM"/"GPU") on top, live value below.
// A custom AppKit view — SwiftUI hosting views inside a status button
// swallow real mouse events, so the tile handles its own clicks.
final class MenuBarStatItemView: NSView {
    var onToggle: (() -> Void)?
    var label: String { didSet { needsDisplay = true } }
    var value: String = "--" { didSet { needsDisplay = true } }

    init(label: String) {
        self.label = label
        super.init(frame: NSRect(x: 0, y: 0, width: 46, height: 24))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        let valueSize = (value as NSString).size(withAttributes: valueAttrs)
        (label as NSString).draw(
            at: NSPoint(x: bounds.midX - labelSize.width / 2,
                        y: bounds.maxY - labelSize.height - 1),
            withAttributes: labelAttrs)
        (value as NSString).draw(
            at: NSPoint(x: bounds.midX - valueSize.width / 2, y: bounds.minY + 1),
            withAttributes: valueAttrs)
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class SMCTemperatureSensor {
    static let shared = SMCTemperatureSensor()
    private var conn: io_connect_t = 0
    private var ready = false
    // Thermal sensor keys ported from ThermalForge (MIT), verified across
    // M1-M5. Missing keys on a given machine simply return nil and are skipped.
    private let cpuKeys: [String] = [
        // aggregate (M5 Max verified)
        "TCDX", "TCHP", "TCMb",
        // per-core (Tp prefix, M1-M5)
        "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
        "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
        "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b",
    ] + (0...31).map { String(format: "Tp%02X", $0) }
    private let gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
                           "TG0B", "TG0H", "TG0V"]

    struct SMCKeyData_t {
        typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                UInt8, UInt8, UInt8, UInt8)
        struct vers_t {
            var major: CUnsignedChar = 0
            var minor: CUnsignedChar = 0
            var build: CUnsignedChar = 0
            var reserved: CUnsignedChar = 0
            var release: CUnsignedShort = 0
        }
        struct LimitData_t {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }
        struct keyInfo_t {
            var dataSize: IOByteCount32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }
        var key: UInt32 = 0
        var vers = vers_t()
        var pLimitData = LimitData_t()
        var keyInfo = keyInfo_t()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                 UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                 UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                 UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                 UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                                 UInt8(0), UInt8(0))
    }

    init() {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { return }
        defer { IOObjectRelease(device) }
        var newConn: io_connect_t = 0
        if IOServiceOpen(device, mach_task_self_, 0, &newConn) == KERN_SUCCESS {
            conn = newConn
            ready = true
        }
    }
    deinit { if ready { IOServiceClose(conn) } }

    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }

    private func readKey(_ key: String) -> (bytes: [UInt8], type: String)? {
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        input.data8 = 9   // readKeyInfo
        guard call(2, input: &input, output: &output) == kIOReturnSuccess, output.result == 0,
              Int(output.keyInfo.dataSize) > 0 else { return nil }
        let typeInt = output.keyInfo.dataType.bigEndian
        let type = String(format: "%c%c%c%c",
                          UInt8(truncatingIfNeeded: typeInt >> 24),
                          UInt8(truncatingIfNeeded: typeInt >> 16),
                          UInt8(truncatingIfNeeded: typeInt >> 8),
                          UInt8(truncatingIfNeeded: typeInt))
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5   // readBytes
        guard call(2, input: &input, output: &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        let t = output.bytes
        return ([t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, t.8, t.9, t.10, t.11,
                 t.12, t.13, t.14, t.15, t.16, t.17, t.18, t.19, t.20, t.21,
                 t.22, t.23, t.24, t.25, t.26, t.27, t.28, t.29, t.30, t.31], type)
    }

    private func value(_ key: String) -> Double? {
        guard let (bytes, type) = readKey(key) else { return nil }
        return Self.decodeTemp(bytes: bytes, type: type)
    }

    // Decode a sensor value. The type string's byte order varies (a 4-char code
    // stored little-endian reads back reversed — "sp78" as "87ps", "flt " as
    // " tlf"), so match by character SET, not by literal.
    static func decodeTemp(bytes: [UInt8], type: String) -> Double? {
        let chars = Set(type)
        if chars == Set("sp78") || chars == Set("sp87") {
            return Double(Int16(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        }
        if chars == Set("flt ") {
            var f: Float = 0
            withUnsafeMutableBytes(of: &f) { dst in
                for i in 0..<4 { dst[i] = bytes[i] }
            }
            return (0...150).contains(Double(f)) ? Double(f) : nil
        }
        if chars == Set("ui8 ") { return Double(bytes[0]) }
        if chars == Set("ioft") {
            // 8-byte IOKit fixed point: first 4 bytes = 16.16 little-endian
            let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            let v = Double(raw >> 16) + Double(raw & 0xFFFF) / 65536.0
            return (0...150).contains(v) ? v : nil
        }
        return nil
    }

    private func peak(_ keys: [String]) -> Double? {
        guard ready else { return nil }
        var best: Double?
        for key in keys {
            if let v = value(key), (10...125).contains(v) {
                best = max(best ?? 0, v)
            }
        }
        return best
    }

    // Peak CPU temperature across the aggregate + per-core + hex-sweep sensors.
    func cpuTemperature() -> Double? { peak(cpuKeys) }
    // Peak GPU temperature.
    func gpuTemperature() -> Double? { peak(gpuKeys) }
}


// Live CPU/memory readings for the menu-bar tiles. Refreshed every 2 seconds.
final class SystemStats: ObservableObject {
    @Published var cpuUsage = 0
    @Published var memoryPressure = 0
    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?
    private var prevUser: UInt32 = 0
    private var prevSys: UInt32 = 0
    private var prevIdle: UInt32 = 0
    private var prevNice: UInt32 = 0
    private var hasPrev = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        // CPU/GPU temperature: peak of the readable sensors per domain.
        cpuTemperature = SMCTemperatureSensor.shared.cpuTemperature()
        gpuTemperature = SMCTemperatureSensor.shared.gpuTemperature()

        // CPU usage: ticks since the last refresh, all cores pooled.
        var countIn: mach_msg_type_number_t = 0
        var countOut: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                               &countIn, &cpuInfo, &countOut) == KERN_SUCCESS,
           let ticks = cpuInfo {
            var user: UInt32 = 0, sys: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0
            for i in 0..<Int(countOut) {
                let base = i * Int(CPU_STATE_MAX)
                user = user &+ UInt32(ticks[base + Int(CPU_STATE_USER)])
                sys = sys &+ UInt32(ticks[base + Int(CPU_STATE_SYSTEM)])
                idle = idle &+ UInt32(ticks[base + Int(CPU_STATE_IDLE)])
                nice = nice &+ UInt32(ticks[base + Int(CPU_STATE_NICE)])
            }
            let dUser = user &- prevUser, dSys = sys &- prevSys
            let dIdle = idle &- prevIdle, dNice = nice &- prevNice
            let dTotal = dUser &+ dSys &+ dIdle &+ dNice
            if hasPrev, dTotal > 0 {
                cpuUsage = Int((Double(dUser &+ dSys &+ dNice) / Double(dTotal)) * 100)
            }
            prevUser = user; prevSys = sys; prevIdle = idle; prevNice = nice
            hasPrev = true
            let size = vm_size_t(countOut) * vm_size_t(MemoryLayout<processor_cpu_load_info_data_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: ticks), size)
        }

        // Memory pressure: the system's own metric — kern.memorystatus_level
        // (0-100, the "free" share Apple's memory_pressure tool prints), so the
        // percentage matches what macOS itself reports. Pressure = 100 - level.
        var level: Int32 = -1
        var levelSize: Int = 0
        if sysctlbyname("kern.memorystatus_level", nil, &levelSize, nil, 0) == 0, levelSize >= 4 {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: levelSize, alignment: 4)
            defer { buffer.deallocate() }
            if sysctlbyname("kern.memorystatus_level", buffer, &levelSize, nil, 0) == 0 {
                level = buffer.assumingMemoryBound(to: Int32.self).pointee
            }
        }
        if level >= 0 {
            memoryPressure = max(0, min(100, 100 - Int(level)))
        }
    }
}

// Owns the three menu-bar tiles (CPU / MEM / GPU) and the popover. Built on
// AppKit tiles instead of MenuBarExtra on purpose: MenuBarExtra evaluates its
// content closure once and keeps the resulting view alive but hidden, so an
// in-app language change could never reach the closed popover. Each tile is a
// custom AppKit view that draws its own 2-line readout and forwards clicks —
// SwiftUI hosting views inside a status button swallow real mouse events.
final class PopoverController: NSObject, NSPopoverDelegate {
    private let manager: RunningAppsManager
    private let stats = SystemStats()
    private let popover = NSPopover()
    // Created right-to-left so the tiles read CPU | MEM | GPU left-to-right.
    private let cpuItem = NSStatusBar.system.statusItem(withLength: 48)
    private let memItem = NSStatusBar.system.statusItem(withLength: 48)
    private let gpuItem = NSStatusBar.system.statusItem(withLength: 48)
    private var tiles: [MenuBarStatItemView] = []
    private var cancellables = Set<AnyCancellable>()

    // Clicking a tile while the popover is open dismisses it first
    // (transient behavior) and then runs this action, which would immediately
    // reopen it. Remember the close time and ignore a reopen within a beat, so
    // that click reads as "close" instead of "close + reopen".
    private var lastCloseDate: Date?

    // NSPopover's built-in transient dismissal is unreliable for a status item
    // in an accessory app (clicks in other apps often don't dismiss it), so
    // outside clicks are watched explicitly while the popover is shown.
    private var outsideClickMonitors: [Any] = []

    init(manager: RunningAppsManager) {
        self.manager = manager
        super.init()

        popover.behavior = .transient
        popover.delegate = self

        // Create tiles right-to-left: GPU first (ends up rightmost), then MEM,
        // then CPU — so the menu bar reads CPU | MEM | GPU.
        let definitions: [(NSStatusItem, String)] = [(gpuItem, "GPU"), (memItem, "MEM"), (cpuItem, "CPU")]
        for (item, label) in definitions {
            guard let button = item.button else { continue }
            button.image = nil
            button.target = self
            button.action = #selector(togglePopover)
            let tile = MenuBarStatItemView(label: label)
            tile.frame = NSRect(x: 0, y: 0, width: 48, height: 24)
            tile.autoresizingMask = [.width, .height]
            tile.onToggle = { [weak self] in self?.togglePopover() }
            button.addSubview(tile)
            tiles.append(tile)
        }

        // While paused, the CPU tile swaps to the pause glyph and the other
        // tiles collapse (isPaused is derived from @Published properties, so
        // objectWillChange covers it).
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePausedUI() }
            .store(in: &cancellables)

        // Push live readings into the tiles.
        stats.$cpuUsage.combineLatest(stats.$memoryPressure, stats.$cpuTemperature, stats.$gpuTemperature)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cpuUsage, mem, temp, gpu in
                guard let self, self.tiles.count == 3 else { return }
                // CPU tile shows the core-average temperature in Celsius; usage
                // % is the fallback when the sensors are unreadable.
                self.tiles[2].value = temp.map { String(Int($0.rounded())) + "°" }
                    ?? "\(cpuUsage)%"
                self.tiles[1].value = "\(mem)%"
                self.tiles[0].value = gpu.map { String(Int($0.rounded())) + "°" } ?? "--"
            }
            .store(in: &cancellables)
    }

    private func icon(paused: Bool) -> NSImage? {
        return NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")
    }

    // While auto-quit is paused: the CPU tile swaps to the pause glyph and the
    // MEM/GPU tiles collapse so the stand-down state stays obvious.
    private func updatePausedUI() {
        let paused = manager.isPaused
        if paused {
            for tile in tiles { tile.removeFromSuperview() }
            memItem.length = 0
            gpuItem.length = 0
            cpuItem.length = NSStatusItem.variableLength
            cpuItem.button?.image = icon(paused: true)
        } else {
            cpuItem.button?.image = nil
            memItem.length = 48
            gpuItem.length = 48
            cpuItem.length = 48
            for tile in tiles where tile.superview == nil {
                let button: NSButton? = {
                    switch tile.label {
                    case "CPU": return cpuItem.button
                    case "MEM": return memItem.button
                    default: return gpuItem.button
                    }
                }()
                if let button { button.addSubview(tile) }
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if let lastCloseDate, Date().timeIntervalSince(lastCloseDate) < 0.15 { return }

        // Rebuild on every show so the strings match the current language.
        let controller = NSHostingController(rootView: ContentView(manager: manager))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller

        if let button = cpuItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitors()
        }
    }

    // Any mouse-down that isn't on a tile, a status item (that's the toggle),
    // or one of our popup menus closes the popover. Global monitors cover
    // clicks in other apps; local ones cover clicks in our own windows.
    private func installOutsideClickMonitors() {
        guard outsideClickMonitors.isEmpty else { return }
        outsideClickMonitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissForOutsideClick(clickedWindow: nil)
        })
        outsideClickMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.dismissForOutsideClick(clickedWindow: event.window)
            return event
        })
    }

    private func dismissForOutsideClick(clickedWindow: NSWindow?) {
        guard popover.isShown else {
            removeOutsideClickMonitors()
            return
        }
        // Clicks on any of our three status items are the toggle/exempt.
        let itemButtons = [cpuItem.button, memItem.button, gpuItem.button]
        if let clickedWindow, itemButtons.contains(where: { $0 === clickedWindow }) { return }
        if clickedWindow === popover.contentViewController?.view.window { return }
        if clickedWindow?.className.contains("Menu") == true { return }
        // Global events carry no window: a click inside our own status item's
        // frame must be exempt too (checked by position).
        if clickedWindow == nil, let button = cpuItem.button, let win = button.window,
           win.frame.contains(NSEvent.mouseLocation) { return }
        popover.performClose(nil)
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseDate = Date()
        removeOutsideClickMonitors()
    }
}

// The app itself. It lives only in the menu bar — no Dock icon, no main window.
@main
struct AutoQuitApp: App {
    init() {
        // Touch the global so the tiles exist from launch on, and prepare the
        // "Keep" / "Quit now" buttons shown on the warning notice.
        _ = popoverController
        runningAppsManager.registerNotifications()
    }

    // The real UI lives in the status items (PopoverController above) and the
    // custom Settings window; this placeholder scene just satisfies the App
    // protocol.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
