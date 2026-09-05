// AutoQuit's starting point. When the app launches this builds the menu-bar
// icon and hands everything off to the engine that watches your apps. There's
// almost nothing here on purpose — the real work lives in ContentView.swift.

import SwiftUI
import Combine
import AppKit

// The app's single "brain", created once and shared everywhere. It keeps track
// of every running app and decides when to quit the idle ones.
let runningAppsManager = RunningAppsManager()

// The menu-bar icon: the normal timer glyph, or a pause symbol while auto-quit
// is paused, so the state is visible at a glance without opening the popover.
private struct MenuBarLabel: View {
    @ObservedObject var manager: RunningAppsManager

    var body: some View {
        if manager.isPaused {
            Image(systemName: "pause.circle")
        } else {
            // 18×18, marked as a "template" image so macOS recolors it to match
            // the menu bar in both light and dark mode.
            let image: NSImage = {
                $0.size.height = 18
                $0.size.width = 18
                $0.isTemplate = true
                return $0
            }(NSImage(named: "MenuBarIcon")!)

            Image(nsImage: image)
        }
    }
}

// A thin wrapper around the popover content that forces a re-render when the
// in-app language changes. MenuBarExtra evaluates its content closure once and
// keeps the resulting view alive but hidden while the popover is closed, so
// neither App-scene updates nor (while hidden) objectWillChange reach the stale
// strings. This wrapper listens for AppLocale's notification and bumps its
// `.id`, making SwiftUI discard the old content and rebuild it with fresh
// strings — even while the popover window is hidden.
private struct LocalePopover: View {
    @State private var language = AppLocale.shared.language
    let manager: RunningAppsManager

    var body: some View {
        ContentView(manager: manager)
            .id(language)
            .onReceive(NotificationCenter.default.publisher(for: .appLocaleDidChange)) { _ in
                language = AppLocale.shared.language
            }
    }
}

// The app itself. It lives only in the menu bar — no Dock icon, no main window.
@main
struct AutoQuitApp: App {
    init() {
        // Prepare the "Keep" / "Quit now" buttons shown on the warning notice.
        runningAppsManager.registerNotifications()
    }

    var body: some Scene {
        // The menu-bar icon; clicking it opens the popover (LocalePopover).
        MenuBarExtra {
            LocalePopover(manager: runningAppsManager)
        } label: {
            MenuBarLabel(manager: runningAppsManager)
        }
        .menuBarExtraStyle(.window)
    }
}
