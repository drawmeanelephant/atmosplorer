import AppKit
import SwiftUI

@main
struct AtmosplorerApp: App {
    init() {
        // SPM executables ship without an app bundle, so nothing claims
        // regular-app activation; without this the window opens behind other
        // apps and there's no menu bar. Claiming `.regular` here makes the
        // bare binary behave like a real app. (A future packaging milestone
        // can move this into a proper .app bundle.)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Atmosplorer") {
            RootView()
        }
        .defaultSize(width: 1000, height: 640)
    }
}
