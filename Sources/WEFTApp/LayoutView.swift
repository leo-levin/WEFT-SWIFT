// LayoutView.swift - Flat 2D dimension flow visualization

import SwiftUI
import Combine
import WEFTLib

// MARK: - Layout State

class LayoutState: ObservableObject {
    @Published var layers: [LoomLayer] = []
    @Published var selectedSampleIndices: Set<Int> = []

    // Region (normalized canvas coordinates)
    @Published var regionMin: SIMD2<Double> = SIMD2(0.0, 0.0)
    @Published var regionMax: SIMD2<Double> = SIMD2(1.0, 1.0)

    // Controls
    @Published var resolution: Int = 16
    @Published var isPlaying: Bool = true
    @Published var scrubTime: Double = 0.0

    // Source node name
    @Published var sourceNodeName: String? = nil

    // Non-published per-tick data — avoids cascading SwiftUI invalidation.
    var samples: [[SIMD2<Double>]] = []
    var cachedRanges: [(min: SIMD2<Double>, max: SIMD2<Double>)] = []
    var samplesResolution: Int = 16
    var evalInFlight: Bool = false

    var sampleCount: Int { resolution * resolution }

    static let maxResolution = 50
}

// MARK: - Panel Layout (computed geometry for single-canvas drawing)

private struct PanelRect {
    let layerIndices: [Int]
    let label: String
    let rect: CGRect       // position within the canvas
    let isInput: Bool
    let isPlane: Bool
}

// MARK: - Layout View

struct LayoutView: View {
    let coordinator: Coordinator
    @Binding var loomNodeName: String?
    @StateObject private var state = LayoutState()
    @State private var playStartWallTime: Double = 0
    @State private var playStartScrubTime: Double = 0
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @State private var drawVersion: Int = 0

    // Background evaluation — .utility QoS to avoid starving Metal rendering
    private let evaluationQueue = DispatchQueue(label: "layout.evaluation", qos: .utility)

    // Preview resolution during playback
    @State private var isShowingPreview = false
    @State private var refinementTask: Task<Void, Never>? = nil
    private let previewResolution = 8

    // Stable ranges during playback
    @State private var lockedRanges: [(min: SIMD2<Double>, max: SIMD2<Double>)]? = nil

    // Keyboard focus
    @FocusState private var canvasFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if state.layers.isEmpty {
                EmptyStateView(
                    "rectangle.split.3x3",
                    message: "No chain selected",
                    hint: "Select a node in Graph and tap \"View in Layout\""
                )
            } else {
                HSplitView {
                    layoutCanvas
                        .frame(minWidth: 200)
                    LayoutLayerPanel(state: state, coordinator: coordinator)
                        .frame(minWidth: 140, idealWidth: 170, maxWidth: 220)
                }

                SubtleDivider(.horizontal)

                LayoutControls(state: state, coordinator: coordinator)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress { key in handleKeyPress(key) }
        .onAppear {
            canvasFocused = true
            if let name = loomNodeName {
                setupChain(for: name)
            }
        }
        .onChange(of: loomNodeName) { _, newName in
            if let name = newName {
                setupChain(for: name)
            }
        }
        .onChange(of: state.resolution) { _, _ in
            refinementTask?.cancel()
            state.selectedSampleIndices = []
            refreshSamples(forceFullResolution: true)
        }
        .onChange(of: state.regionMin) { _, _ in
            refinementTask?.cancel()
            refreshSamples()
        }
        .onChange(of: state.regionMax) { _, _ in
            refinementTask?.cancel()
            refreshSamples()
        }
        .onChange(of: state.scrubTime) { _, _ in
            refinementTask?.cancel()
            if !state.isPlaying { refreshSamples() }
        }
        .onChange(of: state.layers.count) { _, _ in refreshSamples() }
        .task(id: state.isPlaying) {
            if state.isPlaying {
                refinementTask?.cancel()
                playStartWallTime = Date().timeIntervalSinceReferenceDate
                playStartScrubTime = state.scrubTime
                lockedRanges = state.cachedRanges.isEmpty ? nil : state.cachedRanges
                while !Task.isCancelled {
                    refreshSamples()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            } else {
                let elapsed = Date().timeIntervalSinceReferenceDate - playStartWallTime
                state.scrubTime = playStartScrubTime + elapsed
                lockedRanges = nil
                if isShowingPreview {
                    scheduleRefinement()
                }
            }
        }
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ key: KeyPress) -> KeyPress.Result {
        switch key.key {
        case .space:
            state.isPlaying.toggle()
            return .handled
        case .escape:
            state.selectedSampleIndices = []
            return .handled
        default:
            break
        }
        if let char = key.characters.first {
            switch char {
            case "0":
                state.regionMin = SIMD2(0, 0)
                state.regionMax = SIMD2(1, 1)
                zoom = 1.0
                baseZoom = 1.0
                return .handled
            case "+", "=":
                state.resolution = min(LayoutState.maxResolution, state.resolution + 2)
                return .handled
            case "-", "_":
                state.resolution = max(2, state.resolution - 2)
                return .handled
            default:
                break
            }
        }
        return .ignored
    }

    // MARK: - Single Canvas

    private var layoutCanvas: some View {
        Canvas { context, size in
            // Apply zoom centered in the canvas
            var ctx = context
            let cx = size.width / 2
            let cy = size.height / 2
            ctx.translateBy(x: cx, y: cy)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: -cx, y: -cy)

            let panels = computePanelLayout(in: size)
            // Read drawVersion to trigger Canvas redraw
            let _ = drawVersion
            let samples = state.samples
            let selected = state.selectedSampleIndices
            let res = state.samplesResolution

            for panel in panels {
                let bg = Path(roundedRect: panel.rect, cornerRadius: 4)
                ctx.fill(bg, with: .color(.black.opacity(0.3)))

                if panel.isInput && panel.isPlane {
                    drawInputGrid(context: ctx, panel: panel, res: res, selected: selected)
                } else if panel.isPlane {
                    drawPlanePanel(context: ctx, panel: panel, samples: samples, res: res, selected: selected)
                } else {
                    drawStripPanel(context: ctx, panel: panel, samples: samples, res: res, selected: selected)
                }

                let label = Text(panel.label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                let labelPt = CGPoint(x: panel.rect.midX, y: panel.rect.maxY + 10)
                ctx.draw(label, at: labelPt, anchor: .top)
            }
        }
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, s in canvasSize = s }
            }
        )
        .overlay(alignment: .topTrailing) {
            if isShowingPreview {
                Text("...")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(4)
            }
        }
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    handleCanvasTap(at: value.location)
                }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    zoom = max(0.5, min(4.0, baseZoom * value.magnification))
                }
                .onEnded { value in
                    zoom = max(0.5, min(4.0, baseZoom * value.magnification))
                    baseZoom = zoom
                }
        )
    }

    // MARK: - Panel Layout Computation

    private let panelHeight: CGFloat = 120
    private let planeWidth: CGFloat = 120
    private let stripWidth: CGFloat = 30
    private let panelGap: CGFloat = 16
    private let padding: CGFloat = 12
    private let labelSpace: CGFloat = 24

    private func computePanelLayout(in size: CGSize) -> [PanelRect] {
        let layers = state.layers
        guard !layers.isEmpty else { return [] }

        // Group consecutive layers by bundle name
        var groups: [(bundleName: String, indices: [Int], label: String)] = []
        var i = 0
        while i < layers.count {
            let name = layers[i].bundleName
            let start = i
            i += 1
            while i < layers.count && layers[i].bundleName == name {
                i += 1
            }
            let indices = Array(start..<i)
            let label = indices.count == 1 ? layers[indices[0]].label : name
            groups.append((name, indices, label))
        }

        // First pass: compute panel widths
        struct PanelInfo {
            let indices: [Int]
            let label: String
            let isInput: Bool
            let isPlane: Bool
            let width: CGFloat
        }
        var infos: [PanelInfo] = []

        for (gi, group) in groups.enumerated() {
            let isInput = (gi == 0)
            let hasPlane = group.indices.contains { layers[$0].type.isPlane }

            if hasPlane && group.indices.count <= 2 {
                let li = group.indices.first(where: { layers[$0].type.isPlane })!
                infos.append(PanelInfo(indices: [li], label: group.label, isInput: isInput, isPlane: true, width: planeWidth))
            } else if group.indices.count == 1 {
                infos.append(PanelInfo(indices: group.indices, label: group.label, isInput: isInput, isPlane: false, width: stripWidth))
            } else {
                let groupWidth = CGFloat(group.indices.count) * stripWidth + CGFloat(group.indices.count - 1) * 2
                infos.append(PanelInfo(indices: group.indices, label: group.label, isInput: isInput, isPlane: false, width: groupWidth))
            }
        }

        // Compute total width and center offset
        let totalWidth = infos.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(max(0, infos.count - 1)) * panelGap
        let xOffset = max(padding, (size.width - totalWidth) / 2)
        let yOffset = max(padding, (size.height - panelHeight - labelSpace) / 2)

        // Second pass: lay out panels centered
        var panels: [PanelRect] = []
        var x = xOffset

        for info in infos {
            panels.append(PanelRect(
                layerIndices: info.indices,
                label: info.label,
                rect: CGRect(x: x, y: yOffset, width: info.width, height: panelHeight),
                isInput: info.isInput,
                isPlane: info.isPlane
            ))
            x += info.width + panelGap
        }

        return panels
    }

    // MARK: - Drawing

    private func drawInputGrid(context: GraphicsContext, panel: PanelRect, res: Int, selected: Set<Int>) {
        guard res > 0 else { return }
        let r = panel.rect

        for yi in 0..<res {
            for xi in 0..<res {
                let si = yi * res + xi
                let nx = res <= 1 ? 0.5 : Double(xi) / Double(res - 1)
                let ny = res <= 1 ? 0.5 : Double(yi) / Double(res - 1)
                let px = r.minX + nx * r.width
                let py = r.minY + (1.0 - ny) * r.height

                let sel = selected.contains(si)
                let rad: CGFloat = sel ? 3.5 : 1.5
                let opacity: Double = sel ? 1.0 : 0.7

                context.fill(
                    Path(ellipseIn: CGRect(x: px - rad, y: py - rad, width: rad * 2, height: rad * 2)),
                    with: .color(sampleColor(si, res: res).opacity(opacity))
                )
            }
        }
    }

    private func drawPlanePanel(context: GraphicsContext, panel: PanelRect, samples: [[SIMD2<Double>]], res: Int, selected: Set<Int>) {
        let r = panel.rect
        // Faint crosshair
        var hLine = Path(); hLine.move(to: CGPoint(x: r.minX, y: r.midY)); hLine.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        var vLine = Path(); vLine.move(to: CGPoint(x: r.midX, y: r.minY)); vLine.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        let guide: GraphicsContext.Shading = .color(.white.opacity(0.08))
        context.stroke(hLine, with: guide, lineWidth: 0.5)
        context.stroke(vLine, with: guide, lineWidth: 0.5)

        guard let li = panel.layerIndices.first else { return }
        let ranges = currentRanges()
        guard li < ranges.count else { return }
        let range = ranges[li]
        guard range.max.x > range.min.x || range.max.y > range.min.y else { return }

        let hasSelection = !selected.isEmpty

        // Unselected dots: additive blend so overlaps accumulate (shows convergence)
        var additiveCtx = context
        additiveCtx.blendMode = .plusLighter
        for si in 0..<samples.count where !selected.contains(si) {
            guard li < samples[si].count else { continue }
            let val = samples[si][li]
            let px = r.minX + norm(val.x, range.min.x, range.max.x) * r.width
            let py = r.minY + (1.0 - norm(val.y, range.min.y, range.max.y)) * r.height
            let color = sampleColor(si, res: res)
            let opacity: Double = hasSelection ? 0.15 : 0.35
            additiveCtx.fill(
                Path(ellipseIn: CGRect(x: px - 1.5, y: py - 1.5, width: 3, height: 3)),
                with: .color(color.opacity(opacity))
            )
        }

        // Selected dots: normal blend, on top
        for si in selected {
            guard si < samples.count, li < samples[si].count else { continue }
            let val = samples[si][li]
            let px = r.minX + norm(val.x, range.min.x, range.max.x) * r.width
            let py = r.minY + (1.0 - norm(val.y, range.min.y, range.max.y)) * r.height
            context.fill(
                Path(ellipseIn: CGRect(x: px - 3.5, y: py - 3.5, width: 7, height: 7)),
                with: .color(sampleColor(si, res: res))
            )
        }
    }

    private func drawStripPanel(context: GraphicsContext, panel: PanelRect, samples: [[SIMD2<Double>]], res: Int, selected: Set<Int>) {
        let r = panel.rect
        let indices = panel.layerIndices
        let stripCount = indices.count
        let eachWidth = stripCount > 1 ? (r.width - CGFloat(stripCount - 1) * 2) / CGFloat(stripCount) : r.width

        // Faint center lines
        for si in 0..<stripCount {
            let cx = r.minX + (CGFloat(si) * (eachWidth + 2)) + eachWidth / 2
            var line = Path(); line.move(to: CGPoint(x: cx, y: r.minY)); line.addLine(to: CGPoint(x: cx, y: r.maxY))
            context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
        }

        let ranges = currentRanges()
        let hasSelection = !selected.isEmpty

        var additiveCtx = context
        additiveCtx.blendMode = .plusLighter

        for (stripIdx, li) in indices.enumerated() {
            let stripX = r.minX + CGFloat(stripIdx) * (eachWidth + 2)
            let cx = stripX + eachWidth / 2
            guard li < ranges.count else { continue }
            let range = ranges[li]
            guard range.max.x > range.min.x || (range.min.x == range.max.x && !range.min.x.isInfinite) else { continue }

            // Unselected: additive blend
            for si in 0..<samples.count where !selected.contains(si) {
                guard li < samples[si].count else { continue }
                let val = samples[si][li]
                let py = r.minY + (1.0 - norm(val.x, range.min.x, range.max.x)) * r.height
                let opacity: Double = hasSelection ? 0.15 : 0.35
                additiveCtx.fill(
                    Path(ellipseIn: CGRect(x: cx - 1.5, y: py - 1.5, width: 3, height: 3)),
                    with: .color(sampleColor(si, res: res).opacity(opacity))
                )
            }

            // Selected: normal blend, on top
            for si in selected {
                guard si < samples.count, li < samples[si].count else { continue }
                let val = samples[si][li]
                let py = r.minY + (1.0 - norm(val.x, range.min.x, range.max.x)) * r.height
                context.fill(
                    Path(ellipseIn: CGRect(x: cx - 3.5, y: py - 3.5, width: 7, height: 7)),
                    with: .color(sampleColor(si, res: res))
                )
            }
        }
    }

    // MARK: - Tap Handling

    @State private var canvasSize: CGSize = .zero

    private func handleCanvasTap(at location: CGPoint) {
        // Transform tap location into zoomed coordinate space
        let cx = canvasSize.width / 2
        let cy = canvasSize.height / 2
        let loc = CGPoint(
            x: (location.x - cx) / zoom + cx,
            y: (location.y - cy) / zoom + cy
        )
        let location = loc

        // Recompute panels (cheap, no evaluation)
        let panels = computePanelLayout(in: canvasSize)

        // Find which panel was tapped
        guard let panel = panels.first(where: { $0.rect.insetBy(dx: -8, dy: -8).contains(location) }) else {
            state.selectedSampleIndices = []
            return
        }

        if panel.isInput {
            handleInputGridTap(at: location, panel: panel)
        } else {
            handleDataPanelTap(at: location, panel: panel)
        }
    }

    private func handleInputGridTap(at location: CGPoint, panel: PanelRect) {
        let res = state.samplesResolution
        guard res > 0 else { return }
        let r = panel.rect

        let nx = (location.x - r.minX) / r.width
        let ny = 1.0 - (location.y - r.minY) / r.height
        let xi = max(0, min(res - 1, Int(round(nx * Double(res - 1)))))
        let yi = max(0, min(res - 1, Int(round(ny * Double(res - 1)))))
        let si = yi * res + xi

        if state.selectedSampleIndices.contains(si) {
            state.selectedSampleIndices.remove(si)
        } else {
            state.selectedSampleIndices.insert(si)
        }
    }

    private func handleDataPanelTap(at location: CGPoint, panel: PanelRect) {
        let samples = state.samples
        guard !samples.isEmpty else { return }
        guard let li = panel.layerIndices.first, li < state.layers.count else { return }

        let r = panel.rect
        let ranges = currentRanges()
        guard li < ranges.count else { return }
        let range = ranges[li]
        var bestDist = Double.infinity
        var bestSample = -1

        for si in 0..<samples.count {
            guard li < samples[si].count else { continue }
            let val = samples[si][li]

            let px: Double
            let py: Double
            if panel.isPlane {
                px = r.minX + norm(val.x, range.min.x, range.max.x) * r.width
                py = r.minY + (1.0 - norm(val.y, range.min.y, range.max.y)) * r.height
            } else {
                px = r.midX
                py = r.minY + (1.0 - norm(val.x, range.min.x, range.max.x)) * r.height
            }

            let dx = px - location.x
            let dy = py - location.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < bestDist { bestDist = dist; bestSample = si }
        }

        if bestDist < 20 && bestSample >= 0 {
            if state.selectedSampleIndices.contains(bestSample) {
                state.selectedSampleIndices.remove(bestSample)
            } else {
                state.selectedSampleIndices.insert(bestSample)
            }
        } else {
            state.selectedSampleIndices = []
        }
    }

    // MARK: - Setup

    private func setupChain(for bundleName: String) {
        guard let program = coordinator.program,
              let graph = coordinator.dependencyGraph else { return }

        let tracer = ChainTracer(
            program: program,
            graph: graph,
            swatchGraph: coordinator.swatchGraph
        )
        let specs = tracer.trace(from: bundleName)
        guard !specs.isEmpty else { return }

        let layers = specs.enumerated().map { (i, spec) -> LoomLayer in
            let t = specs.count <= 1 ? 0.0 : Double(i) / Double(specs.count - 1)
            return LoomLayer(from: spec, color: layerColor(t: t))
        }

        state.layers = layers
        state.sourceNodeName = bundleName
        state.selectedSampleIndices = []
        refreshSamples()
    }

    private func layerColor(t: Double) -> Color {
        if t <= 0.5 {
            let s = t * 2
            return Color(red: 1.0 - s * 0.5, green: 0.4 - s * 0.2, blue: 0.1 + s * 0.7)
        } else {
            let s = (t - 0.5) * 2
            return Color(red: 0.5 - s * 0.2, green: 0.2 + s * 0.2, blue: 0.8 + s * 0.2)
        }
    }

    // MARK: - Evaluation

    private func refreshSamples(forceFullResolution: Bool = false) {
        guard !state.evalInFlight else { return }
        state.evalInFlight = true

        let usePreview = !forceFullResolution && state.isPlaying
        let effectiveResolution = usePreview ? min(state.resolution, previewResolution) : state.resolution

        let resolution = effectiveResolution
        let regionMin = state.regionMin
        let regionMax = state.regionMax
        let time = state.isPlaying
            ? playStartScrubTime + (Date().timeIntervalSinceReferenceDate - playStartWallTime)
            : state.scrubTime
        let layers = state.layers

        guard let program = coordinator.program, !layers.isEmpty else {
            state.samples = []
            state.evalInFlight = false
            return
        }
        let sampler = coordinator.buildResourceSampler()

        evaluationQueue.async {
            let newSamples = Self.computeSamples(
                resolution: resolution,
                regionMin: regionMin,
                regionMax: regionMax,
                time: time,
                layers: layers,
                program: program,
                sampler: sampler
            )
            let newRanges = Self.computeRanges(samples: newSamples, layerCount: layers.count)

            DispatchQueue.main.async {
                // Write non-published bookkeeping (no SwiftUI invalidation)
                self.state.samples = newSamples
                self.state.samplesResolution = resolution
                self.state.cachedRanges = newRanges
                self.state.evalInFlight = false

                // Only @State writes: drawVersion (redraws Canvas) and isShowingPreview if changed
                let preview = resolution != self.state.resolution
                if self.isShowingPreview != preview {
                    self.isShowingPreview = preview
                }
                self.drawVersion += 1

                if usePreview && !self.state.isPlaying {
                    self.scheduleRefinement()
                }
            }
        }
    }

    private func scheduleRefinement() {
        refinementTask?.cancel()
        refinementTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.refreshSamples(forceFullResolution: true)
            }
        }
    }

    private static func computeSamples(
        resolution: Int,
        regionMin: SIMD2<Double>,
        regionMax: SIMD2<Double>,
        time: Double,
        layers: [LoomLayer],
        program: IRProgram,
        sampler: ResourceSampler?
    ) -> [[SIMD2<Double>]] {
        let interpreter = IRInterpreter(program: program, resourceSampler: sampler)
        var result: [[SIMD2<Double>]] = []
        result.reserveCapacity(resolution * resolution)
        for yi in 0..<resolution {
            for xi in 0..<resolution {
                result.append(evaluateSample(
                    xi: xi, yi: yi, resolution: resolution,
                    regionMin: regionMin, regionMax: regionMax,
                    time: time, layers: layers, interpreter: interpreter
                ))
            }
        }
        return result
    }

    private static func computeRanges(samples: [[SIMD2<Double>]], layerCount: Int) -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        var ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)] = Array(
            repeating: (SIMD2(.infinity, .infinity), SIMD2(-.infinity, -.infinity)),
            count: layerCount
        )
        for sample in samples {
            for (li, val) in sample.enumerated() where li < layerCount {
                ranges[li].min = SIMD2(Swift.min(ranges[li].min.x, val.x), Swift.min(ranges[li].min.y, val.y))
                ranges[li].max = SIMD2(Swift.max(ranges[li].max.x, val.x), Swift.max(ranges[li].max.y, val.y))
            }
        }
        return ranges
    }

    private static func evaluateSample(
        xi: Int, yi: Int, resolution: Int,
        regionMin: SIMD2<Double>, regionMax: SIMD2<Double>,
        time: Double, layers: [LoomLayer],
        interpreter: IRInterpreter
    ) -> [SIMD2<Double>] {
        let x = regionMin.x + (regionMax.x - regionMin.x)
            * (resolution <= 1 ? 0.5 : Double(xi) / Double(resolution - 1))
        let y = regionMin.y + (regionMax.y - regionMin.y)
            * (resolution <= 1 ? 0.5 : Double(yi) / Double(resolution - 1))

        let coords: [String: Double] = [
            "x": x, "y": y, "t": time, "w": 512, "h": 512,
            "me.x": x, "me.y": y, "me.t": time, "me.w": 512, "me.h": 512,
        ]

        var values: [SIMD2<Double>] = []
        values.reserveCapacity(layers.count)
        for layer in layers {
            let exprs = layer.strandExprs
            switch layer.type {
            case .plane:
                let v0 = exprs.count > 0 ? interpreter.evaluate(exprs[0].1, coordinates: coords) : 0
                let v1 = exprs.count > 1 ? interpreter.evaluate(exprs[1].1, coordinates: coords) : 0
                values.append(SIMD2(v0, v1))
            case .axis:
                let v0 = exprs.count > 0 ? interpreter.evaluate(exprs[0].1, coordinates: coords) : 0
                values.append(SIMD2(v0, 0))
            }
        }
        return values
    }

    // MARK: - Sample Color

    private func sampleColor(_ si: Int, res: Int) -> Color {
        guard res > 1 else { return .white }
        let xi = si % res
        let yi = si / res
        let nx = Double(xi) / Double(res - 1)
        let ny = Double(yi) / Double(res - 1)
        let hue = (nx * 0.6 + ny * 0.3).truncatingRemainder(dividingBy: 1.0)
        return Color(hue: hue, saturation: 0.7, brightness: 0.95)
    }

    // MARK: - Helpers

    /// Return locked ranges during playback, or cached ranges when paused
    private func currentRanges() -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        if state.isPlaying, let locked = lockedRanges, locked.count == state.layers.count {
            return locked
        }
        return state.cachedRanges
    }

    private func norm(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return 0.5 }
        return (v - lo) / (hi - lo)
    }
}

// MARK: - Layout Layer Panel

struct LayoutLayerPanel: View {
    @ObservedObject var state: LayoutState
    let coordinator: Coordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                addLayerMenu
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial)

            SubtleDivider(.horizontal)

            List {
                ForEach(Array(state.layers.enumerated()), id: \.element.id) { index, layer in
                    layerRow(layer: layer, index: index)
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove { source, destination in
                    state.layers.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            if !state.selectedSampleIndices.isEmpty {
                selectedSampleReadout
            }
        }
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.2))
    }

    // MARK: - Selected Sample Readout

    @ViewBuilder
    private var selectedSampleReadout: some View {
        let indices = Array(state.selectedSampleIndices.sorted())
        if let first = indices.first, first < state.samples.count {
            VStack(alignment: .leading, spacing: 4) {
                SubtleDivider(.horizontal)

                HStack {
                    Text(indices.count == 1 ? "Selected" : "\(indices.count) selected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xs)

                let sample = state.samples[first]
                ForEach(Array(state.layers.enumerated()), id: \.element.id) { idx, layer in
                    if idx < sample.count {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(layer.color.opacity(layer.isVisible ? 1.0 : 0.3))
                                .frame(width: 6, height: 6)
                            Text(layer.label)
                                .font(.system(size: 10))
                                .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                                .lineLimit(1)
                            Spacer()
                            Text(formatValue(sample[idx], layer.type))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(layer.isVisible ? .secondary : .quaternary)
                        }
                        .padding(.horizontal, Spacing.sm)
                    }
                }
                .padding(.bottom, Spacing.xs)
            }
        }
    }

    private func formatValue(_ val: SIMD2<Double>, _ type: LoomLayerSpec.LayerType) -> String {
        switch type {
        case .plane:
            return "(\(String(format: "%.3f", val.x)), \(String(format: "%.3f", val.y)))"
        case .axis:
            return String(format: "%.3f", val.x)
        }
    }

    // MARK: - Layer Row

    private func layerRow(layer: LoomLayer, index: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                state.layers[index].isVisible.toggle()
            } label: {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? .secondary : .quaternary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Circle()
                .fill(layer.color.opacity(layer.isVisible ? 1.0 : 0.3))
                .frame(width: 8, height: 8)

            Image(systemName: layer.type.isPlane ? "square" : "line.diagonal")
                .font(.system(size: 10))
                .foregroundStyle(layer.isVisible ? .tertiary : .quaternary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(layer.bundleName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .lineLimit(1)
                Text(layerSubtitle(layer))
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? .tertiary : .quaternary)
                    .lineLimit(1)
            }

            Spacer()

            if layer.bundleName != "me" {
                Button {
                    state.layers.removeAll { $0.id == layer.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs + 2)
        .opacity(layer.isVisible ? 1.0 : 0.6)
    }

    // MARK: - Add Layer Menu

    private var addLayerMenu: some View {
        Menu {
            if let program = coordinator.program {
                let available = availableBundleNames(program: program)
                if available.isEmpty {
                    Text("No additional bundles")
                } else {
                    ForEach(available, id: \.self) { name in
                        if let bundle = program.bundles[name] {
                            if bundle.strands.count >= 2 {
                                Button("\(name) (plane)") {
                                    addLayerAsPlane(bundleName: name, program: program)
                                }
                                Button("\(name) (axes)") {
                                    addLayerAsAxisGroup(bundleName: name, program: program)
                                }
                            } else if !bundle.strands.isEmpty {
                                Button(name) {
                                    addLayerAsAxis(bundleName: name, strandName: bundle.strands[0].name, expr: bundle.strands[0].expr)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 18)
    }

    // MARK: - Helpers

    private func availableBundleNames(program: IRProgram) -> [String] {
        let existing = Set(state.layers.map { $0.bundleName })
        return program.bundles.keys
            .filter { !existing.contains($0) && $0 != "me" }
            .sorted()
    }

    private func nextLayerColor() -> Color {
        let distinctBundles = Set(state.layers.map { $0.bundleName }).count
        let hues: [Color] = [
            Color(hue: 0.8, saturation: 0.6, brightness: 0.9),
            Color(hue: 0.55, saturation: 0.6, brightness: 0.85),
            Color(hue: 0.1, saturation: 0.7, brightness: 0.95),
            Color(hue: 0.35, saturation: 0.6, brightness: 0.8),
            Color(hue: 0.95, saturation: 0.6, brightness: 0.9),
            Color(hue: 0.6, saturation: 0.5, brightness: 0.9),
        ]
        return hues[distinctBundles % hues.count]
    }

    private func addLayerAsPlane(bundleName: String, program: IRProgram) {
        guard let bundle = program.bundles[bundleName] else { return }
        let strands = bundle.strands.sorted(by: { $0.index < $1.index })
        guard strands.count >= 2 else { return }
        let color = nextLayerColor()
        let spec = LoomLayerSpec(
            bundleName: bundleName,
            type: .plane(xStrand: "\(bundleName).\(strands[0].name)",
                         yStrand: "\(bundleName).\(strands[1].name)"),
            label: "\(bundleName).\(strands[0].name), \(bundleName).\(strands[1].name)",
            strandExprs: [(strands[0].name, strands[0].expr), (strands[1].name, strands[1].expr)]
        )
        state.layers.append(LoomLayer(from: spec, color: color))
    }

    private func addLayerAsAxisGroup(bundleName: String, program: IRProgram) {
        guard let bundle = program.bundles[bundleName] else { return }
        let strands = bundle.strands.sorted(by: { $0.index < $1.index })
        let color = nextLayerColor()
        for strand in strands {
            let spec = LoomLayerSpec(
                bundleName: bundleName,
                type: .axis(strand: "\(bundleName).\(strand.name)"),
                label: "\(bundleName).\(strand.name)",
                strandExprs: [(strand.name, strand.expr)]
            )
            state.layers.append(LoomLayer(from: spec, color: color))
        }
    }

    private func addLayerAsAxis(bundleName: String, strandName: String, expr: IRExpr) {
        let color = nextLayerColor()
        let spec = LoomLayerSpec(
            bundleName: bundleName,
            type: .axis(strand: "\(bundleName).\(strandName)"),
            label: "\(bundleName).\(strandName)",
            strandExprs: [(strandName, expr)]
        )
        state.layers.append(LoomLayer(from: spec, color: color))
    }

    private func layerSubtitle(_ layer: LoomLayer) -> String {
        switch layer.type {
        case .plane(let x, let y):
            let xShort = x.components(separatedBy: ".").last ?? x
            let yShort = y.components(separatedBy: ".").last ?? y
            return "plane (\(xShort), \(yShort))"
        case .axis(let s):
            let sShort = s.components(separatedBy: ".").last ?? s
            return "axis (\(sShort))"
        }
    }
}
