// LoomView.swift - Loom coordinate visualization (3D stacked planes/axes)

import SwiftUI
import Combine
import WEFTLib

// MARK: - Loom State

class LoomState: ObservableObject {
    @Published var layers: [LoomLayer] = []
    @Published var samples: [[SIMD2<Double>]] = []
    @Published var selectedSampleIndices: Set<Int> = []

    // Region (normalized canvas coordinates)
    @Published var regionMin: SIMD2<Double> = SIMD2(0.0, 0.0)
    @Published var regionMax: SIMD2<Double> = SIMD2(1.0, 1.0)

    // Controls
    @Published var resolution: Int = 16
    @Published var spread: Double = 0.5
    @Published var isPlaying: Bool = true
    @Published var scrubTime: Double = 0.0

    // 3D camera
    @Published var camera: Camera3D = Camera3D()

    // Source node name
    @Published var sourceNodeName: String? = nil

    var sampleCount: Int { resolution * resolution }

    static let maxResolution = 50
}

// MARK: - Loom Layer

struct LoomLayer: Identifiable {
    let id: UUID
    let bundleName: String
    let label: String
    let type: LoomLayerSpec.LayerType
    let strandExprs: [(strandName: String, expr: IRExpr)]
    let color: Color
    var isVisible: Bool = true

    init(from spec: LoomLayerSpec, color: Color) {
        self.id = spec.id
        self.bundleName = spec.bundleName
        self.label = spec.label
        self.type = spec.type
        self.strandExprs = spec.strandExprs
        self.color = color
        self.isVisible = true
    }
}

// MARK: - Slot Layout (groups share a z-slot)

struct SlotLayout {
    let zSlots: [Int]
    let totalSlots: Int
    let xOffsets: [Double]
}

// MARK: - Loom View

struct LoomView: View {
    let coordinator: Coordinator
    @Binding var loomNodeName: String?
    @StateObject private var state = LoomState()
    @State private var dragStart: CGPoint? = nil
    @State private var canvasSize: CGSize = .zero
    @State private var playStartWallTime: Double = 0
    @State private var playStartScrubTime: Double = 0

    // Background evaluation infrastructure
    private let evaluationQueue = DispatchQueue(label: "loom.evaluation", qos: .userInitiated)
    @State private var evaluationInFlight = false

    // Progressive resolution state
    @State private var isShowingPreview = false
    @State private var refinementTask: Task<Void, Never>? = nil
    private let previewResolution = 8

    // Stable ranges during playback
    @State private var lockedRanges: [(min: SIMD2<Double>, max: SIMD2<Double>)]? = nil

    // Keyboard focus
    @FocusState private var canvasFocused: Bool

    // Drag mode tracking
    @State private var isPanning: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if state.layers.isEmpty {
                EmptyStateView(
                    "perspective",
                    message: "No chain selected",
                    hint: "Select a node in Graph and tap \"View in Loom\""
                )
            } else {
                HSplitView {
                    loomCanvas
                        .frame(minWidth: 200)
                    LoomLayerPanel(state: state, coordinator: coordinator)
                        .frame(minWidth: 140, idealWidth: 170, maxWidth: 220)
                }

                SubtleDivider(.horizontal)

                LoomControls(state: state, coordinator: coordinator)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
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
                // Lock ranges at playback start for stability
                lockedRanges = computeRanges()
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSinceReferenceDate - playStartWallTime
                    state.scrubTime = playStartScrubTime + elapsed
                    refreshSamples()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } else {
                // Paused - unlock ranges and trigger refinement if showing preview
                lockedRanges = nil
                if isShowingPreview {
                    scheduleRefinement()
                }
            }
        }
        .onAppear {
            if let name = loomNodeName {
                setupChain(for: name)
            }
        }
    }

    // MARK: - Refresh

    private func refreshSamples(forceFullResolution: Bool = false) {
        guard !evaluationInFlight else { return }
        evaluationInFlight = true

        // Use preview resolution only during playback, not when scrubbing while paused
        let usePreview = !forceFullResolution && state.isPlaying
        let effectiveResolution = usePreview ? min(state.resolution, previewResolution) : state.resolution

        // Capture state snapshot for background computation
        let resolution = effectiveResolution
        let regionMin = state.regionMin
        let regionMax = state.regionMax
        let time = state.scrubTime
        let layers = state.layers

        guard let program = coordinator.program, !layers.isEmpty else {
            state.samples = []
            evaluationInFlight = false
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

            DispatchQueue.main.async {
                // Update state on main thread
                if resolution != self.state.resolution {
                    // Resolution mismatch means we showed a preview
                    self.isShowingPreview = true
                } else {
                    self.isShowingPreview = false
                }
                self.state.samples = newSamples
                self.evaluationInFlight = false

                // Schedule refinement if we showed preview and not playing
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

    // MARK: - 3D Canvas

    private var loomCanvas: some View {
        Canvas { context, size in
            drawLoom(context: context, size: size)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .onAppear { canvasSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
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
        .gesture(tapGesture)
        .gesture(doubleTapGesture)
        .simultaneousGesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress { key in
            handleKeyPress(key)
        }
        .onAppear { canvasFocused = true }
    }

    // MARK: - Keyboard Shortcuts

    private func handleKeyPress(_ key: KeyPress) -> KeyPress.Result {
        switch key.key {
        case .space:
            state.isPlaying.toggle()
            return .handled
        case .upArrow:
            state.camera.pitch += 0.1
            state.camera.pitch = max(-1.2, min(1.2, state.camera.pitch))
            return .handled
        case .downArrow:
            state.camera.pitch -= 0.1
            state.camera.pitch = max(-1.2, min(1.2, state.camera.pitch))
            return .handled
        case .leftArrow:
            state.camera.yaw -= 0.1
            return .handled
        case .rightArrow:
            state.camera.yaw += 0.1
            return .handled
        default:
            break
        }

        // Character-based shortcuts
        if let char = key.characters.first {
            switch char {
            case "r", "R":
                withAnimation(.spring(duration: 0.3)) {
                    state.camera = Camera3D.default
                }
                return .handled
            case "0":
                state.regionMin = SIMD2(0, 0)
                state.regionMax = SIMD2(1, 1)
                return .handled
            case "+", "=":
                state.resolution = min(LoomState.maxResolution, state.resolution + 2)
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

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .modifiers(.option)
            .onChanged { value in
                // Option-drag = pan
                if let start = dragStart {
                    let dx = value.location.x - start.x
                    let dy = value.location.y - start.y
                    state.camera.offsetX += dx * 0.005
                    state.camera.offsetY -= dy * 0.005
                }
                dragStart = value.location
                isPanning = true
            }
            .onEnded { _ in
                dragStart = nil
                isPanning = false
            }
            .simultaneously(with:
                DragGesture()
                    .onChanged { value in
                        guard !isPanning else { return }
                        // Normal drag = rotate
                        if let start = dragStart {
                            let dx = value.location.x - start.x
                            let dy = value.location.y - start.y
                            state.camera.yaw += dx * 0.008
                            state.camera.pitch += dy * 0.008
                            state.camera.pitch = max(-1.2, min(1.2, state.camera.pitch))
                        }
                        dragStart = value.location
                    }
                    .onEnded { _ in
                        dragStart = nil
                    }
            )
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = 0.7 * value.magnification
                state.camera.scale = max(0.3, min(2.0, newScale))
            }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                withAnimation(.spring(duration: 0.3)) {
                    state.camera = Camera3D.default
                }
            }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                handleTap(at: value.location)
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

    // MARK: - Slot Computation (groups share z-depth)

    /// Layers from the same bundle are grouped at the same z-slot, spread horizontally.
    private func computeSlots() -> SlotLayout {
        let count = state.layers.count
        guard count > 0 else { return SlotLayout(zSlots: [], totalSlots: 0, xOffsets: []) }

        var zSlots = [Int](repeating: 0, count: count)
        var xOffsets = [Double](repeating: 0, count: count)
        var slot = 0
        var i = 0

        while i < count {
            let name = state.layers[i].bundleName
            let groupStart = i
            zSlots[i] = slot
            i += 1
            while i < count && state.layers[i].bundleName == name {
                zSlots[i] = slot
                i += 1
            }
            let groupSize = i - groupStart
            if groupSize > 1 {
                for j in groupStart..<i {
                    let t = Double(j - groupStart) / Double(groupSize - 1) - 0.5
                    xOffsets[j] = t * 0.5
                }
            }
            slot += 1
        }
        return SlotLayout(zSlots: zSlots, totalSlots: slot, xOffsets: xOffsets)
    }

    private func slotZ(_ slot: Int, _ totalSlots: Int, _ spread: Double) -> Double {
        guard totalSlots > 1 else { return 0 }
        return -spread / 2 + spread * Double(slot) / Double(totalSlots - 1)
    }

    // MARK: - Evaluation (Pure Computation)

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
        var newSamples: [[SIMD2<Double>]] = []
        newSamples.reserveCapacity(resolution * resolution)

        for yi in 0..<resolution {
            for xi in 0..<resolution {
                let x = regionMin.x + (regionMax.x - regionMin.x)
                    * (resolution <= 1 ? 0.5 : Double(xi) / Double(resolution - 1))
                let y = regionMin.y + (regionMax.y - regionMin.y)
                    * (resolution <= 1 ? 0.5 : Double(yi) / Double(resolution - 1))

                let coords: [String: Double] = [
                    "x": x, "y": y, "t": time, "w": 512, "h": 512,
                    "me.x": x, "me.y": y, "me.t": time, "me.w": 512, "me.h": 512,
                ]

                var layerValues: [SIMD2<Double>] = []
                layerValues.reserveCapacity(layers.count)

                for layer in layers {
                    let exprs = layer.strandExprs
                    switch layer.type {
                    case .plane:
                        let v0 = exprs.count > 0 ? interpreter.evaluate(exprs[0].1, coordinates: coords) : 0
                        let v1 = exprs.count > 1 ? interpreter.evaluate(exprs[1].1, coordinates: coords) : 0
                        layerValues.append(SIMD2(v0, v1))
                    case .axis:
                        let v0 = exprs.count > 0 ? interpreter.evaluate(exprs[0].1, coordinates: coords) : 0
                        layerValues.append(SIMD2(v0, 0))
                    }
                }
                newSamples.append(layerValues)
            }
        }
        return newSamples
    }

    // MARK: - Range Computation

    /// Compute fresh ranges from current samples
    private func computeRanges() -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        let layerCount = state.layers.count
        var ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)] = Array(
            repeating: (SIMD2(.infinity, .infinity), SIMD2(-.infinity, -.infinity)),
            count: layerCount
        )
        for sample in state.samples {
            for (li, val) in sample.enumerated() where li < layerCount {
                ranges[li].min = SIMD2(Swift.min(ranges[li].min.x, val.x), Swift.min(ranges[li].min.y, val.y))
                ranges[li].max = SIMD2(Swift.max(ranges[li].max.x, val.x), Swift.max(ranges[li].max.y, val.y))
            }
        }
        return ranges
    }

    /// Return locked ranges during playback, or compute fresh ranges when paused
    private func currentRanges() -> [(min: SIMD2<Double>, max: SIMD2<Double>)] {
        if state.isPlaying, let locked = lockedRanges, locked.count == state.layers.count {
            return locked
        }
        return computeRanges()
    }

    // MARK: - Drawing

    private func drawLoom(context: GraphicsContext, size: CGSize) {
        guard !state.layers.isEmpty else { return }

        let layerCount = state.layers.count
        let layout = computeSlots()
        let totalSpread = state.spread * Double(layout.totalSlots - 1) * 1.5
        let samples = state.samples
        let ranges = currentRanges()

        // Collect drawables for depth sorting
        struct Drawable {
            enum Kind {
                case planeOutline(Int), axisLine(Int), point(Int, Int), connector(Int), rangeLabel(Int, Bool)
            }
            let kind: Kind
            let depth: Double
        }
        var drawables: [Drawable] = []

        for li in 0..<layerCount where state.layers[li].isVisible {
            let z = slotZ(layout.zSlots[li], layout.totalSlots, totalSpread)
            let d = state.camera.depth(SIMD3(layout.xOffsets[li], 0, z))
            drawables.append(Drawable(kind: state.layers[li].type.isPlane ? .planeOutline(li) : .axisLine(li), depth: d))
            // Range labels for axis layers
            if !state.layers[li].type.isPlane {
                drawables.append(Drawable(kind: .rangeLabel(li, false), depth: d - 0.001)) // min
                drawables.append(Drawable(kind: .rangeLabel(li, true), depth: d - 0.001))  // max
            }
        }

        for si in 0..<samples.count {
            for li in 0..<Swift.min(samples[si].count, layerCount) where state.layers[li].isVisible {
                let z = slotZ(layout.zSlots[li], layout.totalSlots, totalSpread)
                let val = samples[si][li]
                let xo = layout.xOffsets[li]
                let nx: Double
                let ny: Double
                switch state.layers[li].type {
                case .plane:
                    nx = norm(val.x, ranges[li].min.x, ranges[li].max.x) - 0.5
                    ny = norm(val.y, ranges[li].min.y, ranges[li].max.y) - 0.5
                case .axis:
                    nx = xo
                    ny = norm(val.x, ranges[li].min.x, ranges[li].max.x) - 0.5
                }
                drawables.append(Drawable(kind: .point(si, li), depth: state.camera.depth(SIMD3(nx, ny, z))))
            }
        }

        // Only draw connectors through visible layers
        let visibleIndices = state.layers.indices.filter { state.layers[$0].isVisible }
        for si in state.selectedSampleIndices where si < samples.count {
            if let firstVisible = visibleIndices.first {
                let z = slotZ(layout.zSlots[firstVisible], layout.totalSlots, totalSpread)
                drawables.append(Drawable(kind: .connector(si), depth: state.camera.depth(SIMD3(0, 0, z)) - 0.01))
            }
        }

        drawables.sort { $0.depth > $1.depth }

        for d in drawables {
            switch d.kind {
            case .planeOutline(let li): drawPlane(context, size, li, layout, totalSpread)
            case .axisLine(let li): drawAxis(context, size, li, layout, totalSpread, ranges)
            case .point(let si, let li): drawPt(context, size, si, li, layout, totalSpread, ranges, samples)
            case .connector(let si): drawConnector(context, size, si, layout, totalSpread, ranges, samples)
            case .rangeLabel(let li, let isMax): drawRangeLabel(context, size, li, layout, totalSpread, ranges, isMax)
            }
        }

        // Labels with shadow for readability (only visible layers)
        for li in 0..<layerCount where state.layers[li].isVisible {
            let z = slotZ(layout.zSlots[li], layout.totalSlots, totalSpread)
            let xo = layout.xOffsets[li]
            let labelPos: SIMD3<Double>
            let anchor: UnitPoint
            if xo != 0 {
                // Grouped axis: label above its position
                labelPos = SIMD3(xo, 0.58, z)
                anchor = .bottom
            } else if state.layers[li].type.isPlane {
                labelPos = SIMD3(-0.55, 0.58, z)
                anchor = .leading
            } else {
                labelPos = SIMD3(0.05, 0.58, z)
                anchor = .bottomLeading
            }
            let p = state.camera.project(labelPos, viewSize: size)
            let label = Text(state.layers[li].label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(state.layers[li].color)

            // Shadow for readability
            var shadowCtx = context
            shadowCtx.addFilter(.shadow(color: .black.opacity(0.9), radius: 3))
            shadowCtx.draw(label, at: p, anchor: anchor)
        }
    }

    private func norm(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return 0.5 }
        return (v - lo) / (hi - lo)
    }

    private func drawPlane(_ ctx: GraphicsContext, _ sz: CGSize, _ li: Int, _ layout: SlotLayout, _ sp: Double) {
        let z = slotZ(layout.zSlots[li], layout.totalSlots, sp)
        let c = [SIMD3(-0.5, -0.5, z), SIMD3(0.5, -0.5, z), SIMD3(0.5, 0.5, z), SIMD3(-0.5, 0.5, z)]
        let p = c.map { state.camera.project($0, viewSize: sz) }
        var path = Path()
        path.move(to: p[0]); path.addLine(to: p[1]); path.addLine(to: p[2]); path.addLine(to: p[3])
        path.closeSubpath()
        let col = state.layers[li].color
        ctx.fill(path, with: .color(col.opacity(0.10)))
        ctx.stroke(path, with: .color(col.opacity(0.6)), lineWidth: 1.5)
    }

    private func drawAxis(_ ctx: GraphicsContext, _ sz: CGSize, _ li: Int, _ layout: SlotLayout, _ sp: Double,
                          _ ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)]) {
        let z = slotZ(layout.zSlots[li], layout.totalSlots, sp)
        let xo = layout.xOffsets[li]
        var path = Path()
        path.move(to: state.camera.project(SIMD3(xo, 0.5, z), viewSize: sz))
        path.addLine(to: state.camera.project(SIMD3(xo, -0.5, z), viewSize: sz))
        ctx.stroke(path, with: .color(state.layers[li].color.opacity(0.8)), lineWidth: 3)
    }

    private func drawRangeLabel(_ ctx: GraphicsContext, _ sz: CGSize, _ li: Int, _ layout: SlotLayout,
                                 _ sp: Double, _ ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)], _ isMax: Bool) {
        guard li < ranges.count else { return }
        let z = slotZ(layout.zSlots[li], layout.totalSlots, sp)
        let xo = layout.xOffsets[li]
        let r = ranges[li]

        // Skip if range is invalid
        guard r.min.x.isFinite && r.max.x.isFinite && r.max.x > r.min.x else { return }

        let yPos: Double = isMax ? 0.52 : -0.52
        let value = isMax ? r.max.x : r.min.x
        let pos = state.camera.project(SIMD3(xo + 0.08, yPos, z), viewSize: sz)

        let label = Text(String(format: "%.2f", value))
            .font(.system(size: 8, design: .monospaced))
            .foregroundColor(state.layers[li].color.opacity(0.6))

        var shadowCtx = ctx
        shadowCtx.addFilter(.shadow(color: .black.opacity(0.7), radius: 2))
        shadowCtx.draw(label, at: pos, anchor: isMax ? .bottomLeading : .topLeading)
    }

    private func drawPt(_ ctx: GraphicsContext, _ sz: CGSize, _ si: Int, _ li: Int,
                         _ layout: SlotLayout, _ sp: Double,
                         _ ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)],
                         _ samples: [[SIMD2<Double>]]) {
        guard si < samples.count, li < samples[si].count else { return }
        let val = samples[si][li]
        let z = slotZ(layout.zSlots[li], layout.totalSlots, sp)
        let r = ranges[li]
        let pt: SIMD3<Double>
        switch state.layers[li].type {
        case .plane:
            pt = SIMD3(norm(val.x, r.min.x, r.max.x) - 0.5, norm(val.y, r.min.y, r.max.y) - 0.5, z)
        case .axis:
            pt = SIMD3(layout.xOffsets[li], norm(val.x, r.min.x, r.max.x) - 0.5, z)
        }
        let sp2 = state.camera.project(pt, viewSize: sz)
        let sel = state.selectedSampleIndices.contains(si)
        let rad: CGFloat = sel ? 3.5 : 2
        ctx.fill(Path(ellipseIn: CGRect(x: sp2.x - rad, y: sp2.y - rad, width: rad * 2, height: rad * 2)),
                 with: .color(state.layers[li].color.opacity(sel ? 1.0 : 0.4)))
    }

    private func drawConnector(_ ctx: GraphicsContext, _ sz: CGSize, _ si: Int,
                                 _ layout: SlotLayout, _ sp: Double,
                                 _ ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)],
                                 _ samples: [[SIMD2<Double>]]) {
        guard si < samples.count else { return }
        let sample = samples[si]

        // Only include visible layers
        let visibleIndices = state.layers.indices.filter { $0 < sample.count && state.layers[$0].isVisible }
        guard visibleIndices.count >= 2 else { return }

        // Project visible points
        var pts: [(li: Int, pt: CGPoint)] = []
        for li in visibleIndices {
            let val = sample[li]
            let z = slotZ(layout.zSlots[li], layout.totalSlots, sp)
            let r = ranges[li]
            let pt3: SIMD3<Double>
            switch state.layers[li].type {
            case .plane:
                pt3 = SIMD3(norm(val.x, r.min.x, r.max.x) - 0.5, norm(val.y, r.min.y, r.max.y) - 0.5, z)
            case .axis:
                pt3 = SIMD3(layout.xOffsets[li], norm(val.x, r.min.x, r.max.x) - 0.5, z)
            }
            pts.append((li, state.camera.project(pt3, viewSize: sz)))
        }

        // Group by z-slot (for visible layers only)
        var slotGroups: [(slot: Int, indices: [(li: Int, pt: CGPoint)])] = []
        var i = 0
        while i < pts.count {
            let slot = layout.zSlots[pts[i].li]
            var group = [pts[i]]
            i += 1
            while i < pts.count && layout.zSlots[pts[i].li] == slot {
                group.append(pts[i])
                i += 1
            }
            slotGroups.append((slot, group))
        }

        let style = StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        let color: GraphicsContext.Shading = .color(.white.opacity(0.6))

        // Draw lines between adjacent slot groups (fan-out / fan-in)
        for gi in 0..<(slotGroups.count - 1) {
            for from in slotGroups[gi].indices {
                for to in slotGroups[gi + 1].indices {
                    var path = Path()
                    path.move(to: from.pt)
                    path.addLine(to: to.pt)
                    ctx.stroke(path, with: color, style: style)
                }
            }
        }
    }

    // MARK: - Tap Handling (multi-select)

    private func handleTap(at location: CGPoint) {
        guard !state.samples.isEmpty, !state.layers.isEmpty else {
            state.selectedSampleIndices = []
            return
        }

        let layerCount = state.layers.count
        let layout = computeSlots()
        let totalSpread = state.spread * Double(layout.totalSlots - 1) * 1.5
        let samples = state.samples

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

        let size = canvasSize
        var bestDist = Double.infinity
        var bestSample = -1
        var bestLayer = -1

        for si in 0..<samples.count {
            for li in 0..<Swift.min(samples[si].count, layerCount) {
                let sp = projectSample(si: si, li: li, layout: layout, totalSpread: totalSpread,
                                       ranges: ranges, samples: samples, size: size)
                let dx = sp.x - location.x
                let dy = sp.y - location.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestDist { bestDist = dist; bestSample = si; bestLayer = li }
            }
        }

        if bestDist < 20 && bestSample >= 0 {
            // Find all samples that map to the same projected location at the tapped layer
            let targetPt = projectSample(si: bestSample, li: bestLayer, layout: layout,
                                          totalSpread: totalSpread, ranges: ranges,
                                          samples: samples, size: size)
            var matching: Set<Int> = []
            for si in 0..<samples.count {
                guard bestLayer < samples[si].count else { continue }
                let pt = projectSample(si: si, li: bestLayer, layout: layout,
                                        totalSpread: totalSpread, ranges: ranges,
                                        samples: samples, size: size)
                let dx = pt.x - targetPt.x
                let dy = pt.y - targetPt.y
                if sqrt(dx * dx + dy * dy) < 8 {
                    matching.insert(si)
                }
            }

            // Toggle: if already selected, deselect all matching; otherwise select all
            if state.selectedSampleIndices.contains(bestSample) {
                state.selectedSampleIndices.subtract(matching)
            } else {
                state.selectedSampleIndices.formUnion(matching)
            }
        } else {
            // Tapped empty space: clear all
            state.selectedSampleIndices = []
        }
    }

    private func projectSample(si: Int, li: Int, layout: SlotLayout, totalSpread: Double,
                                ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)],
                                samples: [[SIMD2<Double>]], size: CGSize) -> CGPoint {
        let val = samples[si][li]
        let z = slotZ(layout.zSlots[li], layout.totalSlots, totalSpread)
        let r = ranges[li]
        let pt: SIMD3<Double>
        switch state.layers[li].type {
        case .plane:
            pt = SIMD3(norm(val.x, r.min.x, r.max.x) - 0.5, norm(val.y, r.min.y, r.max.y) - 0.5, z)
        case .axis:
            pt = SIMD3(layout.xOffsets[li], norm(val.x, r.min.x, r.max.x) - 0.5, z)
        }
        return state.camera.project(pt, viewSize: size)
    }
}

// MARK: - LayerType Extension

extension LoomLayerSpec.LayerType {
    var isPlane: Bool {
        switch self {
        case .plane: return true
        case .axis: return false
        }
    }
}
