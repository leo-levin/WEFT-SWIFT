// ContentView.swift - Main application view with WEFT editor

import SwiftUI
import AppKit
import SWeftLib

struct ContentView: View {
    @StateObject private var viewModel = WeftViewModel()
    @State private var showDebugPanel = true
    @State private var showGraphPanel = true
    @State private var showStats = true
    @State private var inspectorSelection: InspectorTab = .ir

    var body: some View {
        VStack(spacing: 0) {
            toolbarView
                .background(.bar)

            Divider()

            HSplitView {
                // Editor
                editorPanel
                    .frame(minWidth: 300)

                // Inspector
                if showDebugPanel {
                    inspectorPanel
                        .frame(minWidth: 250, idealWidth: 320, maxWidth: 450)
                }

                // Canvas + Graph
                canvasPanel
            }
        }
        .onAppear {
            viewModel.loadExample(.gradient)
        }
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.hasError ? .red : (viewModel.isRunning ? .green : .gray))
                    .frame(width: 8, height: 8)
                Text(viewModel.statusText)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            Spacer()

            Button("Stop", systemImage: "stop.fill") {
                viewModel.stop()
            }
            .disabled(!viewModel.isRunning)
            .keyboardShortcut(".", modifiers: .command)

            Button("Run", systemImage: "play.fill") {
                viewModel.compileAndRun()
            }
            .keyboardShortcut(.return, modifiers: .command)

            Divider()
                .frame(height: 16)

            Toggle(isOn: $showStats) {
                Label("Stats", systemImage: "speedometer")
            }
            .toggleStyle(.button)
            .labelStyle(.titleOnly)

            Toggle(isOn: $showDebugPanel) {
                Label("Inspector", systemImage: "sidebar.left")
            }
            .toggleStyle(.button)
            .labelStyle(.titleOnly)

            Toggle(isOn: $showGraphPanel) {
                Label("Graph", systemImage: "chart.line.text.clipboard")
            }
            .toggleStyle(.button)
            .labelStyle(.titleOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Editor Panel

    private var editorPanel: some View {
        VStack(spacing: 0) {
            CodeEditor(text: $viewModel.sourceCode)
                .onChange(of: viewModel.sourceCode) { _, _ in
                    viewModel.hasError = false
                }

            if !viewModel.errorMessage.isEmpty {
                Divider()
                ScrollView {
                    Text(viewModel.errorMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
                .frame(height: 80)
                .background(.red.opacity(0.05))
            }
        }
    }

    // MARK: - Canvas Panel

    @ObservedObject private var renderStats = RenderStats.shared

    private var canvasPanel: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text("Canvas")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Canvas with letterboxing
            GeometryReader { geo in
                let aspectRatio: CGFloat = 800.0 / 600.0
                let availableWidth = geo.size.width
                let availableHeight = geo.size.height
                let fittedWidth = min(availableWidth, availableHeight * aspectRatio)
                let fittedHeight = fittedWidth / aspectRatio

                ZStack {
                    Color.black

                    ZStack(alignment: .topTrailing) {
                        if viewModel.hasVisual {
                            WeftMetalView(coordinator: viewModel.coordinator)

                            if showStats {
                                statsOverlay
                                    .padding(8)
                            }
                        } else {
                            emptyCanvasPlaceholder
                        }
                    }
                    .frame(width: fittedWidth, height: fittedHeight)
                }
            }

            Divider()

            // Graph area
            if showGraphPanel {
                HStack {
                    Text("Graph")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                GraphView(coordinator: viewModel.coordinator)
            } else {
                Spacer()
                    .background(.background)
            }
        }
        .frame(minWidth: 400)
    }

    private var statsOverlay: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.1f fps", renderStats.fps))
            Text(String(format: "%.2f ms", renderStats.frameTime))
            if renderStats.droppedFrames > 0 {
                Text("\(renderStats.droppedFrames) dropped")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white.opacity(0.8))
        .padding(6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }

    private var emptyCanvasPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.circle")
                .font(.system(size: 40, weight: .thin))
            Text("Press \u{2318}Return to run")
                .font(.callout)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Inspector Panel

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $inspectorSelection) {
                    ForEach(InspectorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            ScrollView {
                let content = inspectorSelection == .ir ? viewModel.irOutput : viewModel.astOutput
                Text(content.isEmpty ? "No output" : content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(content.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            HStack {
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    let content = inspectorSelection == .ir ? viewModel.irOutput : viewModel.astOutput
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(6)
        }
    }
}

// MARK: - Inspector Tab

enum InspectorTab: String, CaseIterable, Identifiable {
    case ir = "IR"
    case ast = "AST"

    var id: Self { self }
}


// MARK: - Graph View (placeholder for Metal rendering)

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
            let text = Text("No graph").font(.system(size: 14)).foregroundColor(.gray)
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

        let nodeWidth: CGFloat = 90
        let nodeHeight: CGFloat = 32
        let layerSpacing: CGFloat = 140
        let nodeSpacing: CGFloat = 12
        let padding: CGFloat = 30

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
                context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1.5)

                // Arrowhead
                let arrowSize: CGFloat = 6
                let arrowPath = Path { p in
                    p.move(to: CGPoint(x: endX, y: toPos.y))
                    p.addLine(to: CGPoint(x: endX - arrowSize, y: toPos.y - arrowSize / 2))
                    p.addLine(to: CGPoint(x: endX - arrowSize, y: toPos.y + arrowSize / 2))
                    p.closeSubpath()
                }
                context.fill(arrowPath, with: .color(.white.opacity(0.3)))
            }
        }

        // Draw nodes
        for (name, pos) in positions {
            let rect = CGRect(x: pos.x - nodeWidth / 2, y: pos.y - nodeHeight / 2, width: nodeWidth, height: nodeHeight)

            let isDisplay = name == "display"
            let isPlay = name == "play"
            let color: Color = isDisplay ? .blue : (isPlay ? .green : .orange)

            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(color.opacity(0.25)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(color.opacity(0.8)), lineWidth: 1.5)

            let text = Text(name).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
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
        // Stop any running audio before switching
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
            // Get AST
            let astString = try jsCompiler.parseToAST(sourceCode)
            astOutput = formatJSON(astString)

            // Get IR
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

        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false

        textView.delegate = context.coordinator
        textView.string = text

        // Set up scroll view
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        // Configure text view to fill scroll view
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
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var isEditing = false

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
        }
    }
}

// Custom NSTextView that properly accepts first responder
class FocusableTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        return result
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }
}

#Preview {
    ContentView()
}
