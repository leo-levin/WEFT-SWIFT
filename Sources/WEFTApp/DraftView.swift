// DraftView.swift - Draft coordinate visualization (3D stacked planes/axes)

import SwiftUI
import Combine
import WEFTLib

// MARK: - Draft State

class DraftState: ObservableObject {
    @Published var layers: [DraftLayer] = []
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

// MARK: - Draft Layer

struct DraftLayer: Identifiable {
    let id: UUID
    let bundleName: String
    let label: String
    let type: DraftLayerSpec.LayerType
    let strandExprs: [(strandName: String, expr: IRExpr)]
    let color: Color

    init(from spec: DraftLayerSpec, color: Color) {
        self.id = spec.id
        self.bundleName = spec.bundleName
        self.label = spec.label
        self.type = spec.type
        self.strandExprs = spec.strandExprs
        self.color = color
    }
}

// MARK: - Draft View

struct DraftView: View {
    let coordinator: Coordinator
    @Binding var draftNodeName: String?
    @StateObject private var state = DraftState()
    @State private var dragStart: CGPoint? = nil
    @State private var timer: AnyCancellable? = nil

    var body: some View {
        VStack(spacing: 0) {
            if state.layers.isEmpty {
                EmptyStateView(
                    "perspective",
                    message: "No chain selected",
                    hint: "Select a node in Graph and tap \"View in Draft\""
                )
            } else {
                HSplitView {
                    draftCanvas
                        .frame(minWidth: 200)
                    DraftLayerPanel(state: state, coordinator: coordinator)
                        .frame(minWidth: 120, idealWidth: 150, maxWidth: 200)
                }

                SubtleDivider(.horizontal)

                DraftControls(state: state, coordinator: coordinator)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onChange(of: draftNodeName) { _, newName in
            if let name = newName {
                setupChain(for: name)
            }
        }
        .onChange(of: state.resolution) { _, _ in refreshSamples() }
        .onChange(of: state.regionMin) { _, _ in refreshSamples() }
        .onChange(of: state.regionMax) { _, _ in refreshSamples() }
        .onChange(of: state.scrubTime) { _, _ in
            if !state.isPlaying { refreshSamples() }
        }
        .onChange(of: state.layers.count) { _, _ in refreshSamples() }
        .onChange(of: state.isPlaying) { _, playing in
            if playing { startTimer() } else { stopTimer() }
        }
        .onAppear {
            if let name = draftNodeName {
                setupChain(for: name)
            }
            if state.isPlaying { startTimer() }
        }
        .onDisappear { stopTimer() }
    }

    // MARK: - Timer for Live Playback

    private func startTimer() {
        stopTimer()
        timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in refreshSamples() }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func refreshSamples() {
        let time = state.isPlaying ? coordinator.time : state.scrubTime
        evaluateSamples(time: time)
    }

    // MARK: - 3D Canvas

    private var draftCanvas: some View {
        Canvas { context, size in
            drawDraft(context: context, size: size)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .gesture(dragGesture)
        .gesture(tapGesture)
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

        let layers = specs.enumerated().map { (i, spec) -> DraftLayer in
            let t = specs.count <= 1 ? 0.0 : Double(i) / Double(specs.count - 1)
            return DraftLayer(from: spec, color: layerColor(t: t))
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

    private func evaluateSamples(time: Double) {
        guard let program = coordinator.program, !state.layers.isEmpty else {
            state.samples = []
            return
        }

        let interpreter = IRInterpreter(program: program)
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

    private func drawDraft(context: GraphicsContext, size: CGSize) {
        guard !state.layers.isEmpty else { return }

        let layerCount = state.layers.count
        let totalSpread = state.spread * Double(layerCount - 1) * 1.5
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
            let z = layerZ(li, layerCount, totalSpread)
            drawables.append(Drawable(kind: state.layers[li].type.isPlane ? .planeOutline(li) : .axisLine(li),
                                      depth: state.camera.depth(SIMD3(0, 0, z))))
        }

        for si in 0..<samples.count {
            for li in 0..<Swift.min(samples[si].count, layerCount) {
                let z = layerZ(li, layerCount, totalSpread)
                let val = samples[si][li]
                let nx = norm(val.x, ranges[li].min.x, ranges[li].max.x) - 0.5
                let ny = norm(val.y, ranges[li].min.y, ranges[li].max.y) - 0.5
                drawables.append(Drawable(kind: .point(si, li), depth: state.camera.depth(SIMD3(nx, ny, z))))
            }
        }

        for si in state.selectedSampleIndices where si < samples.count {
            drawables.append(Drawable(kind: .connector(si), depth: state.camera.depth(SIMD3(0, 0, layerZ(0, layerCount, totalSpread))) - 0.01))
        }

        drawables.sort { $0.depth > $1.depth }

        for d in drawables {
            switch d.kind {
            case .planeOutline(let li): drawPlane(context, size, li, layerCount, totalSpread)
            case .axisLine(let li): drawAxis(context, size, li, layerCount, totalSpread)
            case .point(let si, let li): drawPt(context, size, si, li, layerCount, totalSpread, ranges, samples)
            case .connector(let si): drawLine(context, size, si, layerCount, totalSpread, ranges, samples)
            }
        }

        // Labels
        for li in 0..<layerCount {
            let z = layerZ(li, layerCount, totalSpread)
            let p = state.camera.project(SIMD3(-0.6, 0.55, z), viewSize: size)
            context.draw(
                Text(state.layers[li].label).font(.system(size: 9, weight: .medium)).foregroundColor(state.layers[li].color),
                at: p, anchor: .leading
            )
        }
    }

    private func layerZ(_ i: Int, _ count: Int, _ spread: Double) -> Double {
        guard count > 1 else { return 0 }
        return -spread / 2 + spread * Double(i) / Double(count - 1)
    }

    private func norm(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo else { return 0.5 }
        return (v - lo) / (hi - lo)
    }

    private func drawPlane(_ ctx: GraphicsContext, _ sz: CGSize, _ li: Int, _ cnt: Int, _ sp: Double) {
        let z = layerZ(li, cnt, sp)
        let c = [SIMD3(-0.5, -0.5, z), SIMD3(0.5, -0.5, z), SIMD3(0.5, 0.5, z), SIMD3(-0.5, 0.5, z)]
        let p = c.map { state.camera.project($0, viewSize: sz) }
        var path = Path()
        path.move(to: p[0]); path.addLine(to: p[1]); path.addLine(to: p[2]); path.addLine(to: p[3])
        path.closeSubpath()
        let col = state.layers[li].color
        ctx.fill(path, with: .color(col.opacity(0.04)))
        ctx.stroke(path, with: .color(col.opacity(0.3)), lineWidth: 1)
    }

    private func drawAxis(_ ctx: GraphicsContext, _ sz: CGSize, _ li: Int, _ cnt: Int, _ sp: Double) {
        let z = layerZ(li, cnt, sp)
        var path = Path()
        path.move(to: state.camera.project(SIMD3(0, 0.5, z), viewSize: sz))
        path.addLine(to: state.camera.project(SIMD3(0, -0.5, z), viewSize: sz))
        ctx.stroke(path, with: .color(state.layers[li].color.opacity(0.5)), lineWidth: 2)
    }

    private func drawPt(_ ctx: GraphicsContext, _ sz: CGSize, _ si: Int, _ li: Int,
                         _ cnt: Int, _ sp: Double,
                         _ ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)],
                         _ samples: [[SIMD2<Double>]]) {
        guard si < samples.count, li < samples[si].count else { return }
        let val = samples[si][li]
        let z = layerZ(li, cnt, sp)
        let r = ranges[li]
        let pt: SIMD3<Double>
        switch state.layers[li].type {
        case .plane:
            pt = SIMD3(norm(val.x, r.min.x, r.max.x) - 0.5, norm(val.y, r.min.y, r.max.y) - 0.5, z)
        case .axis:
            pt = SIMD3(0, norm(val.x, r.min.x, r.max.x) - 0.5, z)
        }
        let sp2 = state.camera.project(pt, viewSize: sz)
        let sel = state.selectedSampleIndices.contains(si)
        let rad: CGFloat = sel ? 4 : 2.5
        ctx.fill(Path(ellipseIn: CGRect(x: sp2.x - rad, y: sp2.y - rad, width: rad * 2, height: rad * 2)),
                 with: .color(state.layers[li].color.opacity(sel ? 1.0 : 0.7)))
    }

    private func drawLine(_ ctx: GraphicsContext, _ sz: CGSize, _ si: Int,
                           _ cnt: Int, _ sp: Double,
                           _ ranges: [(min: SIMD2<Double>, max: SIMD2<Double>)],
                           _ samples: [[SIMD2<Double>]]) {
        guard si < samples.count, samples[si].count >= cnt else { return }
        let sample = samples[si]
        var pts: [CGPoint] = []
        for li in 0..<cnt {
            let val = sample[li]
            let z = layerZ(li, cnt, sp)
            let r = ranges[li]
            let pt: SIMD3<Double>
            switch state.layers[li].type {
            case .plane:
                pt = SIMD3(norm(val.x, r.min.x, r.max.x) - 0.5, norm(val.y, r.min.y, r.max.y) - 0.5, z)
            case .axis:
                pt = SIMD3(0, norm(val.x, r.min.x, r.max.x) - 0.5, z)
            }
            pts.append(state.camera.project(pt, viewSize: sz))
        }
        guard pts.count >= 2 else { return }
        var path = Path()
        path.move(to: pts[0])
        for i in 1..<pts.count { path.addLine(to: pts[i]) }
        ctx.stroke(path, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    // MARK: - Tap Handling

    private func handleTap(at location: CGPoint) {
        guard !state.samples.isEmpty, !state.layers.isEmpty else {
            state.selectedSampleIndices = []
            return
        }

        let layerCount = state.layers.count
        let totalSpread = state.spread * Double(layerCount - 1) * 1.5
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

        // Need actual view size for hit testing — use a reasonable default
        let size = CGSize(width: 400, height: 300)
        var bestDist = Double.infinity
        var bestSample = -1

        for si in 0..<samples.count {
            for li in 0..<Swift.min(samples[si].count, layerCount) {
                let val = samples[si][li]
                let z = layerZ(li, layerCount, totalSpread)
                let r = ranges[li]
                let pt: SIMD3<Double>
                switch state.layers[li].type {
                case .plane:
                    pt = SIMD3(norm(val.x, r.min.x, r.max.x) - 0.5, norm(val.y, r.min.y, r.max.y) - 0.5, z)
                case .axis:
                    pt = SIMD3(0, norm(val.x, r.min.x, r.max.x) - 0.5, z)
                }
                let sp = state.camera.project(pt, viewSize: size)
                let dx = sp.x - location.x
                let dy = sp.y - location.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestDist { bestDist = dist; bestSample = si }
            }
        }

        if bestDist < 15 && bestSample >= 0 {
            if state.selectedSampleIndices.contains(bestSample) {
                state.selectedSampleIndices.remove(bestSample)
            } else {
                state.selectedSampleIndices = [bestSample]
            }
        } else {
            state.selectedSampleIndices = []
        }
    }
}

// MARK: - LayerType Extension

extension DraftLayerSpec.LayerType {
    var isPlane: Bool {
        switch self {
        case .plane: return true
        case .axis: return false
        }
    }
}
