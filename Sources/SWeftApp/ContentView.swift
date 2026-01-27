// ContentView.swift - Main application view with WEFT editor

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SWeftLib

struct ContentView: View {
    @StateObject private var viewModel = WeftViewModel()
    @State private var showGraph = true
    @State private var showErrors = true
    @State private var showStats = true
    @State private var showDevMode = false
    @State private var devModeTab: DevModeTab = .ir

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            SubtleDivider(.horizontal)
            mainContent
        }
        .onAppear {
            viewModel.loadExample(.gradient)
        }
        .focusedSceneValue(\.viewModel, viewModel)
        .focusedSceneValue(\.showGraph, $showGraph)
        .focusedSceneValue(\.showErrors, $showErrors)
        .focusedSceneValue(\.showStats, $showStats)
        .focusedSceneValue(\.showDevMode, $showDevMode)
        .navigationTitle(viewModel.documentTitle)
        .onOpenURL { url in
            viewModel.loadFile(from: url)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Spacing.sm) {
            // Status
            HStack(spacing: Spacing.xs) {
                StatusIndicator(status: viewModel.hasError ? .error : (viewModel.isRunning ? .running : .stopped))
                Text(viewModel.statusText)
                    .font(.panelTitle)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Transport controls
            HStack(spacing: Spacing.xs) {
                Button {
                    viewModel.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.isRunning)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")

                Button {
                    viewModel.compileAndRun()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Run (⌘Return)")
            }

            Divider()
                .frame(height: 12)

            // Panel toggles
            HStack(spacing: Spacing.xxs) {
                ToolbarIconButton("speedometer", label: "Stats (⌥⌘S)", isActive: showStats) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showStats.toggle()
                    }
                }

                ToolbarIconButton("exclamationmark.triangle", label: "Errors (⇧⌘E)", isActive: showErrors && viewModel.hasError) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showErrors.toggle()
                    }
                }
                .opacity(viewModel.hasError ? 1 : 0.4)

                ToolbarIconButton("point.3.connected.trianglepath.dotted", label: "Graph (⇧⌘G)", isActive: showGraph) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showGraph.toggle()
                    }
                }

                Divider()
                    .frame(height: 12)

                ToolbarIconButton("hammer", label: "Dev Mode (⇧⌘D)", isActive: showDevMode) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showDevMode.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.panelHeaderBackground)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        HSplitView {
            // Left: Editor + Errors
            editorSection
                .frame(minWidth: 300, idealWidth: 400)

            // Middle: Canvas + Graph
            canvasSection
                .frame(minWidth: showDevMode ? 300 : 400)

            // Right: Dev Mode Panel (when enabled)
            if showDevMode {
                devModeSection
                    .frame(minWidth: 320, idealWidth: 400)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDevMode)
    }

    // MARK: - Dev Mode Section

    private var devModeSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: Spacing.xs) {
                Image(systemName: "hammer")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Dev Mode")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showDevMode = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.panelHeaderBackground)

            SubtleDivider(.horizontal)

            DevModeView(coordinator: viewModel.coordinator, selectedTab: $devModeTab)
                .id(viewModel.compilationVersion) // Refresh on recompile
        }
    }

    // MARK: - Editor Section

    private var editorSection: some View {
        VStack(spacing: 0) {
            CodeEditor(text: $viewModel.sourceCode)
                .id(viewModel.editorID)
                .onChange(of: viewModel.sourceCode) { _, _ in
                    viewModel.hasError = false
                }

            // Resource warning panel
            if viewModel.resourceWarning != nil && showErrors {
                SubtleDivider(.horizontal)
                resourceWarningPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Error panel
            if viewModel.hasError && showErrors {
                SubtleDivider(.horizontal)
                errorPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.hasError && showErrors)
        .animation(.easeInOut(duration: 0.15), value: viewModel.resourceWarning != nil)
    }

    private var resourceWarningPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text("Resource Warning")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()

                Button {
                    viewModel.browseForMissingResource()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text("Browse...")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.resourceWarning = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.orange.opacity(0.1))

            SubtleDivider(.horizontal)

            ScrollView {
                if let warning = viewModel.resourceWarning {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(warning)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text("Place files next to your .weft file, or use Browse to locate them.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.sm)
                }
            }
            .frame(maxHeight: 100)
        }
    }

    private var errorPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Text("Error")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation { showErrors = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.panelHeaderBackground)

            SubtleDivider(.horizontal)

            ScrollView {
                CompilationErrorView(error: viewModel.compilationError)
            }
            .frame(maxHeight: 140)
        }
    }

    // MARK: - Canvas Section

    @ObservedObject private var renderStats = RenderStats.shared

    private var canvasSection: some View {
        VStack(spacing: 0) {
            // Canvas
            canvasContent

            // Graph (or collapsed header)
            SubtleDivider(.horizontal)
            if showGraph {
                graphPanel
                    .frame(minHeight: 100, idealHeight: 140)
                    .transition(.asymmetric(
                        insertion: .push(from: .bottom),
                        removal: .push(from: .top)
                    ))
            } else {
                collapsedGraphHeader
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showGraph)
    }

    private var canvasContent: some View {
        GeometryReader { geo in
            let aspectRatio: CGFloat = 16.0 / 10.0
            let availableWidth = geo.size.width
            let availableHeight = geo.size.height
            let fittedWidth = min(availableWidth, availableHeight * aspectRatio)
            let fittedHeight = fittedWidth / aspectRatio

            ZStack {
                Color.canvasBackground

                ZStack(alignment: .topTrailing) {
                    if viewModel.hasVisual {
                        WeftMetalView(coordinator: viewModel.coordinator)

                        if showStats {
                            StatsBadge(fps: renderStats.fps, frameTime: renderStats.frameTime)
                                .padding(Spacing.sm)
                                .transition(.opacity)
                        }
                    } else {
                        EmptyStateView("play.circle", message: "Press ⌘Return to run")
                    }
                }
                .frame(width: fittedWidth, height: fittedHeight)
            }
        }
    }

    private var collapsedGraphHeader: some View {
        CollapsedPanelHeader(title: "Graph", icon: "point.3.connected.trianglepath.dotted") {
            withAnimation(.easeInOut(duration: 0.15)) {
                showGraph = true
            }
        }
    }

    private var graphPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Graph")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showGraph = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.panelHeaderBackground)

            SubtleDivider(.horizontal)

            GraphView(coordinator: viewModel.coordinator)
        }
    }
}

// MARK: - Example Programs

enum WeftExample: CaseIterable {
    case gradient
    case plasma
    case circle
    case sine
    case crossdomain

    var name: String {
        switch self {
        case .gradient: return "Gradient"
        case .plasma: return "Plasma"
        case .circle: return "Circle"
        case .sine: return "Sine Wave"
        case .crossdomain: return "Audio-Visual"
        }
    }

    var source: String {
        switch self {
        case .gradient:
            return """
            // Animated gradient
            display[r, g, b] = [me.x, me.y, fract(me.t)]
            """

        case .plasma:
            return """
            // Plasma effect
            v.x = sin(me.x * 10.0 + me.t)
            v.y = sin(me.y * 10.0 + me.t * 1.5)
            v.z = sin((me.x + me.y) * 5.0 + me.t * 2.0)
            display[r, g, b] = [
                sin(v.x + v.y) * 0.5 + 0.5,
                sin(v.y + v.z) * 0.5 + 0.5,
                sin(v.z + v.x) * 0.5 + 0.5
            ]
            """

        case .circle:
            return """
            // Circle with antialiasing
            cx.v = 0.5
            cy.v = 0.5
            radius.v = 0.3
            dx.v = me.x - cx.v
            dy.v = me.y - cy.v
            dist.v = sqrt(dx.v * dx.v + dy.v * dy.v)
            edge.v = smoothstep(radius.v + 0.01, radius.v - 0.01, dist.v)
            display[r, g, b] = [edge.v, edge.v * 0.5, edge.v * 0.8]
            """

        case .sine:
            return """
            // 440Hz sine wave
            freq.v = 440.0
            phase.v = me.i / me.sampleRate * freq.v * 6.28318
            play[0] = sin(phase.v) * 0.3
            """

        case .crossdomain:
            return """
            // Audio-reactive visual
            amp.v = abs(sin(me.t * 3.0))
            freq.v = 440.0
            phase.v = me.i / me.sampleRate * freq.v * 6.28318
            play[0] = sin(phase.v) * amp.v * 0.3
            display[r, g, b] = [amp.v, me.y, me.x]
            """
        }
    }
}

// MARK: - View Model

@MainActor
class WeftViewModel: ObservableObject {
    @Published var coordinator = Coordinator()
    @Published var sourceCode = "" {
        didSet {
            if sourceCode != oldValue {
                isDirty = true
            }
        }
    }
    @Published var statusText = "Ready (Swift)"
    @Published var errorMessage = ""
    @Published var compilationError = CompilationError(message: "", location: nil, codeContext: [])
    @Published var hasVisual = false
    @Published var hasAudio = false
    @Published var isAudioPlaying = false
    @Published var hasError = false
    @Published var isRunning = false
    @Published var resourceWarning: String? = nil

    // Dev mode state - increments on each compile to trigger view refresh
    @Published var compilationVersion = 0

    // File state
    @Published var currentFileURL: URL? = nil
    @Published var isDirty: Bool = false
    @Published var editorID = UUID()  // Changes to force editor refresh

    var documentTitle: String {
        let filename = currentFileURL?.lastPathComponent ?? "Untitled"
        return isDirty ? "\(filename) \u{2022}" : filename
    }

    private let compiler = WeftCompiler()

    init() {
        // Native Swift compiler - no initialization needed
    }

    // MARK: - File Operations

    func newFile() {
        stop()
        sourceCode = ""
        currentFileURL = nil
        isDirty = false
        editorID = UUID()
        errorMessage = ""
        hasError = false
        statusText = "Ready (Swift)"
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "weft")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a WEFT file to open"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.loadFile(from: url)
            }
        }
    }

    func loadFile(from url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            stop()
            sourceCode = content
            currentFileURL = url
            isDirty = false
            editorID = UUID()
            errorMessage = ""
            hasError = false
            statusText = "Ready (Swift)"
        } catch {
            showFileError("Failed to open file: \(error.localizedDescription)")
        }
    }

    func saveFile() {
        if let url = currentFileURL {
            writeFile(to: url)
        } else {
            saveFileAs()
        }
    }

    func saveFileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "weft")!]
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Untitled.weft"
        panel.message = "Save your WEFT file"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.writeFile(to: url)
            }
        }
    }

    private func writeFile(to url: URL) {
        do {
            try sourceCode.write(to: url, atomically: true, encoding: .utf8)
            currentFileURL = url
            isDirty = false
        } catch {
            showFileError("Failed to save file: \(error.localizedDescription)")
        }
    }

    private func showFileError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "File Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func loadExample(_ example: WeftExample) {
        stop()
        sourceCode = example.source
        currentFileURL = nil
        isDirty = false
        errorMessage = ""
        hasError = false
        compileAndRun()
    }

    func stop() {
        if isAudioPlaying {
            coordinator.stopAudio()
            isAudioPlaying = false
        }
        hasVisual = false
        hasAudio = false
        isRunning = false
        statusText = "Stopped"
        RenderStats.shared.reset()
    }

    func compileAndRun() {
        errorMessage = ""
        hasError = false
        resourceWarning = nil
        statusText = "Compiling..."
        RenderStats.shared.reset()

        do {
            // Use native Swift compiler
            let program = try compiler.compile(sourceCode)

            // Set source file URL for relative resource resolution
            coordinator.sourceFileURL = currentFileURL

            try coordinator.load(program: program)

            // Check for resource loading errors
            if let resourceErrors = coordinator.getResourceErrorMessage() {
                resourceWarning = resourceErrors
                print("Resource warnings:\n\(resourceErrors)")
            }

            hasVisual = coordinator.swatchGraph?.swatches.contains { $0.isSink && $0.backend == "visual" } ?? false
            hasAudio = coordinator.swatchGraph?.swatches.contains { $0.isSink && $0.backend == "audio" } ?? false

            isRunning = true
            statusText = resourceWarning != nil ? "Running (with warnings)" : "Running"
            compilationVersion += 1  // Trigger dev mode refresh

            if hasAudio && !isAudioPlaying {
                try coordinator.startAudio()
                isAudioPlaying = true
            }

        } catch let error as WeftCompileError {
            hasError = true
            isRunning = false
            errorMessage = error.errorDescription ?? "Unknown compile error"
            compilationError = CompilationError.parse(from: errorMessage, source: sourceCode)
            statusText = "Error"
        } catch {
            hasError = true
            isRunning = false
            errorMessage = error.localizedDescription
            compilationError = CompilationError.parse(from: errorMessage, source: sourceCode)
            statusText = "Error"
        }
    }

    func toggleAudio() {
        if isAudioPlaying {
            coordinator.stopAudio()
            isAudioPlaying = false
        } else {
            do {
                try coordinator.startAudio()
                isAudioPlaying = true
            } catch {
                errorMessage = "Audio error: \(error.localizedDescription)"
            }
        }
    }

    func browseForMissingResource() {
        // Get the first missing resource to help determine file types
        let hasImageErrors = coordinator.getTextureLoadErrors()?.isEmpty == false
        let hasAudioErrors = coordinator.getSampleLoadErrors()?.isEmpty == false

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the missing resource file"

        // Set allowed types based on what's missing
        var allowedTypes: [UTType] = []
        if hasImageErrors {
            allowedTypes.append(contentsOf: [.png, .jpeg, .heic, .tiff, .bmp, .gif])
        }
        if hasAudioErrors {
            allowedTypes.append(contentsOf: [.wav, .aiff, .mp3, .audio])
        }
        if allowedTypes.isEmpty {
            allowedTypes = [.png, .jpeg, .wav, .aiff, .mp3, .audio]
        }
        panel.allowedContentTypes = allowedTypes

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            Task { @MainActor in
                guard let self = self else { return }

                // Get the filename to find which resource to replace
                let filename = url.lastPathComponent

                // Find and replace the path in source code
                // Look for load("...") or sample("...") patterns
                var newSource = self.sourceCode
                let loadPattern = #"(load|sample|texture)\s*\(\s*"([^"]*)""#
                if let regex = try? NSRegularExpression(pattern: loadPattern, options: []) {
                    let range = NSRange(newSource.startIndex..., in: newSource)
                    let matches = regex.matches(in: newSource, options: [], range: range)

                    // Find a match that contains a file not found
                    for match in matches.reversed() {
                        if let pathRange = Range(match.range(at: 2), in: newSource) {
                            let oldPath = String(newSource[pathRange])
                            let oldFilename = (oldPath as NSString).lastPathComponent

                            // If the old filename matches or this resource was missing, replace it
                            if let texErrors = self.coordinator.getTextureLoadErrors(),
                               texErrors.values.contains(where: { $0.path == oldPath }) {
                                // Replace with full path
                                newSource.replaceSubrange(pathRange, with: url.path)
                                break
                            } else if let smpErrors = self.coordinator.getSampleLoadErrors(),
                                      smpErrors.values.contains(where: { $0.path == oldPath }) {
                                newSource.replaceSubrange(pathRange, with: url.path)
                                break
                            } else if filename.lowercased().contains(oldFilename.lowercased()) ||
                                        oldFilename.lowercased().contains(filename.lowercased()) {
                                // Fuzzy match on filename
                                newSource.replaceSubrange(pathRange, with: url.path)
                                break
                            }
                        }
                    }
                }

                // Update source and recompile
                if newSource != self.sourceCode {
                    self.sourceCode = newSource
                    self.editorID = UUID()  // Force editor refresh
                }
                self.compileAndRun()
            }
        }
    }
}

// MARK: - Code Editor (NSTextView wrapper)

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FocusableTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.insertionPointColor = NSColor.textColor

        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false

        textView.delegate = context.coordinator
        textView.string = text

        // Apply initial syntax highlighting
        DispatchQueue.main.async {
            context.coordinator.applyHighlighting(to: textView)
        }

        // Set up scroll view
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text && !context.coordinator.isEditing {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            // Apply syntax highlighting after text update
            context.coordinator.applyHighlighting(to: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var isEditing = false
        private let highlighter = WeftSyntaxHighlighter()

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            // Save selection
            let selectedRanges = textView.selectedRanges
            // Apply highlighting
            highlighter.highlight(textStorage)
            // Restore selection
            textView.selectedRanges = selectedRanges
        }
    }
}

class FocusableTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    // Documentation popover state
    private var docPopover: NSPopover?

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        // Check for Option+Click to show documentation
        if event.modifierFlags.contains(.option) {
            let point = convert(event.locationInWindow, from: nil)
            if let word = wordAtPoint(point), !word.isEmpty {
                showDocumentationPopover(for: word, at: point)
                return  // Don't pass to super - we handled it
            }
        }

        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
        dismissPopover()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        dismissPopover()
    }

    override func keyDown(with event: NSEvent) {
        // Escape dismisses popover
        if event.keyCode == 53 {  // Escape key
            dismissPopover()
        }
        super.keyDown(with: event)
    }

    // MARK: - Word Detection

    private func wordAtPoint(_ point: NSPoint) -> String? {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return nil }

        // Convert point to text container coordinates
        let textContainerOffset = textContainerOrigin
        let locationInTextContainer = NSPoint(
            x: point.x - textContainerOffset.x,
            y: point.y - textContainerOffset.y
        )

        // Get character index at point
        var fraction: CGFloat = 0
        let charIndex = layoutManager.characterIndex(
            for: locationInTextContainer,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )

        guard charIndex < string.count else { return nil }

        // Find word boundaries
        let nsString = string as NSString
        let wordRange = nsString.rangeOfWord(at: charIndex)

        guard wordRange.location != NSNotFound && wordRange.length > 0 else { return nil }

        return nsString.substring(with: wordRange)
    }

    // MARK: - Popover Management

    /// Shows documentation popover for a spindle/builtin at the given click position.
    /// Trigger: Option+Click on a word in the editor.
    private func showDocumentationPopover(for word: String, at point: NSPoint) {
        guard let doc = SpindleDocManager.shared.documentation(for: word) else { return }

        // Create popover content
        let contentView = DocumentationPopoverView(doc: doc)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)

        // Size to fit content
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        // Create popover
        let popover = NSPopover()
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = hostingView
        popover.behavior = .transient
        popover.animates = true

        // Calculate rect at click position
        let cursorRect = NSRect(x: point.x, y: point.y, width: 1, height: 1)

        popover.show(relativeTo: cursorRect, of: self, preferredEdge: .maxY)
        docPopover = popover
    }

    private func dismissPopover() {
        docPopover?.close()
        docPopover = nil
    }
}

// MARK: - NSString Extension for Word Finding

extension NSString {
    func rangeOfWord(at index: Int) -> NSRange {
        guard index >= 0 && index < length else {
            return NSRange(location: NSNotFound, length: 0)
        }

        // Define word characters (letters, digits, underscore)
        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

        // Check if current character is a word character
        let char = character(at: index)
        guard let scalar = Unicode.Scalar(char), wordChars.contains(scalar) else {
            return NSRange(location: NSNotFound, length: 0)
        }

        // Find start of word
        var start = index
        while start > 0 {
            let prevChar = character(at: start - 1)
            guard let prevScalar = Unicode.Scalar(prevChar), wordChars.contains(prevScalar) else { break }
            start -= 1
        }

        // Find end of word
        var end = index
        while end < length - 1 {
            let nextChar = character(at: end + 1)
            guard let nextScalar = Unicode.Scalar(nextChar), wordChars.contains(nextScalar) else { break }
            end += 1
        }

        return NSRange(location: start, length: end - start + 1)
    }
}

// MARK: - Documentation Popover View

struct DocumentationPopoverView: View {
    let doc: SpindleDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Signature
            Text(doc.signature)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)

            // Description
            Text(doc.description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Parameters
            if !doc.params.isEmpty {
                Divider()
                ForEach(doc.params, id: \.name) { param in
                    HStack(alignment: .top, spacing: 4) {
                        Text(param.name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.blue)
                        Text("-")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(param.desc)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Returns
            if let returns = doc.returns {
                Divider()
                HStack(alignment: .top, spacing: 4) {
                    Text("Returns:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(returns)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Example
            if let example = doc.example {
                Divider()
                Text(example)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(4)
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(4)
            }
        }
        .padding(10)
        .frame(maxWidth: 320)
    }
}

#Preview {
    ContentView()
}
