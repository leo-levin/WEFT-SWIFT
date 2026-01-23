// DevModeView.swift - Developer mode panel with IR, shader, and analysis views

import SwiftUI
import SWeftLib

// MARK: - Dev Mode View

struct DevModeView: View {
    let coordinator: Coordinator
    @Binding var selectedTab: DevModeTab

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(DevModeTab.allCases, id: \.self) { tab in
                    DevModeTabButton(
                        tab: tab,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.panelHeaderBackground)

            SubtleDivider(.horizontal)

            // Tab content
            Group {
                switch selectedTab {
                case .ir:
                    IRView(coordinator: coordinator)
                case .code:
                    GeneratedCodeView(coordinator: coordinator)
                case .analysis:
                    AnalysisView(coordinator: coordinator)
                case .swatches:
                    SwatchesView(coordinator: coordinator)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Dev Mode Tab

enum DevModeTab: String, CaseIterable {
    case ir = "IR"
    case code = "Code"
    case analysis = "Analysis"
    case swatches = "Swatches"

    var icon: String {
        switch self {
        case .ir: return "doc.text"
        case .code: return "cpu"
        case .analysis: return "chart.bar.xaxis"
        case .swatches: return "square.grid.2x2"
        }
    }
}

// MARK: - Dev Mode Tab Button

struct DevModeTabButton: View {
    let tab: DevModeTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10))
                Text(tab.rawValue)
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - IR View

struct IRView: View {
    let coordinator: Coordinator
    @State private var expandedBundles: Set<String> = []
    @State private var expandedSpindles: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if let program = coordinator.program {
                    // Program overview
                    DevModeSection(title: "Program Overview", icon: "doc.text.fill") {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            InfoRow(label: "Bundles", value: "\(program.bundles.count)")
                            InfoRow(label: "Spindles", value: "\(program.spindles.count)")
                            InfoRow(label: "Resources", value: program.resources.isEmpty ? "None" : program.resources.joined(separator: ", "))
                            InfoRow(label: "Execution Order", value: program.order.map { $0.bundle }.joined(separator: " -> "))
                        }
                    }

                    // Bundles
                    DevModeSection(title: "Bundles", icon: "cube.fill") {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(Array(program.bundles.keys.sorted()), id: \.self) { bundleName in
                                if let bundle = program.bundles[bundleName] {
                                    let domain = coordinator.annotatedProgram?.bundleDomain(bundleName)
                                    let purityState = purityStateForBundle(bundleName, annotations: coordinator.annotatedProgram)
                                    BundleRow(
                                        bundle: bundle,
                                        isExpanded: expandedBundles.contains(bundleName),
                                        domain: domain,
                                        purityState: purityState
                                    ) {
                                        if expandedBundles.contains(bundleName) {
                                            expandedBundles.remove(bundleName)
                                        } else {
                                            expandedBundles.insert(bundleName)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Spindles
                    if !program.spindles.isEmpty {
                        DevModeSection(title: "Spindles", icon: "function") {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                ForEach(program.spindles.keys.sorted(), id: \.self) { spindleName in
                                    if let spindle = program.spindles[spindleName] {
                                        SpindleRow(
                                            spindle: spindle,
                                            isExpanded: expandedSpindles.contains(spindleName)
                                        ) {
                                            if expandedSpindles.contains(spindleName) {
                                                expandedSpindles.remove(spindleName)
                                            } else {
                                                expandedSpindles.insert(spindleName)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    EmptyDevModeView(message: "No program loaded", hint: "Run a program to see IR")
                }
            }
            .padding(Spacing.sm)
        }
    }
}

// MARK: - Bundle Row

/// Simplified purity state for display (derived from annotations)
enum PurityState {
    case pure
    case stateful
    case external
}

struct BundleRow: View {
    let bundle: IRBundle
    let isExpanded: Bool
    let domain: BackendDomain?
    let purityState: PurityState?
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Text(bundle.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)

                    Text("[\(bundle.strands.map { $0.name }.joined(separator: ", "))]")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Badges
                    if let d = domain {
                        DomainBadge(domain: d)
                    }
                    if let ps = purityState {
                        PurityBadge(purityState: ps)
                    }
                }
                .padding(.vertical, Spacing.xxs)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(bundle.strands, id: \.name) { strand in
                        HStack(alignment: .top, spacing: Spacing.xs) {
                            Text("\(strand.name):")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)

                            Text(strand.expr.description)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.vertical, Spacing.xs)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }
        }
    }
}

// MARK: - Spindle Row

struct SpindleRow: View {
    let spindle: IRSpindle
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Text(spindle.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)

                    Text("(\(spindle.params.joined(separator: ", ")))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("-> \(spindle.returns.count) return\(spindle.returns.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
                .padding(.vertical, Spacing.xxs)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    // Local bundles
                    if !spindle.locals.isEmpty {
                        Text("Locals:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        ForEach(spindle.locals, id: \.name) { local in
                            Text("  \(local.name) = ...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Returns
                    Text("Returns:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(spindle.returns.enumerated()), id: \.offset) { idx, expr in
                        Text("  [\(idx)] = \(expr.description)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 20)
                .padding(.vertical, Spacing.xs)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }
        }
    }
}

// MARK: - Generated Code View

struct GeneratedCodeView: View {
    let coordinator: Coordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Metal Shaders
                if let shaderSources = getShaderSources(), !shaderSources.isEmpty {
                    ForEach(Array(shaderSources.enumerated()), id: \.offset) { idx, source in
                        DevModeSection(title: shaderSources.count > 1 ? "Metal Shader \(idx + 1)" : "Metal Shader", icon: "cpu") {
                            SyntaxHighlightedCode(source: source.source, language: .metal)
                        }
                    }
                }

                // Audio Backend Info
                if hasAudioSwatches() {
                    DevModeSection(title: "Audio Backend", icon: "waveform") {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Audio code is generated as Swift closures at runtime.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)

                            Divider()

                            Text("Signature:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)

                            Text("(sampleIndex: Int, time: Double, sampleRate: Double) -> (Float, Float)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary)
                                .padding(.vertical, Spacing.xxs)

                            if let audioInfo = getAudioInfo() {
                                Divider()
                                Text("Bundles:")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                Text(audioInfo)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }

                // Empty state
                if getShaderSources()?.isEmpty ?? true && !hasAudioSwatches() {
                    EmptyDevModeView(message: "No generated code", hint: "Run a program to see generated code")
                }
            }
            .padding(Spacing.sm)
        }
    }

    private func getShaderSources() -> [(swatch: Swatch, source: String)]? {
        guard let swatches = coordinator.swatchGraph?.swatches else { return nil }

        var sources: [(Swatch, String)] = []
        for swatch in swatches where swatch.backend == .visual {
            if let source = coordinator.getCompiledShaderSource(for: swatch.id) {
                sources.append((swatch, source))
            }
        }
        return sources.isEmpty ? nil : sources
    }

    private func hasAudioSwatches() -> Bool {
        guard let swatches = coordinator.swatchGraph?.swatches else { return false }
        return swatches.contains { $0.backend == .audio }
    }

    private func getAudioInfo() -> String? {
        guard let swatches = coordinator.swatchGraph?.swatches else { return nil }
        let audioBundles = swatches
            .filter { $0.backend == .audio }
            .flatMap { $0.bundles }
            .sorted()
        return audioBundles.isEmpty ? nil : audioBundles.joined(separator: ", ")
    }
}

// MARK: - Syntax Highlighted Code

enum CodeLanguage {
    case metal
}

struct SyntaxHighlightedCode: View {
    let source: String
    let language: CodeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(highlightedCode)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(2)
        }
    }

    private var highlightedCode: AttributedString {
        var result = AttributedString(source)

        // Apply base style
        result.foregroundColor = NSColor.labelColor

        // Metal syntax highlighting
        if language == .metal {
            highlightMetalSyntax(&result)
        }

        return result
    }

    private func highlightMetalSyntax(_ attributed: inout AttributedString) {
        let sourceString = source

        // Keywords (purple/magenta)
        let keywords = ["kernel", "void", "return", "if", "else", "for", "while", "struct", "constant", "device", "texture2d", "sampler", "float", "float2", "float3", "float4", "int", "int2", "uint", "uint2", "half", "half3", "half4", "bool", "using", "namespace", "metal", "access", "read", "write", "sample", "thread_position_in_grid"]
        for keyword in keywords {
            highlightPattern("\\b\(keyword)\\b", in: &attributed, source: sourceString, color: NSColor(red: 0.77, green: 0.52, blue: 0.77, alpha: 1.0)) // purple
        }

        // Types (blue)
        let types = ["Uniforms", "MTLTexture", "MTLBuffer"]
        for type in types {
            highlightPattern("\\b\(type)\\b", in: &attributed, source: sourceString, color: NSColor(red: 0.34, green: 0.61, blue: 0.84, alpha: 1.0)) // blue
        }

        // Built-in functions (cyan/teal)
        let builtins = ["sin", "cos", "tan", "abs", "floor", "ceil", "sqrt", "pow", "min", "max", "clamp", "mix", "step", "smoothstep", "fract", "fmod", "normalize", "length", "dot", "cross", "saturate"]
        for builtin in builtins {
            highlightPattern("\\b\(builtin)\\b(?=\\s*\\()", in: &attributed, source: sourceString, color: NSColor(red: 0.31, green: 0.79, blue: 0.69, alpha: 1.0)) // teal
        }

        // Numbers (light green)
        highlightPattern("\\b\\d+\\.?\\d*f?\\b", in: &attributed, source: sourceString, color: NSColor(red: 0.71, green: 0.84, blue: 0.66, alpha: 1.0))

        // Comments (green)
        highlightPattern("//.*$", in: &attributed, source: sourceString, color: NSColor(red: 0.42, green: 0.60, blue: 0.33, alpha: 1.0), options: [.anchorsMatchLines])

        // Strings (orange) - unlikely in Metal but just in case
        highlightPattern("\"[^\"]*\"", in: &attributed, source: sourceString, color: NSColor(red: 0.81, green: 0.57, blue: 0.48, alpha: 1.0))

        // Preprocessor directives (magenta)
        highlightPattern("^\\s*#\\w+", in: &attributed, source: sourceString, color: NSColor(red: 0.77, green: 0.52, blue: 0.77, alpha: 1.0), options: [.anchorsMatchLines])

        // Attributes like [[texture(0)]] (yellow)
        highlightPattern("\\[\\[[^\\]]+\\]\\]", in: &attributed, source: sourceString, color: NSColor(red: 0.86, green: 0.86, blue: 0.67, alpha: 1.0))
    }

    private func highlightPattern(_ pattern: String, in attributed: inout AttributedString, source: String, color: NSColor, options: NSRegularExpression.Options = []) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }

        let nsRange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)

        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            guard let attrRange = Range(range, in: attributed) else { continue }
            attributed[attrRange].foregroundColor = color
        }
    }
}

// MARK: - Analysis View

struct AnalysisView: View {
    let coordinator: Coordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Signal Annotations
                DevModeSection(title: "Signal Annotations", icon: "tag.fill") {
                    if let annotations = coordinator.annotatedProgram,
                       let program = coordinator.program {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(Array(program.bundles.keys.sorted()), id: \.self) { bundle in
                                HStack {
                                    Text(bundle)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    DomainBadge(domain: annotations.bundleDomain(bundle))
                                    if let ps = purityStateForBundle(bundle, annotations: annotations) {
                                        PurityBadge(purityState: ps)
                                    }
                                }
                            }

                            // Show stateful bundles
                            let statefulBundles = program.bundles.keys.filter { bundleName in
                                annotations.signals.contains { key, signal in
                                    key.hasPrefix("\(bundleName).") && signal.stateful
                                }
                            }
                            if !statefulBundles.isEmpty {
                                Divider()
                                Text("Stateful (uses cache)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                Text(statefulBundles.sorted().joined(separator: ", "))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("No annotations available")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Dependency Graph
                DevModeSection(title: "Dependencies", icon: "arrow.triangle.branch") {
                    if let graph = coordinator.dependencyGraph {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(graph.dependencies.keys.sorted(), id: \.self) { bundle in
                                let deps = graph.dependencies[bundle] ?? []
                                HStack(alignment: .top) {
                                    Text(bundle)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .frame(width: 80, alignment: .leading)

                                    if deps.isEmpty {
                                        Text("(no dependencies)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    } else {
                                        Text("-> " + deps.sorted().joined(separator: ", "))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    } else {
                        Text("No graph available")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Cache Info
                if let cacheDescriptors = coordinator.getCacheDescriptors(), !cacheDescriptors.isEmpty {
                    DevModeSection(title: "Cache Nodes", icon: "clock.arrow.circlepath") {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(Array(cacheDescriptors.enumerated()), id: \.offset) { idx, desc in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("[\(idx)] \(desc.bundleName).\(desc.strandIndex)")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        Spacer()
                                        CacheDomainBadge(domain: desc.domain)
                                    }
                                    HStack(spacing: Spacing.sm) {
                                        Text("History: \(desc.historySize)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text("Tap: \(desc.tapIndex)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        if desc.hasSelfReference {
                                            Text("Self-Ref")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.sm)
        }
    }
}

// MARK: - Swatches View

struct SwatchesView: View {
    let coordinator: Coordinator
    @State private var expandedSwatches: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if let swatchGraph = coordinator.swatchGraph {
                    // Overview
                    DevModeSection(title: "Swatch Graph", icon: "square.grid.2x2.fill") {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            InfoRow(label: "Total Swatches", value: "\(swatchGraph.swatches.count)")
                            InfoRow(label: "Visual Swatches", value: "\(swatchGraph.swatches.filter { $0.backend == .visual }.count)")
                            InfoRow(label: "Audio Swatches", value: "\(swatchGraph.swatches.filter { $0.backend == .audio }.count)")
                        }
                    }

                    // Individual swatches
                    DevModeSection(title: "Compilation Units", icon: "shippingbox.fill") {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            ForEach(swatchGraph.swatches, id: \.id) { swatch in
                                SwatchRow(
                                    swatch: swatch,
                                    isExpanded: expandedSwatches.contains(swatch.id)
                                ) {
                                    if expandedSwatches.contains(swatch.id) {
                                        expandedSwatches.remove(swatch.id)
                                    } else {
                                        expandedSwatches.insert(swatch.id)
                                    }
                                }
                            }
                        }
                    }

                    // Execution order
                    if let sortedSwatches = swatchGraph.topologicalSort() {
                        DevModeSection(title: "Execution Order", icon: "arrow.right") {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                ForEach(Array(sortedSwatches.enumerated()), id: \.element.id) { idx, swatch in
                                    HStack {
                                        Text("\(idx + 1).")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 20)

                                        DomainBadge(domain: swatch.backend)

                                        Text(swatch.bundles.sorted().joined(separator: ", "))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.primary)

                                        if swatch.isSink {
                                            Text("SINK")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.red.opacity(0.8))
                                                .cornerRadius(3)
                                        }

                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                } else {
                    EmptyDevModeView(message: "No swatch graph", hint: "Run a program to see compilation units")
                }
            }
            .padding(Spacing.sm)
        }
    }
}

// MARK: - Swatch Row

struct SwatchRow: View {
    let swatch: Swatch
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    DomainBadge(domain: swatch.backend)

                    Text(swatch.bundles.sorted().joined(separator: ", "))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)

                    Spacer()

                    if swatch.isSink {
                        Text("SINK")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(3)
                    }
                }
                .padding(.vertical, Spacing.xxs)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text("ID:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(swatch.id.uuidString.prefix(8) + "...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if !swatch.inputBuffers.isEmpty {
                        HStack(alignment: .top) {
                            Text("Inputs:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Text(swatch.inputBuffers.sorted().joined(separator: ", "))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.blue)
                        }
                    }

                    if !swatch.outputBuffers.isEmpty {
                        HStack(alignment: .top) {
                            Text("Outputs:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Text(swatch.outputBuffers.sorted().joined(separator: ", "))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.vertical, Spacing.xs)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }
        }
    }
}

// MARK: - Helper Components

struct DevModeSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            content()
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

struct DomainBadge: View {
    let domain: BackendDomain

    var body: some View {
        Text(domain.rawValue.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(domainColor)
            .cornerRadius(3)
    }

    private var domainColor: Color {
        switch domain {
        case .visual: return .blue
        case .audio: return .green
        case .none: return .gray
        }
    }
}

struct PurityBadge: View {
    let purityState: PurityState

    var body: some View {
        Text(purityText)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(purityColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(purityColor.opacity(0.15))
            .cornerRadius(3)
    }

    private var purityText: String {
        switch purityState {
        case .pure: return "pure"
        case .stateful: return "stateful"
        case .external: return "external"
        }
    }

    private var purityColor: Color {
        switch purityState {
        case .pure: return .green
        case .stateful: return .orange
        case .external: return .purple
        }
    }
}

/// Helper to derive purity state from annotations
func purityStateForBundle(_ bundleName: String, annotations: IRAnnotatedProgram?) -> PurityState? {
    guard let annotations = annotations else { return nil }

    // Look for any strand in the bundle
    for (key, signal) in annotations.signals {
        if key.hasPrefix("\(bundleName).") {
            if signal.isExternal {
                return .external
            } else if signal.stateful {
                return .stateful
            } else {
                return .pure
            }
        }
    }
    return nil
}

struct CacheDomainBadge: View {
    let domain: CacheDomain

    var body: some View {
        Text(domainText)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(domainColor)
            .cornerRadius(3)
    }

    private var domainText: String {
        switch domain {
        case .visual: return "VISUAL"
        case .audio: return "AUDIO"
        }
    }

    private var domainColor: Color {
        switch domain {
        case .visual: return .blue
        case .audio: return .green
        }
    }
}

struct EmptyDevModeView: View {
    let message: String
    let hint: String

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24, weight: .ultraLight))
                .foregroundStyle(.tertiary)

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.lg)
    }
}
