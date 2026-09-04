// AutoQuit's starting point. When the app launches this builds the menu-bar
// icon and hands everything off to the engine that watches your apps. There's
// almost nothing here on purpose — the real work lives in ContentView.swift.

import SwiftUI
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

// The app itself. It lives only in the menu bar — no Dock icon, no main window.
@main
struct AutoQuitApp: App {
    // Observed so the whole scene re-renders when the user switches language.
    @ObservedObject private var locale = AppLocale.shared

    init() {
        // Prepare the "Keep" / "Quit now" buttons shown on the warning notice.
        runningAppsManager.registerNotifications()
    }

    var body: some Scene {
        // The menu-bar icon; clicking it opens the popover (ContentView).
        // `isInserted` is toggled off and on when the language changes, so
        // SwiftUI recreates the menu-bar extra and its cached popover content
        // with fresh strings. The binding ignores writes from MenuBarExtra so
        // it can't trigger a re-creation loop.
        MenuBarExtra(
            isInserted: Binding(
                get: { locale.isInserted },
                set: { _ in }  // ignore MenuBarExtra's writes
            )
        ) {
            ContentView(manager: runningAppsManager)
        } label: {
            MenuBarLabel(manager: runningAppsManager)
        }
        .menuBarExtraStyle(.window)
    }
}
