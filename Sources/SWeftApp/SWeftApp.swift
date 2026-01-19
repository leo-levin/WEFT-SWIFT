// SWeftApp.swift - SWeft Application Entry Point

import SwiftUI
import AppKit

@main
struct SWeftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .navigationTitle("WEFT")
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            PanelCommands()
        }
    }
}

// MARK: - Panel Commands (View Menu)

struct PanelCommands: Commands {
    @FocusedBinding(\.showGraph) var showGraph
    @FocusedBinding(\.showErrors) var showErrors
    @FocusedBinding(\.showStats) var showStats

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Section {
                Toggle("Graph", isOn: Binding(
                    get: { showGraph ?? true },
                    set: { showGraph = $0 }
                ))
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Toggle("Errors", isOn: Binding(
                    get: { showErrors ?? true },
                    set: { showErrors = $0 }
                ))
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Toggle("Stats Overlay", isOn: Binding(
                    get: { showStats ?? true },
                    set: { showStats = $0 }
                ))
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
    }
}

// MARK: - Focused Values for Panel State

struct ShowGraphKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct ShowErrorsKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct ShowStatsKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var showGraph: Binding<Bool>? {
        get { self[ShowGraphKey.self] }
        set { self[ShowGraphKey.self] = newValue }
    }

    var showErrors: Binding<Bool>? {
        get { self[ShowErrorsKey.self] }
        set { self[ShowErrorsKey.self] = newValue }
    }

    var showStats: Binding<Bool>? {
        get { self[ShowStatsKey.self] }
        set { self[ShowStatsKey.self] = newValue }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
