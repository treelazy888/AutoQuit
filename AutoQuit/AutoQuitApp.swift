// AutoQuit's starting point. When the app launches this builds the menu-bar
// icon and hands everything off to the engine that watches your apps. There's
// almost nothing here on purpose — the real work lives in ContentView.swift.

import SwiftUI
import Combine
import AppKit

// The app's single "brain", created once and shared everywhere. It keeps track
// of every running app and decides when to quit the idle ones.
let runningAppsManager = RunningAppsManager()

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
    private let popover = NSPopover()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
            button.image = icon(paused: manager.isPaused)
            button.target = self
            button.action = #selector(togglePopover)
        }

        // Mirror the paused state on the menu-bar icon (isPaused is derived
        // from @Published properties, so objectWillChange covers it).
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let button = self.statusItem.button else { return }
                button.image = self.icon(paused: self.manager.isPaused)
            }
            .store(in: &cancellables)
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
