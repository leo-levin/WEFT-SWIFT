// WEFTApp.swift - WEFT Application Entry Point

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WEFTLib

@main
struct WEFTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            FileCommands()
            PanelCommands()
            HelpCommands()
        }
    }
}

// MARK: - File Commands (File Menu)

struct FileCommands: Commands {
    @FocusedValue(\.viewModel) var viewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                viewModel?.newFile()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open...") {
                viewModel?.openFile()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                viewModel?.saveFile()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As...") {
                viewModel?.saveFileAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Divider()

            Button("View Stdlib") {
                revealStdlibInFinder()
            }
        }
    }

    private func revealStdlibInFinder() {
        // Use the stdlib URL exposed by WEFTLib
        if let stdlibURL = WeftStdlib.directoryURL {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: stdlibURL.path)
        } else {
            let alert = NSAlert()
            alert.messageText = "Stdlib Not Found"
            alert.informativeText = "Could not locate the stdlib directory in the bundle."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// MARK: - Focused Value Key for ViewModel

struct ViewModelKey: FocusedValueKey {
    typealias Value = WeftViewModel
}

// MARK: - Panel Commands (View Menu)

struct PanelCommands: Commands {
    @FocusedBinding(\.showGraph) var showGraph
    @FocusedBinding(\.showErrors) var showErrors
    @FocusedBinding(\.showStats) var showStats
    @FocusedBinding(\.showDevMode) var showDevMode
    @FocusedBinding(\.graphPanelMode) var graphPanelMode

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Section {
                Toggle("Graph", isOn: Binding(
                    get: { showGraph ?? true },
                    set: { showGraph = $0 }
                ))
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Toggle("Loom View", isOn: Binding(
                    get: { graphPanelMode == .loom },
                    set: { newValue in
                        graphPanelMode = newValue ? .loom : .graph
                        if newValue { showGraph = true }
                    }
                ))
                .keyboardShortcut("d", modifiers: [.command, .option])

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

                Divider()

                Toggle("Dev Mode", isOn: Binding(
                    get: { showDevMode ?? false },
                    set: { showDevMode = $0 }
                ))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Help Commands (Help Menu)

struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("WEFT Documentation") {
                if let url = URL(string: "https://weft.notion.site") {
                    NSWorkspace.shared.open(url)
                }
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

struct ShowDevModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct GraphPanelModeKey: FocusedValueKey {
    typealias Value = Binding<GraphPanelMode>
}

extension FocusedValues {
    var viewModel: WeftViewModel? {
        get { self[ViewModelKey.self] }
        set { self[ViewModelKey.self] = newValue }
    }

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

    var showDevMode: Binding<Bool>? {
        get { self[ShowDevModeKey.self] }
        set { self[ShowDevModeKey.self] = newValue }
    }

    var graphPanelMode: Binding<GraphPanelMode>? {
        get { self[GraphPanelModeKey.self] }
        set { self[GraphPanelModeKey.self] = newValue }
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
