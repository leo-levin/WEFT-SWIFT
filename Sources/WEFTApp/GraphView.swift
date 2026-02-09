// GraphView.swift - Dependency graph visualization

import SwiftUI
import WEFTLib

// MARK: - Graph Data Model

struct GraphNode: Identifiable {
    let id: String  // bundle name
    let name: String
    let strandCount: Int
    let strandNames: [String]
    let backend: String?
    let purity: PurityState?
    let isSink: Bool
    let hasCache: Bool
    let hardware: Set<IRHardware>
    let dependencies: Set<String>
    let dependents: Set<String>
}

struct GraphEdge: Identifiable {
    var id: String { "\(from)->\(to)" }
    let from: String
    let to: String
}

// MARK: - Graph View

struct GraphView: View {
    let coordinator: Coordinator
    var layoutBundles: Set<String> = []
    var onToggleLayout: ((String) -> Void)? = nil
    @State private var hoveredNode: String? = nil
    @State private var selectedNode: String? = nil
    @State private var nodePositions: [String: CGPoint] = [:]
    @State private var graphNodes: [String: GraphNode] = [:]
    @State private var graphEdges: [GraphEdge] = []
    @State private var layoutParams: LayoutParams = LayoutParams()

    struct LayoutParams {
        var nodeWidth: CGFloat = 72
        var nodeHeight: CGFloat = 26
        var layerSpacing: CGFloat = 100
        var nodeSpacing: CGFloat = 12
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Graph canvas
                Canvas { context, size in
                    drawGraph(context: context, size: size)
                }
                .background(Color(NSColor.windowBackgroundColor))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredNode = hitTest(location: location)
                    case .ended:
                        hoveredNode = nil
                    }
                }
                .onTapGesture { location in
                    if let tapped = hitTest(location: location) {
                        selectedNode = selectedNode == tapped ? nil : tapped
                    } else {
                        selectedNode = nil
                    }
                }
                .onChange(of: geometry.size) { _, newSize in
                    updateLayout(size: newSize)
                }
                .onAppear {
                    updateLayout(size: geometry.size)
                }

                // Popover for selected node
                if let nodeName = selectedNode, let node = graphNodes[nodeName], let pos = nodePositions[nodeName] {
                    NodePopover(
                        node: node,
                        onDismiss: { selectedNode = nil },
                        isInLayout: layoutBundles.contains(nodeName),
                        onToggleLayout: onToggleLayout.map { toggle in
                            { toggle(nodeName) }
                        }
                    )
                    .position(x: pos.x, y: pos.y - layoutParams.nodeHeight / 2 - 60)
                }
            }
        }
    }

    // MARK: - Layout

    private func updateLayout(size: CGSize) {
        guard coordinator.swatchGraph != nil, let program = coordinator.program else {
            graphNodes = [:]
            graphEdges = []
            nodePositions = [:]
            return
        }

        let deps = coordinator.dependencyGraph?.dependencies ?? [:]
        let annotations = coordinator.annotatedProgram
        let cacheDescriptors = coordinator.getCacheDescriptors() ?? []
        let cacheBundles = Set(cacheDescriptors.map { $0.bundleName })

        // Compute dependents (reverse lookup)
        var dependents: [String: Set<String>] = [:]
        for (name, nodeDeps) in deps {
            for dep in nodeDeps {
                dependents[dep, default: []].insert(name)
            }
        }

        // Build nodes
        var nodes: [String: GraphNode] = [:]
        for (bundleName, bundle) in program.bundles {
            let backend = backendIdForBundle(bundleName, annotations: annotations)
            let purity = purityStateForBundle(bundleName, annotations: annotations)
            let hardware = annotations?.bundleHardware(bundleName) ?? []
            let isSink = bundleName == "display" || bundleName == "play"

            nodes[bundleName] = GraphNode(
                id: bundleName,
                name: bundleName,
                strandCount: bundle.strands.count,
                strandNames: bundle.strands.map { $0.name },
                backend: backend,
                purity: purity,
                isSink: isSink,
                hasCache: cacheBundles.contains(bundleName),
                hardware: hardware,
                dependencies: deps[bundleName] ?? [],
                dependents: dependents[bundleName] ?? []
            )
        }

        // Build edges
        var edges: [GraphEdge] = []
        for (name, nodeDeps) in deps {
            for dep in nodeDeps {
                edges.append(GraphEdge(from: dep, to: name))
            }
        }

        // Compute layers
        var layers: [String: Int] = [:]
        if let sortedNodes = coordinator.dependencyGraph?.topologicalSort() {
            for name in sortedNodes {
                let myDeps = deps[name] ?? []
                let layer = myDeps.isEmpty ? 0 : (myDeps.compactMap { layers[$0] }.max() ?? 0) + 1
                layers[name] = layer
            }
        } else {
            for name in nodes.keys {
                layers[name] = 0
            }
        }

        // Group by layer
        var layerGroups: [Int: [String]] = [:]
        for (name, layer) in layers {
            layerGroups[layer, default: []].append(name)
        }
        for layer in layerGroups.keys {
            layerGroups[layer]?.sort()
        }

        // Adaptive sizing based on graph complexity
        let nodeCount = nodes.count
        let layerCount = (layerGroups.keys.max() ?? 0) + 1
        let maxNodesInLayer = layerGroups.values.map { $0.count }.max() ?? 1

        var params = LayoutParams()

        // Scale down for larger graphs
        if nodeCount > 15 {
            params.nodeWidth = 64
            params.nodeHeight = 22
            params.layerSpacing = 85
        } else if nodeCount > 8 {
            params.nodeWidth = 68
            params.nodeHeight = 24
            params.layerSpacing = 90
        }

        // Dynamic vertical spacing
        let padding: CGFloat = 20
        let availableHeight = size.height - 2 * padding
        let minSpacing: CGFloat = 8
        let maxSpacing: CGFloat = 32
        params.nodeSpacing = max(minSpacing, min(maxSpacing,
            (availableHeight - params.nodeHeight * CGFloat(maxNodesInLayer)) / CGFloat(max(1, maxNodesInLayer - 1))))

        // Compute positions
        var positions: [String: CGPoint] = [:]
        let totalWidth = CGFloat(layerCount) * params.layerSpacing
        let xOffset = max(padding, (size.width - totalWidth) / 2)

        for (layer, nodeNames) in layerGroups {
            let totalHeight = CGFloat(nodeNames.count) * params.nodeHeight + CGFloat(nodeNames.count - 1) * params.nodeSpacing
            let startY = (size.height - totalHeight) / 2
            let x = xOffset + CGFloat(layer) * params.layerSpacing + params.nodeWidth / 2

            for (i, name) in nodeNames.enumerated() {
                let y = startY + CGFloat(i) * (params.nodeHeight + params.nodeSpacing) + params.nodeHeight / 2
                positions[name] = CGPoint(x: x, y: y)
            }
        }

        self.graphNodes = nodes
        self.graphEdges = edges
        self.nodePositions = positions
        self.layoutParams = params
    }

    // MARK: - Hit Testing

    private func hitTest(location: CGPoint) -> String? {
        for (name, pos) in nodePositions {
            let rect = CGRect(
                x: pos.x - layoutParams.nodeWidth / 2,
                y: pos.y - layoutParams.nodeHeight / 2,
                width: layoutParams.nodeWidth,
                height: layoutParams.nodeHeight
            )
            if rect.contains(location) {
                return name
            }
        }
        return nil
    }

    // MARK: - Drawing

    private func drawGraph(context: GraphicsContext, size: CGSize) {
        guard !graphNodes.isEmpty else {
            let text = Text("No graph")
                .font(.system(size: 11))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
            return
        }

        // Compute connected nodes for highlighting
        let connectedNodes: Set<String>
        let highlightNode = hoveredNode ?? selectedNode
        if let hn = highlightNode, let node = graphNodes[hn] {
            var connected = Set<String>([hn])
            connected.formUnion(node.dependencies)
            connected.formUnion(node.dependents)
            connectedNodes = connected
        } else {
            connectedNodes = Set(graphNodes.keys)
        }

        // Draw edges
        for edge in graphEdges {
            guard let fromPos = nodePositions[edge.from], let toPos = nodePositions[edge.to] else { continue }

            let isHighlighted = highlightNode == nil ||
                (connectedNodes.contains(edge.from) && connectedNodes.contains(edge.to))

            drawEdge(context: context, from: fromPos, to: toPos, isHighlighted: isHighlighted)
        }

        // Draw nodes
        for (name, node) in graphNodes {
            guard let pos = nodePositions[name] else { continue }

            let isHighlighted = connectedNodes.contains(name)
            let isHovered = hoveredNode == name
            let isSelected = selectedNode == name

            drawNode(context: context, node: node, position: pos, isHighlighted: isHighlighted, isHovered: isHovered, isSelected: isSelected)
        }
    }

    private func drawEdge(context: GraphicsContext, from: CGPoint, to: CGPoint, isHighlighted: Bool) {
        let startX = from.x + layoutParams.nodeWidth / 2
        let endX = to.x - layoutParams.nodeWidth / 2
        let midX = (startX + endX) / 2

        var path = Path()
        path.move(to: CGPoint(x: startX, y: from.y))
        path.addCurve(
            to: CGPoint(x: endX, y: to.y),
            control1: CGPoint(x: midX, y: from.y),
            control2: CGPoint(x: midX, y: to.y)
        )

        let baseColor = Color(NSColor.tertiaryLabelColor)
        let edgeColor = isHighlighted ? baseColor : baseColor.opacity(0.2)

        context.stroke(path, with: .color(edgeColor), lineWidth: isHighlighted ? 1.5 : 1)

        // Arrowhead
        let arrowSize: CGFloat = 6
        let arrowPath = Path { p in
            p.move(to: CGPoint(x: endX, y: to.y))
            p.addLine(to: CGPoint(x: endX - arrowSize, y: to.y - arrowSize / 2))
            p.addLine(to: CGPoint(x: endX - arrowSize, y: to.y + arrowSize / 2))
            p.closeSubpath()
        }
        context.fill(arrowPath, with: .color(edgeColor))
    }

    private func drawNode(context: GraphicsContext, node: GraphNode, position: CGPoint, isHighlighted: Bool, isHovered: Bool, isSelected: Bool) {
        let w = layoutParams.nodeWidth
        let h = layoutParams.nodeHeight
        let rect = CGRect(x: position.x - w / 2, y: position.y - h / 2, width: w, height: h)

        // Node color based on backend
        let nodeColor: Color
        if node.isSink {
            nodeColor = node.name == "display" ? .nodeVisual : .nodeAudio
        } else if let backend = node.backend {
            nodeColor = backend == "visual" ? .nodeVisual : (backend == "audio" ? .nodeAudio : .nodeCompute)
        } else {
            nodeColor = .nodeCompute
        }

        let opacity = isHighlighted ? 1.0 : 0.3

        // Shadow for hovered/selected
        if isHovered || isSelected {
            var shadowContext = context
            shadowContext.addFilter(.shadow(color: nodeColor.opacity(0.5), radius: 6, x: 0, y: 2))
            shadowContext.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(nodeColor.opacity(0.2)))
        }

        // Background
        let bgOpacity = (isHovered || isSelected) ? 0.25 : 0.12
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(nodeColor.opacity(bgOpacity * opacity)))

        // Border
        let borderWidth: CGFloat = isSelected ? 2 : (isHovered ? 1.5 : 1)
        let borderOpacity = (isHovered || isSelected) ? 0.8 : 0.5
        context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(nodeColor.opacity(borderOpacity * opacity)), lineWidth: borderWidth)

        // Sink indicator - outer glow
        if node.isSink && isHighlighted {
            let glowRect = rect.insetBy(dx: -3, dy: -3)
            context.stroke(Path(roundedRect: glowRect, cornerRadius: 7), with: .color(nodeColor.opacity(0.25)), lineWidth: 2)
        }

        // Node label
        let textColor = Color(NSColor.labelColor).opacity(opacity)
        let fontSize: CGFloat = layoutParams.nodeHeight > 24 ? 10 : 9
        let text = Text(node.name)
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .foregroundColor(textColor)
        context.draw(text, at: position, anchor: .center)

        // Strand count badge (top-right corner)
        if node.strandCount > 1 {
            let badgeX = rect.maxX - 2
            let badgeY = rect.minY + 2
            let badgeText = Text("\(node.strandCount)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(nodeColor.opacity(opacity * 0.9))
            context.draw(badgeText, at: CGPoint(x: badgeX, y: badgeY), anchor: .topTrailing)
        }

        // Cache indicator (small dot, bottom-right)
        if node.hasCache {
            let indicatorSize: CGFloat = 5
            let indicatorX = rect.maxX - 4
            let indicatorY = rect.maxY - 4
            context.fill(Circle().path(in: CGRect(x: indicatorX - indicatorSize/2, y: indicatorY - indicatorSize/2, width: indicatorSize, height: indicatorSize)),
                        with: .color(Color.orange.opacity(opacity * 0.8)))
        }

        // Layout indicator (small square, bottom-left)
        if layoutBundles.contains(node.name) {
            let indicatorSize: CGFloat = 5
            let indicatorX = rect.minX + 4
            let indicatorY = rect.maxY - 4
            context.fill(Path(CGRect(x: indicatorX - indicatorSize/2, y: indicatorY - indicatorSize/2, width: indicatorSize, height: indicatorSize)),
                        with: .color(Color.cyan.opacity(opacity * 0.8)))
        }
    }
}

// MARK: - Node Popover

struct NodePopover: View {
    let node: GraphNode
    let onDismiss: () -> Void
    var isInLayout: Bool = false
    var onToggleLayout: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Text(node.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            // Layout toggle button (any non-sink bundle: visual, audio, or pure)
            if let toggle = onToggleLayout, !node.isSink, node.name != "scope" {
                Button {
                    toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isInLayout ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                            .font(.system(size: 9))
                        Text(isInLayout ? "Remove from Layout" : "Add to Layout")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(isInLayout ? .primary : .secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Info rows
            VStack(alignment: .leading, spacing: 4) {
                if node.strandCount > 1 {
                    infoRow("Strands", value: "[\(node.strandNames.joined(separator: ", "))]")
                }

                if let backend = node.backend {
                    infoRow("Backend", value: backend, color: backend == "visual" ? .nodeVisual : .nodeAudio)
                }

                if let purity = node.purity {
                    let (label, color) = purityInfo(purity)
                    infoRow("Purity", value: label, color: color)
                }

                if node.hasCache {
                    infoRow("Cache", value: "stateful", color: .orange)
                }

                if !node.hardware.isEmpty {
                    let hwNames = node.hardware.map { hw -> String in
                        switch hw {
                        case .camera: return "camera"
                        case .microphone: return "mic"
                        case .speaker: return "speaker"
                        case .gpu: return "gpu"
                        case .custom(let n): return n
                        }
                    }
                    infoRow("Hardware", value: hwNames.joined(separator: ", "), color: .purple)
                }

                if !node.dependencies.isEmpty {
                    infoRow("Depends on", value: node.dependencies.sorted().joined(separator: ", "))
                }

                if !node.dependents.isEmpty {
                    infoRow("Used by", value: node.dependents.sorted().joined(separator: ", "))
                }
            }
        }
        .padding(8)
        .frame(minWidth: 140, maxWidth: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    private func infoRow(_ label: String, value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label + ":")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(2)
        }
    }

    private func purityInfo(_ purity: PurityState) -> (String, Color) {
        switch purity {
        case .pure: return ("pure", .green)
        case .stateful: return ("stateful", .orange)
        case .external: return ("external", .purple)
        }
    }
}

// MARK: - IRHardware Extension

extension IRHardware: Comparable {
    public static func < (lhs: IRHardware, rhs: IRHardware) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    var sortKey: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .speaker: return "speaker"
        case .gpu: return "gpu"
        case .custom(let name): return name
        }
    }
}
