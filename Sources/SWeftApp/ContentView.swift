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

            // Error panel
            if viewModel.hasError && showErrors {
                SubtleDivider(.horizontal)
                errorPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.hasError && showErrors)
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

// MARK: - Graph View

struct GraphView: View {
    let coordinator: Coordinator

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawGraph(context: context, size: size)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func drawGraph(context: GraphicsContext, size: CGSize) {
        guard coordinator.swatchGraph != nil, let program = coordinator.program else {
            let text = Text("No graph")
                .font(.system(size: 11))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
            return
        }

        // Build dependency graph
        var deps: [String: Set<String>] = [:]
        for (name, bundle) in program.bundles {
            var bundleDeps = Set<String>()
            for strand in bundle.strands {
                for fv in strand.expr.freeVars() {
                    let parts = fv.split(separator: ".")
                    if let first = parts.first {
                        let depName = String(first)
                        if depName != name && depName != "me" && program.bundles[depName] != nil {
                            bundleDeps.insert(depName)
                        }
                    }
                }
            }
            deps[name] = bundleDeps
        }

        // Assign layers via longest path (sinks at right)
        var layers: [String: Int] = [:]
        func computeLayer(_ name: String) -> Int {
            if let l = layers[name] { return l }
            let myDeps = deps[name] ?? []
            let layer = myDeps.isEmpty ? 0 : (myDeps.map { computeLayer($0) }.max() ?? 0) + 1
            layers[name] = layer
            return layer
        }
        for name in program.bundles.keys { _ = computeLayer(name) }

        // Group by layer
        var layerGroups: [Int: [String]] = [:]
        for (name, layer) in layers {
            layerGroups[layer, default: []].append(name)
        }
        for layer in layerGroups.keys {
            layerGroups[layer]?.sort()
        }

        let nodeWidth: CGFloat = 72
        let nodeHeight: CGFloat = 24
        let layerSpacing: CGFloat = 100
        let nodeSpacing: CGFloat = 8
        let padding: CGFloat = 16

        // Calculate positions
        var positions: [String: CGPoint] = [:]
        for (layer, nodes) in layerGroups {
            let totalHeight = CGFloat(nodes.count) * nodeHeight + CGFloat(nodes.count - 1) * nodeSpacing
            let startY = (size.height - totalHeight) / 2
            let x = padding + CGFloat(layer) * layerSpacing + nodeWidth / 2

            for (i, name) in nodes.enumerated() {
                let y = startY + CGFloat(i) * (nodeHeight + nodeSpacing) + nodeHeight / 2
                positions[name] = CGPoint(x: x, y: y)
            }
        }

        // Draw edges with curves
        for (name, nodeDeps) in deps {
            guard let toPos = positions[name] else { continue }
            for dep in nodeDeps {
                guard let fromPos = positions[dep] else { continue }

                let startX = fromPos.x + nodeWidth / 2
                let endX = toPos.x - nodeWidth / 2
                let midX = (startX + endX) / 2

                var path = Path()
                path.move(to: CGPoint(x: startX, y: fromPos.y))
                path.addCurve(
                    to: CGPoint(x: endX, y: toPos.y),
                    control1: CGPoint(x: midX, y: fromPos.y),
                    control2: CGPoint(x: midX, y: toPos.y)
                )

                let edgeColor = Color(NSColor.tertiaryLabelColor)
                context.stroke(path, with: .color(edgeColor), lineWidth: 1)

                // Arrowhead
                let arrowSize: CGFloat = 4
                let arrowPath = Path { p in
                    p.move(to: CGPoint(x: endX, y: toPos.y))
                    p.addLine(to: CGPoint(x: endX - arrowSize, y: toPos.y - arrowSize / 2))
                    p.addLine(to: CGPoint(x: endX - arrowSize, y: toPos.y + arrowSize / 2))
                    p.closeSubpath()
                }
                context.fill(arrowPath, with: .color(edgeColor))
            }
        }

        // Draw nodes
        for (name, pos) in positions {
            let rect = CGRect(x: pos.x - nodeWidth / 2, y: pos.y - nodeHeight / 2, width: nodeWidth, height: nodeHeight)

            let isDisplay = name == "display"
            let isPlay = name == "play"
            let color: Color = isDisplay ? .nodeVisual : (isPlay ? .nodeAudio : .nodeCompute)

            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(color.opacity(0.12)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(color.opacity(0.5)), lineWidth: 1)

            let textColor = Color(NSColor.labelColor)
            let text = Text(name).font(.system(size: 9, weight: .medium)).foregroundColor(textColor)
            context.draw(text, at: pos, anchor: .center)
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
        statusText = "Compiling..."
        RenderStats.shared.reset()

        do {
            // Use native Swift compiler
            let program = try compiler.compile(sourceCode)

            try coordinator.load(program: program)

            hasVisual = coordinator.swatchGraph?.swatches.contains { $0.isSink && $0.backend == .visual } ?? false
            hasAudio = coordinator.swatchGraph?.swatches.contains { $0.isSink && $0.backend == .audio } ?? false

            isRunning = true
            statusText = "Running"
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

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }
}

#Preview {
    ContentView()
}
