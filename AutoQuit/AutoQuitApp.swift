// AutoQuit's starting point. When the app launches this builds the menu-bar
// icon and hands everything off to the engine that watches your apps. There's
// almost nothing here on purpose — the real work lives in ContentView.swift.

import SwiftUI
import Combine
import AppKit

// The app's single "brain", created once and shared everywhere. It keeps track
// of every running app and decides when to quit the idle ones.
let runningAppsManager = RunningAppsManager()

// Live CPU/memory readings for the menu-bar text. Refreshed every 2 seconds.
// CPU temperature would be the natural left value, but macOS 26 blocks SMC
// sensor reads for third-party apps (every AppleSMC call returns
// kIOReturnBadArgument), so the bottom-left shows CPU usage instead.
final class SystemStats: ObservableObject {
    @Published var cpuUsage = 0
    @Published var memoryPressure = 0
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

        // Memory pressure: share of RAM in active use (total minus free and
        // cached-inactive pages), matching the "memory used" reading.
        var stats = vm_statistics64()
        var pageCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let memResult = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(pageCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &pageCount)
            }
        }
        if memResult == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            let total = ProcessInfo.processInfo.physicalMemory
            let free = UInt64(stats.free_count) * UInt64(pageSize)
            let inactive = UInt64(stats.inactive_count) * UInt64(pageSize)
            let used = Int(total) - Int(free + inactive)
            memoryPressure = max(0, min(100, used * 100 / Int(total)))
        }
    }
}

// Draws the live 2×2 CPU/MEM readout in the status item and forwards clicks
// to the popover toggle. A custom AppKit view (rather than SwiftUI in an
// NSHostingView) because hosting views inside a status button swallow real
// mouse events — the toggle silently stopped working.
private final class MenuBarStatsNSView: NSView {
    var onToggle: (() -> Void)? { didSet { needsDisplay = true } }
    var cpuUsage = 0 { didSet { needsDisplay = true } }
    var memoryPressure = 0 { didSet { needsDisplay = true } }


    override func draw(_ dirtyRect: NSRect) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let columns: [(String, String)] = [("CPU", "\(cpuUsage)%"), ("MEM", "\(memoryPressure)%")]
        let colWidth = bounds.width / 2
        for (index, (label, value)) in columns.enumerated() {
            let x = bounds.minX + CGFloat(index) * colWidth
            let labelSize = (label as NSString).size(withAttributes: labelAttrs)
            let valueSize = (value as NSString).size(withAttributes: valueAttrs)
            (label as NSString).draw(
                at: NSPoint(x: x + (colWidth - labelSize.width) / 2,
                            y: bounds.maxY - labelSize.height - 1),
                withAttributes: labelAttrs)
            (value as NSString).draw(
                at: NSPoint(x: x + (colWidth - valueSize.width) / 2, y: bounds.minY + 1),
                withAttributes: valueAttrs)
        }
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Owns the menu-bar status item and its popover; created once at launch and
// kept alive for the whole run (touched from AutoQuitApp.init).
let popoverController = PopoverController(manager: runningAppsManager)

// Owns the menu-bar status item and its popover. Built on AppKit instead of
// MenuBarExtra on purpose: MenuBarExtra evaluates its content closure once and
// keeps the resulting view alive but hidden afterwards, so an in-app language
// change could never reach the closed popover (several SwiftUI approaches —
// @ObservedObject, scene ids, an isInserted toggle, a change notification —
// all failed on exactly that). Here the content view controller is rebuilt
// fresh right before every show, so the popover always renders the current
// language — the same reason the Settings window (also NSHostingController
// based) updates live.
final class PopoverController: NSObject, NSPopoverDelegate {
    private let manager: RunningAppsManager
    private let stats = SystemStats()
    private let popover = NSPopover()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 76)
    private var statsView: MenuBarStatsNSView?
    private var cancellables = Set<AnyCancellable>()

    // Clicking the status item while the popover is open dismisses it first
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

        if let button = statusItem.button {
            button.image = nil
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "CPU / MEM"
        }
        updateButtonContent()

        // Mirror the paused state on the menu-bar item (isPaused is derived
        // from @Published properties, so objectWillChange covers it).
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButtonContent() }
            .store(in: &cancellables)

        // Push live readings into the drawn view.
        stats.$cpuUsage.combineLatest(stats.$memoryPressure)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cpu, mem in
                self?.statsView?.cpuUsage = cpu
                self?.statsView?.memoryPressure = mem
            }
            .store(in: &cancellables)
    }

    // The menu-bar item shows live CPU/MEM text; while auto-quit is paused it
    // swaps back to the pause glyph so the stand-down state stays visible.
    private func updateButtonContent() {
        guard let button = statusItem.button else { return }
        if manager.isPaused {
            statsView?.removeFromSuperview()
            statsView = nil
            statusItem.length = NSStatusItem.variableLength
            button.image = icon(paused: true)
            return
        }
        button.image = nil
        statusItem.length = 76
        if statsView == nil {
            let view = MenuBarStatsNSView(frame: NSRect(x: 0, y: 0, width: 76, height: 24))
            view.autoresizingMask = [.width, .height]
            view.onToggle = { [weak self] in self?.togglePopover() }
            button.addSubview(view)
            statsView = view
        }
    }

    private func icon(paused: Bool) -> NSImage? {
        if paused {
            return NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")
        }
        let image = NSImage(named: "MenuBarIcon")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        return image
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if let lastCloseDate, Date().timeIntervalSince(lastCloseDate) < 0.15 { return }

        // Rebuild on every show so the strings match the current language.
        // A half-strength window background over NSPopover's default material
        // dials the transparency down a notch: less see-through than the bare
        // popover, lighter than the fully-opaque background tried in 1.2.4.
        // Tune the 0.5 to taste — 0 = original, 1 = fully opaque.
        let controller = NSHostingController(rootView: ContentView(manager: manager)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5)))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller

        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitors()
            // The popover's window doesn't reliably become key, so tell the
            // manager directly — it only measures memory while "a window is
            // open" and would otherwise never measure again after a relaunch.
            manager.popoverIsOpen = true
        }
    }

    // Any mouse-down that isn't on the popover itself, the status item (that's
    // the toggle), or one of our popup menus (the pause menu anchors to the
    // popover) closes the popover. Global monitors cover clicks in other apps;
    // local ones cover clicks in our own windows.
    private func installOutsideClickMonitors() {
        guard outsideClickMonitors.isEmpty else { return }
        outsideClickMonitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            // Global events carry no window — a click on our own status item
            // also arrives here (win=nil) and must be exempted, or the same
            // click that toggles the popover would instantly close it. The
            // click position (bottom-left global coords) tells us where it
            // actually landed.
            if let self, let button = self.statusItem.button,
               let win = button.window,
               win.frame.contains(NSEvent.mouseLocation) {
                return
            }
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
        if let button = statusItem.button, clickedWindow === button.window { return }
        if clickedWindow === popover.contentViewController?.view.window { return }
        if clickedWindow?.className.contains("Menu") == true { return }
        popover.performClose(nil)
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseDate = Date()
        removeOutsideClickMonitors()
        manager.popoverIsOpen = false
    }
}

// The app itself. It lives only in the menu bar — no Dock icon, no main window.
@main
struct AutoQuitApp: App {
    init() {
        // Touch the global so the status item exists from launch on, and
        // prepare the "Keep" / "Quit now" buttons shown on the warning notice.
        _ = popoverController
        runningAppsManager.registerNotifications()
    }

    // The real UI lives in the status item (PopoverController above) and the
    // custom Settings window; this placeholder scene just satisfies the App
    // protocol.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
