// SWeftApp.swift - SWeft Application Entry Point

import SwiftUI
import AppKit

@main
struct SWeftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .navigationTitle("WEFT 0.2.1")
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1400, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set activation policy to regular app (shows in Dock and menu bar)
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app and bring to front
        NSApp.activate(ignoringOtherApps: true)

        // Make sure the main window becomes key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
