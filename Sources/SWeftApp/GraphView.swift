// GraphView.swift - Improved dependency graph visualization

import SwiftUI
import SWeftLib

// MARK: - Graph Data Model

struct GraphNode: Identifiable {
    let id: String  // bundle name
    let name: String
    let strandCount: Int
    let strandNames: [String]
    let backend: String?  // "visual" / "audio" / nil
    let purity: PurityState?
    let isSink: Bool
    let hasCache: Bool
    let hardware: Set<IRHardware>
    var position: CGPoint = .zero
    var layer: Int = 0
}

struct GraphEdge: Identifiable {
    var id: String { "\(from)->\(to)" }
    let from: String
    let to: String
    let isCacheDependency: Bool
}

// MARK: - Graph View

struct GraphView: View {
    let coordinator: Coordinator
    @State private var hoveredNode: String? = nil
    @State private var graphSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let graphData = buildGraphData(size: size)
                drawGraph(context: context, size: size, data: graphData)
            }
            .background(Color(NSColor.windowBackgroundColor))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredNode = hitTest(location: location, size: geometry.size)
                case .ended:
                    hoveredNode = nil
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                graphSize = newSize
            }
        }
    }

    // MARK: - Graph Data Building

    private func buildGraphData(size: CGSize) -> (nodes: [String: GraphNode], edges: [GraphEdge], positions: [String: CGPoint]) {
        guard coordinator.swatchGraph != nil, let program = coordinator.program else {
            return ([:], [], [:])
        }

        let deps = coordinator.dependencyGraph?.dependencies ?? [:]
        let annotations = coordinator.annotatedProgram
        let cacheDescriptors = coordinator.getCacheDescriptors() ?? []
        let cacheBundles = Set(cacheDescriptors.map { $0.bundleName })

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
                hardware: hardware
            )
        }

        // Build edges
        var edges: [GraphEdge] = []
        for (name, nodeDeps) in deps {
            for dep in nodeDeps {
                // Check if this is a cache dependency
                let isCacheDep = cacheDescriptors.contains { desc in
                    desc.bundleName == name && expressionReferencesBundles(desc.signalExpr, bundles: [dep])
                }
                edges.append(GraphEdge(from: dep, to: name, isCacheDependency: isCacheDep))
            }
        }

        // Compute positions
        let positions = computeLayout(nodes: nodes, deps: deps, size: size)

        return (nodes, edges, positions)
    }

    /// Check if an expression references any of the given bundles
    private func expressionReferencesBundles(_ expr: IRExpr, bundles: Set<String>) -> Bool {
        switch expr {
        case .index(let bundle, let indexExpr):
            return bundles.contains(bundle) || expressionReferencesBundles(indexExpr, bundles: bundles)
        case .binaryOp(_, let left, let right):
            return expressionReferencesBundles(left, bundles: bundles) || expressionReferencesBundles(right, bundles: bundles)
        case .unaryOp(_, let operand):
            return expressionReferencesBundles(operand, bundles: bundles)
        case .builtin(_, let args):
            return args.contains { expressionReferencesBundles($0, bundles: bundles) }
        case .call(_, let args):
            return args.contains { expressionReferencesBundles($0, bundles: bundles) }
        case .extract(let call, _):
            return expressionReferencesBundles(call, bundles: bundles)
        case .remap(let base, let subs):
            return expressionReferencesBundles(base, bundles: bundles) ||
                   subs.values.contains { expressionReferencesBundles($0, bundles: bundles) }
        case .num, .param, .cacheRead:
            return false
        }
    }

    // MARK: - Layout

    private func computeLayout(nodes: [String: GraphNode], deps: [String: Set<String>], size: CGSize) -> [String: CGPoint] {
        // Compute layers using topological sort
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

        // Layout constants - compact sizing
        let nodeWidth: CGFloat = 64
        let nodeHeight: CGFloat = 20
        let layerSpacing: CGFloat = 90
        let padding: CGFloat = 16

        // Dynamic node spacing based on available space
        let maxNodesInLayer = layerGroups.values.map { $0.count }.max() ?? 1
        let availableHeight = size.height - 2 * padding
        let minSpacing: CGFloat = 6
        let maxSpacing: CGFloat = 24
        let dynamicSpacing = max(minSpacing, min(maxSpacing,
            (availableHeight - nodeHeight * CGFloat(maxNodesInLayer)) / CGFloat(max(1, maxNodesInLayer - 1))))

        // Calculate positions
        var positions: [String: CGPoint] = [:]
        let layerCount = (layerGroups.keys.max() ?? 0) + 1
        let totalWidth = CGFloat(layerCount) * layerSpacing
        let xOffset = max(padding, (size.width - totalWidth) / 2)

        for (layer, nodeNames) in layerGroups {
            let totalHeight = CGFloat(nodeNames.count) * nodeHeight + CGFloat(nodeNames.count - 1) * dynamicSpacing
            let startY = (size.height - totalHeight) / 2
            let x = xOffset + CGFloat(layer) * layerSpacing + nodeWidth / 2

            for (i, name) in nodeNames.enumerated() {
                let y = startY + CGFloat(i) * (nodeHeight + dynamicSpacing) + nodeHeight / 2
                positions[name] = CGPoint(x: x, y: y)
            }
        }

        return positions
    }

    // MARK: - Hit Testing

    private func hitTest(location: CGPoint, size: CGSize) -> String? {
        let graphData = buildGraphData(size: size)
        let nodeWidth: CGFloat = 64
        let nodeHeight: CGFloat = 20

        for (name, pos) in graphData.positions {
            let rect = CGRect(
                x: pos.x - nodeWidth / 2,
                y: pos.y - nodeHeight / 2,
                width: nodeWidth,
                height: nodeHeight
            )
            if rect.contains(location) {
                return name
            }
        }
        return nil
    }

    // MARK: - Drawing

    private func drawGraph(context: GraphicsContext, size: CGSize, data: (nodes: [String: GraphNode], edges: [GraphEdge], positions: [String: CGPoint])) {
        let (nodes, edges, positions) = data

        guard !nodes.isEmpty else {
            let text = Text("No graph")
                .font(.system(size: 11))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
            return
        }

        let deps = coordinator.dependencyGraph?.dependencies ?? [:]

        // Compute connected nodes for hover highlighting
        let connectedNodes: Set<String>
        if let hovered = hoveredNode {
            var connected = Set<String>([hovered])
            // Add dependencies (upstream)
            if let upstream = deps[hovered] {
                connected.formUnion(upstream)
            }
            // Add dependents (downstream)
            for (name, nodeDeps) in deps {
                if nodeDeps.contains(hovered) {
                    connected.insert(name)
                }
            }
            connectedNodes = connected
        } else {
            connectedNodes = Set(nodes.keys)
        }

        let nodeWidth: CGFloat = 64
        let nodeHeight: CGFloat = 20

        // Draw edges
        for edge in edges {
            guard let fromPos = positions[edge.from], let toPos = positions[edge.to] else { continue }

            let isHighlighted = hoveredNode == nil ||
                (connectedNodes.contains(edge.from) && connectedNodes.contains(edge.to))

            drawEdge(
                context: context,
                from: fromPos,
                to: toPos,
                nodeWidth: nodeWidth,
                isCacheDependency: edge.isCacheDependency,
                isHighlighted: isHighlighted
            )
        }

        // Draw nodes
        for (name, node) in nodes {
            guard let pos = positions[name] else { continue }

            let isHighlighted = connectedNodes.contains(name)
            let isHovered = hoveredNode == name

            drawNode(
                context: context,
                node: node,
                position: pos,
                width: nodeWidth,
                height: nodeHeight,
                isHighlighted: isHighlighted,
                isHovered: isHovered
            )
        }
    }

    private func drawEdge(context: GraphicsContext, from: CGPoint, to: CGPoint, nodeWidth: CGFloat, isCacheDependency: Bool, isHighlighted: Bool) {
        let startX = from.x + nodeWidth / 2
        let endX = to.x - nodeWidth / 2
        let midX = (startX + endX) / 2

        var path = Path()
        path.move(to: CGPoint(x: startX, y: from.y))
        path.addCurve(
            to: CGPoint(x: endX, y: to.y),
            control1: CGPoint(x: midX, y: from.y),
            control2: CGPoint(x: midX, y: to.y)
        )

        let baseColor = isCacheDependency ? Color.orange : Color(NSColor.tertiaryLabelColor)
        let edgeColor = isHighlighted ? baseColor : baseColor.opacity(0.25)
        let lineWidth: CGFloat = isCacheDependency ? 1.0 : 1.5

        if isCacheDependency {
            // Dashed line for cache dependencies
            let dashed = StrokeStyle(lineWidth: lineWidth, dash: [4, 3])
            context.stroke(path, with: .color(edgeColor), style: dashed)
        } else {
            context.stroke(path, with: .color(edgeColor), lineWidth: lineWidth)
        }

        // Arrowhead
        let arrowSize: CGFloat = 5
        let arrowPath = Path { p in
            p.move(to: CGPoint(x: endX, y: to.y))
            p.addLine(to: CGPoint(x: endX - arrowSize, y: to.y - arrowSize / 2))
            p.addLine(to: CGPoint(x: endX - arrowSize, y: to.y + arrowSize / 2))
            p.closeSubpath()
        }
        context.fill(arrowPath, with: .color(edgeColor))
    }

    private func drawNode(context: GraphicsContext, node: GraphNode, position: CGPoint, width: CGFloat, height: CGFloat, isHighlighted: Bool, isHovered: Bool) {
        let rect = CGRect(x: position.x - width / 2, y: position.y - height / 2, width: width, height: height)

        // Determine node color
        let nodeColor: Color
        if node.isSink {
            nodeColor = node.name == "display" ? .nodeVisual : .nodeAudio
        } else if let backend = node.backend {
            nodeColor = backend == "visual" ? .nodeVisual : (backend == "audio" ? .nodeAudio : .nodeCompute)
        } else {
            nodeColor = .nodeCompute
        }

        let opacity = isHighlighted ? 1.0 : 0.35

        // Shadow for hovered nodes
        if isHovered {
            var shadowContext = context
            shadowContext.addFilter(.shadow(color: nodeColor.opacity(0.4), radius: 4, x: 0, y: 1))
            shadowContext.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(nodeColor.opacity(0.15)))
        }

        // Node background
        let bgOpacity = isHovered ? 0.2 : 0.1
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(nodeColor.opacity(bgOpacity * opacity)))

        // Node border
        let borderOpacity = isHovered ? 0.7 : 0.4
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(nodeColor.opacity(borderOpacity * opacity)), lineWidth: isHovered ? 1.5 : 1)

        // Sink glow
        if node.isSink && isHighlighted {
            let glowRect = rect.insetBy(dx: -2, dy: -2)
            context.stroke(Path(roundedRect: glowRect, cornerRadius: 6), with: .color(nodeColor.opacity(0.2)), lineWidth: 2)
        }

        // Build label: "name[n]" or just "name" for single-strand
        let strandSuffix = node.strandCount > 1 ? "[\(node.strandCount)]" : ""
        let labelText = node.name + strandSuffix

        // Calculate text layout
        let textX = position.x
        let textY = position.y

        // Draw backend indicator dot (left side)
        let dotSize: CGFloat = 4
        let dotX = rect.minX + 5
        let dotY = position.y
        let dotColor = node.backend == "visual" ? Color.nodeVisual : (node.backend == "audio" ? Color.nodeAudio : Color.nodeCompute)
        context.fill(Circle().path(in: CGRect(x: dotX - dotSize/2, y: dotY - dotSize/2, width: dotSize, height: dotSize)), with: .color(dotColor.opacity(opacity)))

        // Draw purity indicator (small dot after backend dot)
        if let purity = node.purity {
            let purityColor: Color
            switch purity {
            case .pure: purityColor = .green
            case .stateful: purityColor = .orange
            case .external: purityColor = .purple
            }
            let purityDotSize: CGFloat = 3
            let purityX = dotX + dotSize + 2
            context.fill(Circle().path(in: CGRect(x: purityX - purityDotSize/2, y: dotY - purityDotSize/2, width: purityDotSize, height: purityDotSize)), with: .color(purityColor.opacity(opacity * 0.8)))
        }

        // Draw cache indicator (right side)
        if node.hasCache {
            let cacheText = Text("↺")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(Color.orange.opacity(opacity * 0.9))
            context.draw(cacheText, at: CGPoint(x: rect.maxX - 7, y: textY), anchor: .center)
        }

        // Draw main label (centered, accounting for indicators)
        let textColor = Color(NSColor.labelColor).opacity(opacity)
        let text = Text(labelText)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(textColor)

        // Offset text slightly right to account for left indicators
        let labelOffset: CGFloat = node.purity != nil ? 6 : 3
        context.draw(text, at: CGPoint(x: textX + labelOffset, y: textY), anchor: .center)

        // Draw hardware icons on hover
        if isHovered && !node.hardware.isEmpty {
            var iconX = rect.minX
            let iconY = rect.maxY + 8
            for hw in node.hardware.sorted(by: { $0.description < $1.description }) {
                let iconName: String
                switch hw {
                case .camera: iconName = "camera.fill"
                case .microphone: iconName = "mic.fill"
                case .speaker: iconName = "speaker.wave.2.fill"
                case .gpu: iconName = "cpu"
                case .custom(let name): iconName = name
                }

                if let cgImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let iconRect = CGRect(x: iconX, y: iconY - 5, width: 10, height: 10)
                    context.draw(Image(decorative: cgImage, scale: 2), in: iconRect)
                }
                iconX += 12
            }
        }
    }
}

// MARK: - IRHardware Extension

extension IRHardware: Comparable {
    public static func < (lhs: IRHardware, rhs: IRHardware) -> Bool {
        lhs.description < rhs.description
    }

    var description: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .speaker: return "speaker"
        case .gpu: return "gpu"
        case .custom(let name): return name
        }
    }
}
