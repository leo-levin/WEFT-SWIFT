// ContentView.swift - Main application view with WEFT editor

import SwiftUI
import AppKit
import SWeftLib

struct ContentView: View {
    @StateObject private var viewModel = WeftViewModel()
    @State private var showInspector = true
    @State private var showGraph = true
    @State private var showErrors = true
    @State private var showStats = true
    @State private var inspectorTab: InspectorTab = .ir

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            SubtleDivider(.horizontal)
            mainContent
        }
        .onAppear {
            viewModel.loadExample(.gradient)
        }
        .focusedSceneValue(\.showInspector, $showInspector)
        .focusedSceneValue(\.showGraph, $showGraph)
        .focusedSceneValue(\.showErrors, $showErrors)
        .focusedSceneValue(\.showStats, $showStats)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Spacing.md) {
            // Status
            HStack(spacing: Spacing.sm) {
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
                .frame(height: 14)
                .padding(.horizontal, Spacing.xs)

            // Panel toggles
            HStack(spacing: 2) {
                ToolbarIconButton("speedometer", label: "Stats (⌥⌘S)", isActive: showStats) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showStats.toggle()
                    }
                }

                ToolbarIconButton("exclamationmark.triangle", label: "Errors (⇧⌘E)", isActive: showErrors && viewModel.hasError) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showErrors.toggle()
                    }
                }
                .opacity(viewModel.hasError ? 1 : 0.4)

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, Spacing.xs)

                ToolbarIconButton("rectangle.bottomthird.inset.filled", label: "Graph (⇧⌘G)", isActive: showGraph) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showGraph.toggle()
                    }
                }

                ToolbarIconButton("sidebar.trailing", label: "Inspector (⌥⌘I)", isActive: showInspector) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showInspector.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.panelHeaderBackground)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        HSplitView {
            // Left: Editor + Errors
            editorSection
                .frame(minWidth: 280, idealWidth: 360)

            // Center: Canvas + Graph
            canvasSection
                .frame(minWidth: 320)

            // Right: Inspector
            if showInspector {
                inspectorSection
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            }
        }
    }

    // MARK: - Editor Section

    private var editorSection: some View {
        VStack(spacing: 0) {
            Panel(showSeparator: true) {
                PanelHeader("Editor", icon: "doc.text")
            } content: {
                CodeEditor(text: $viewModel.sourceCode)
                    .onChange(of: viewModel.sourceCode) { _, _ in
                        viewModel.hasError = false
                    }
            }

            // Error panel
            if viewModel.hasError && showErrors {
                SubtleDivider(.horizontal)
                errorPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.hasError && showErrors)
    }

    private var errorPanel: some View {
        VStack(spacing: 0) {
            PanelHeader("Errors", icon: "exclamationmark.triangle") {
                Button {
                    withAnimation {
                        showErrors = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            SubtleDivider(.horizontal)

            ScrollView {
                ErrorBanner(viewModel.errorMessage)
            }
            .frame(height: 80)
        }
    }

    // MARK: - Canvas Section

    @ObservedObject private var renderStats = RenderStats.shared

    private var canvasSection: some View {
        VStack(spacing: 0) {
            // Canvas
            Panel(showSeparator: true) {
                PanelHeader("Canvas", icon: "square.on.square")
            } content: {
                canvasContent
            }

            // Graph
            if showGraph {
                SubtleDivider(.horizontal)
                graphPanel
                    .frame(minHeight: 120, idealHeight: 160)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showGraph)
    }

    private var canvasContent: some View {
        GeometryReader { geo in
            let aspectRatio: CGFloat = 4.0 / 3.0
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
                            StatsOverlay(
                                fps: renderStats.fps,
                                frameTime: renderStats.frameTime,
                                droppedFrames: renderStats.droppedFrames
                            )
                            .padding(Spacing.sm)
                            .transition(.opacity)
                        }
                    } else {
                        EmptyStateView("play.circle", message: "Press ⌘Return to run", hint: "or write some WEFT code")
                    }
                }
                .frame(width: fittedWidth, height: fittedHeight)
            }
        }
    }

    private var graphPanel: some View {
        Panel(showSeparator: false) {
            PanelHeader("Graph", icon: "point.3.connected.trianglepath.dotted") {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showGraph = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        } content: {
            SubtleDivider(.horizontal)
            GraphView(coordinator: viewModel.coordinator)
        }
    }

    // MARK: - Inspector Section

    private var inspectorSection: some View {
        Panel(showSeparator: true) {
            PanelHeader("Inspector", icon: "sidebar.right") {
                Picker("", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
        } content: {
            VStack(spacing: 0) {
                let content = inspectorTab == .ir ? viewModel.irOutput : viewModel.astOutput
                CodeBlockView(content)

                SubtleDivider(.horizontal)

                HStack {
                    Spacer()
                    Button {
                        let content = inspectorTab == .ir ? viewModel.irOutput : viewModel.astOutput
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(Spacing.sm)
            }
        }
    }
}

// MARK: - Inspector Tab

enum InspectorTab: String, CaseIterable, Identifiable {
    case ir = "IR"
    case ast = "AST"

    var id: Self { self }
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
                .font(.system(size: 12, weight: .regular))
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

        let nodeWidth: CGFloat = 80
        let nodeHeight: CGFloat = 28
        let layerSpacing: CGFloat = 120
        let nodeSpacing: CGFloat = 10
        let padding: CGFloat = 24

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
                let arrowSize: CGFloat = 5
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

            context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(color.opacity(0.15)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(color.opacity(0.6)), lineWidth: 1)

            let textColor = Color(NSColor.labelColor)
            let text = Text(name).font(.system(size: 10, weight: .medium)).foregroundColor(textColor)
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
    @Published var sourceCode = ""
    @Published var statusText = "Ready"
    @Published var errorMessage = ""
    @Published var irOutput = ""
    @Published var astOutput = ""
    @Published var hasVisual = false
    @Published var hasAudio = false
    @Published var isAudioPlaying = false
    @Published var hasError = false
    @Published var isRunning = false

    private let jsCompiler = WeftJSCompiler()

    init() {
        do {
            try jsCompiler.initialize()
        } catch {
            print("Failed to initialize JS compiler: \(error)")
        }
    }

    func loadExample(_ example: WeftExample) {
        stop()
        sourceCode = example.source
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
    }

    func compileAndRun() {
        errorMessage = ""
        hasError = false
        statusText = "Compiling..."

        do {
            let astString = try jsCompiler.parseToAST(sourceCode)
            astOutput = formatJSON(astString)

            let jsonString = try jsCompiler.compileToJSON(sourceCode)
            irOutput = formatJSON(jsonString)

            guard let data = jsonString.data(using: .utf8) else {
                throw WeftCompileError.jsonParseError("Could not encode JSON")
            }

            let parser = IRParser()
            let program = try parser.parse(data: data)

            try coordinator.load(program: program)

            hasVisual = coordinator.swatchGraph?.swatches.contains { $0.isSink && $0.backend == .visual } ?? false
            hasAudio = coordinator.swatchGraph?.swatches.contains { $0.isSink && $0.backend == .audio } ?? false

            isRunning = true
            statusText = "Running"

            if hasAudio && !isAudioPlaying {
                try coordinator.startAudio()
                isAudioPlaying = true
            }

        } catch let error as WeftCompileError {
            hasError = true
            isRunning = false
            errorMessage = error.errorDescription ?? "Unknown compile error"
            statusText = "Error"
        } catch {
            hasError = true
            isRunning = false
            errorMessage = error.localizedDescription
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

    private func formatJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return json
        }
        if prettyString.count > 2000 {
            return String(prettyString.prefix(2000)) + "\n... (truncated)"
        }
        return prettyString
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

        textView.textContainerInset = NSSize(width: 10, height: 12)
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
