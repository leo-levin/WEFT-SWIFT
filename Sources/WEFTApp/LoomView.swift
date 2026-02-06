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

    init(from spec: LoomLayerSpec, color: Color) {
        self.id = spec.id
        self.bundleName = spec.bundleName
        self.label = spec.label
        self.type = spec.type
        self.strandExprs = spec.strandExprs
        self.color = color
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
            state.selectedSampleIndices = []
            refreshSamples()
        }
        .onChange(of: state.regionMin) { _, _ in refreshSamples() }
        .onChange(of: state.regionMax) { _, _ in refreshSamples() }
        .onChange(of: state.scrubTime) { _, _ in
            if !state.isPlaying { refreshSamples() }
        }
        .onChange(of: state.layers.count) { _, _ in refreshSamples() }
        .task(id: state.isPlaying) {
            guard state.isPlaying else { return }
            while !Task.isCancelled {
                refreshSamples()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onAppear {
            if let name = loomNodeName {
                setupChain(for: name)
            }
        }
    }

    // MARK: - Refresh

    private func refreshSamples() {
        let time = state.isPlaying ? coordinator.time : state.scrubTime
        evaluateSamples(time: time)
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
        .gesture(tapGesture)
        .simultaneousGesture(dragGesture)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
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

    // MARK: - Evaluation

    private func evaluateSamples(time: Double) {
        guard let program = coordinator.program, !state.layers.isEmpty else {
            state.samples = []
            return
        }

        let interpreter = IRInterpreter(program: program,
                                         resourceSampler: coordinator.buildResourceSampler())
        let res = state.resolution
        var newSamples: [[SIMD2<Double>]] = []
        newSamples.reserveCapacity(res * res)

        for yi in 0..<res {
            for xi in 0..<res {
                let x = state.regionMin.x + (state.regionMax.x - state.regionMin.x)
                    * (res <= 1 ? 0.5 : Double(xi) / Double(res - 1))
                let y = state.regionMin.y + (state.regionMax.y - state.regionMin.y)
                    * (res <= 1 ? 0.5 : Double(yi) / Double(res - 1))

                let coords: [String: Double] = [
                    "x": x, "y": y, "t": time, "w": 512, "h": 512,
                    "me.x": x, "me.y": y, "me.t": time, "me.w": 512, "me.h": 512,
                ]

                var layerValues: [SIMD2<Double>] = []
                layerValues.reserveCapacity(state.layers.count)

                for layer in state.layers {
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
        state.samples = newSamples
    }

    // MARK: - Drawing

    private func drawLoom(context: GraphicsContext, size: CGSize) {
        guard !state.layers.isEmpty else { return }

        let layerCount = state.layers.count
        let layout = computeSlots()
        let totalSpread = state.spread * Double(layout.totalSlots - 1) * 1.5
        let samples = state.samples

        // Auto-range per layer
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

        // Collect drawables for depth sorting
        struct Drawable {
            enum Kind {
                case planeOutline(Int), axisLine(Int), point(Int, Int), connector(Int)
            }
            let kind: Kind
            let depth: Double
        }
        var drawables: [Drawable] = []

        for li in 0..<layerCount {
            let z = slotZ(layout.zSlots[li], layout.totalSlots, totalSpread)
            drawables.append(Drawable(kind: state.layers[li].type.isPlane ? .planeOutline(li) : .axisLine(li),
                                      depth: state.camera.depth(SIMD3(layout.xOffsets[li], 0, z))))
        }

        for si in 0..<samples.count {
            for li in 0..<Swift.min(samples[si].count, layerCount) {
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

        for si in state.selectedSampleIndices where si < samples.count {
            let z = slotZ(layout.zSlots[0], layout.totalSlots, totalSpread)
            drawables.append(Drawable(kind: .connector(si), depth: state.camera.depth(SIMD3(0, 0, z)) - 0.01))
        }

        drawables.sort { $0.depth > $1.depth }

        for d in drawables {
            switch d.kind {
            case .planeOutline(let li): drawPlane(context, size, li, layout, totalSpread)
            case .axisLine(let li): drawAxis(context, size, li, layout, totalSpread)
            case .point(let si, let li): drawPt(context, size, si, li, layout, totalSpread, ranges, samples)
            case .connector(let si): drawLine(context, size, si, layerCount, layout, totalSpread, ranges, samples)
            }
        }

        // Labels with shadow for readability
        for li in 0..<layerCount {
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

    private func drawAxis(_ ctx: GraphicsContext, _ sz: CGSize, _ li: Int, _ layout: SlotLayout, _ sp: Double) {
        let z = slotZ(layout.zSlots[li], layout.totalSlots, sp)
        let xo = layout.xOffsets[li]
        var path = Path()
        path.move(to: state.camera.project(SIMD3(xo, 0.5, z), viewSize: sz))
        path.addLine(to: state.camera.project(SIMD3(xo, -0.5, z), viewSize: sz))
        ctx.stroke(path, with: .color(state.layers[li].color.opacity(0.8)), lineWidth: 3)
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

    private func drawLine(_ ctx: GraphicsContext, _ sz: CGSize, _ si: Int,
                           _ cnt: Int, _ layout: SlotLayout, _ sp: Double,
                           _ ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)],
                           _ samples: [[SIMD2<Double>]]) {
        guard si < samples.count, samples[si].count >= cnt else { return }
        let sample = samples[si]

        // Project all points
        var pts: [CGPoint] = []
        for li in 0..<cnt {
            let val = sample[li]
            let z = slotZ(layout.zSlots[li], layout.totalSlots, sp)
            let r = ranges[li]
            let pt: SIMD3<Double>
            switch state.layers[li].type {
            case .plane:
                pt = SIMD3(norm(val.x, r.min.x, r.max.x) - 0.5, norm(val.y, r.min.y, r.max.y) - 0.5, z)
            case .axis:
                pt = SIMD3(layout.xOffsets[li], norm(val.x, r.min.x, r.max.x) - 0.5, z)
            }
            pts.append(state.camera.project(pt, viewSize: sz))
        }
        guard pts.count >= 2 else { return }

        // Group layer indices by z-slot for fan-out/in
        var slotGroups: [(slot: Int, layers: [Int])] = []
        var i = 0
        while i < cnt {
            let slot = layout.zSlots[i]
            var group = [i]
            i += 1
            while i < cnt && layout.zSlots[i] == slot {
                group.append(i)
                i += 1
            }
            slotGroups.append((slot, group))
        }

        let style = StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        let color: GraphicsContext.Shading = .color(.white.opacity(0.6))

        // Draw lines between adjacent slot groups (fan-out / fan-in)
        for gi in 0..<(slotGroups.count - 1) {
            for fromIdx in slotGroups[gi].layers {
                for toIdx in slotGroups[gi + 1].layers {
                    var path = Path()
                    path.move(to: pts[fromIdx])
                    path.addLine(to: pts[toIdx])
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
