// LayoutPanelView.swift - Unified layout panel for visual thumbnails and audio waveforms

import SwiftUI
import UniformTypeIdentifiers
import WEFTLib

// MARK: - Layout Item (unified model for drag reordering)

enum LayoutItemKind {
    case thumbnail(CGImage)
    case sparkline([Float])
    case audioScope(ScopeBuffer)
    case builtinScope(ScopeBuffer)
}

struct LayoutItem: Identifiable {
    let id: String  // bundle name (or "scope" for built-in)
    let kind: LayoutItemKind
}

struct LayoutPanelView: View {
    let layoutImages: [(bundleName: String, image: CGImage)]
    var layoutWaveforms: [String: [Float]] = [:]
    let scopeBuffer: ScopeBuffer?
    var layoutScopeBuffers: [String: ScopeBuffer] = [:]
    var expanded: Bool = false
    @Binding var layoutOrder: [String]
    let onRemoveBundle: (String) -> Void

    // Item size scales with expanded mode
    private var itemWidth: CGFloat { expanded ? 192 : 128 }
    private var itemHeight: CGFloat { expanded ? 140 : 80 }
    // Row height: item + label + spacing
    private var rowHeight: CGFloat { itemHeight + 20 + Spacing.sm }
    private var maxPanelHeight: CGFloat { expanded ? 400 : 240 }

    /// Builds an ordered list of all layout items, respecting user drag order
    private var orderedItems: [LayoutItem] {
        // Collect all available items by name
        var itemsByName: [String: LayoutItem] = [:]
        for img in layoutImages {
            itemsByName[img.bundleName] = LayoutItem(id: img.bundleName, kind: .thumbnail(img.image))
        }
        for (name, values) in layoutWaveforms {
            itemsByName[name] = LayoutItem(id: name, kind: .sparkline(values))
        }
        for (name, buffer) in layoutScopeBuffers {
            itemsByName[name] = LayoutItem(id: name, kind: .audioScope(buffer))
        }
        if let scope = scopeBuffer {
            itemsByName["scope"] = LayoutItem(id: "scope", kind: .builtinScope(scope))
        }

        // Order by layoutOrder, then append any new items not yet in the order
        var result: [LayoutItem] = []
        for name in layoutOrder {
            if let item = itemsByName.removeValue(forKey: name) {
                result.append(item)
            }
        }
        // Append remaining items (new ones not yet ordered)
        for name in itemsByName.keys.sorted() {
            result.append(itemsByName[name]!)
        }
        return result
    }

    @State private var draggedItem: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: Spacing.xs) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Layout")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.panelHeaderBackground)

            SubtleDivider(.horizontal)

            // Content: wrapping grid of thumbnails and waveforms
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: itemWidth + 8), spacing: Spacing.sm)],
                          alignment: .leading, spacing: Spacing.sm) {
                    ForEach(orderedItems) { item in
                        layoutItemView(for: item)
                            .opacity(draggedItem == item.id ? 0.4 : 1.0)
                            .onDrag {
                                draggedItem = item.id
                                return NSItemProvider(object: item.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: LayoutDropDelegate(
                                targetId: item.id,
                                draggedItem: $draggedItem,
                                layoutOrder: $layoutOrder,
                                allItems: orderedItems.map(\.id)
                            ))
                    }
                }
                .padding(Spacing.sm)
            }
            .frame(maxHeight: maxPanelHeight)
            .background(Color.canvasBackground)
            .animation(.easeInOut(duration: 0.15), value: expanded)
            .animation(.default, value: layoutOrder)
        }
    }

    @ViewBuilder
    private func layoutItemView(for item: LayoutItem) -> some View {
        switch item.kind {
        case .thumbnail(let image):
            LayoutThumbnailView(
                bundleName: item.id,
                image: image,
                width: itemWidth, height: itemHeight,
                onRemove: { onRemoveBundle(item.id) }
            )
        case .sparkline(let values):
            LayoutSparklineView(
                bundleName: item.id,
                values: values,
                width: itemWidth, height: itemHeight,
                onRemove: { onRemoveBundle(item.id) }
            )
        case .audioScope(let buffer):
            LayoutScopeView(
                scopeBuffer: buffer, label: item.id,
                width: itemWidth, height: itemHeight,
                onRemove: { onRemoveBundle(item.id) }
            )
        case .builtinScope(let buffer):
            LayoutScopeView(
                scopeBuffer: buffer, label: "scope",
                width: itemWidth, height: itemHeight
            )
        }
    }
}

// MARK: - Drop Delegate for Reordering

struct LayoutDropDelegate: DropDelegate {
    let targetId: String
    @Binding var draggedItem: String?
    @Binding var layoutOrder: [String]
    let allItems: [String]

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedItem, dragged != targetId else { return }

        // Ensure layoutOrder has all current items
        var order = layoutOrder
        for id in allItems where !order.contains(id) {
            order.append(id)
        }

        guard let fromIndex = order.firstIndex(of: dragged),
              let toIndex = order.firstIndex(of: targetId) else { return }

        withAnimation(.default) {
            order.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            layoutOrder = order
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Layout Thumbnail

struct LayoutThumbnailView: View {
    let bundleName: String
    let image: CGImage
    var width: CGFloat = 128
    var height: CGFloat = 80
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )

                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                }
            }

            Text(bundleName)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Layout Scope (audio waveforms in compact form)

struct LayoutScopeView: View {
    let scopeBuffer: ScopeBuffer
    var label: String = "scope"
    var width: CGFloat = 160
    var height: CGFloat = 80
    var onRemove: (() -> Void)? = nil
    @State private var isHovered = false

    private let displaySamples = 1024
    private let traceColors: [Color] = [
        .green, .cyan, .yellow, .orange, .pink, .mint, .indigo, .teal
    ]

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        drawTraces(context: context, size: size, date: timeline.date)
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                }

                if isHovered, let onRemove = onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                }
            }

            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .onHover { isHovered = $0 }
    }

    private func drawTraces(context: GraphicsContext, size: CGSize, date: Date) {
        let readCount = displaySamples * 2
        let snapshot = scopeBuffer.snapshot(count: readCount)
        guard !snapshot.isEmpty else { return }

        let strandCount = snapshot.count
        let laneHeight = size.height / CGFloat(strandCount)

        for (strandIdx, allSamples) in snapshot.enumerated() {
            let laneTop = CGFloat(strandIdx) * laneHeight
            let traceHeight = laneHeight
            let color = traceColors[strandIdx % traceColors.count]

            guard allSamples.count >= displaySamples else { continue }

            // Simple trigger: rising zero-crossing
            var triggerOffset = 0
            let searchEnd = allSamples.count - displaySamples
            for i in 1..<max(1, searchEnd) {
                if allSamples[i - 1] <= 0 && allSamples[i] > 0 {
                    triggerOffset = i
                    break
                }
            }

            let samples = Array(allSamples[triggerOffset..<(triggerOffset + displaySamples)])
            let xStep = size.width / CGFloat(samples.count - 1)

            var path = Path()
            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) * xStep
                let clamped = max(-1, min(1, sample))
                let normalized = CGFloat(clamped) * -0.5 + 0.5
                let y = laneTop + normalized * traceHeight
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}

// MARK: - Layout Sparkline (1D visual value over time)

struct LayoutSparklineView: View {
    let bundleName: String
    let values: [Float]
    var width: CGFloat = 160
    var height: CGFloat = 80
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    drawSparkline(context: context, size: size)
                }
                .frame(width: width, height: height)
                .background(Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )

                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(2)
                }
            }

            Text(bundleName)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onHover { isHovered = $0 }
    }

    private func drawSparkline(context: GraphicsContext, size: CGSize) {
        guard values.count > 1 else { return }

        let xStep = size.width / CGFloat(values.count - 1)
        let margin: CGFloat = 4

        // Draw mid-line
        var midPath = Path()
        midPath.move(to: CGPoint(x: 0, y: size.height / 2))
        midPath.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(midPath, with: .color(.white.opacity(0.1)), lineWidth: 0.5)

        // Draw value trace (values are [0, 1], map to full height with margin)
        var path = Path()
        for (i, value) in values.enumerated() {
            let x = CGFloat(i) * xStep
            let y = margin + (size.height - margin * 2) * CGFloat(1.0 - value)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(.green), lineWidth: 1.5)

        // Current value label
        if let last = values.last {
            let text = String(format: "%.2f", last)
            context.draw(
                Text(text)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.green.opacity(0.7)),
                at: CGPoint(x: size.width - 16, y: 8)
            )
        }
    }
}
