// WeftView.swift - Metal view for WEFT rendering

import SwiftUI
import MetalKit
import SWeftLib

// MARK: - Render Stats

public class RenderStats: ObservableObject {
    public static let shared = RenderStats()

    @Published public var fps: Double = 0
    @Published public var frameTime: Double = 0
    @Published public var frameCount: Int = 0
    @Published public var droppedFrames: Int = 0

    private var lastFrameTime: CFTimeInterval = 0
    private var frameTimeSamples: [Double] = []
    private var lastStatsUpdate: CFTimeInterval = 0
    private var expectedFrameTime: Double = 1.0 / 60.0

    func recordFrame() {
        let now = CACurrentMediaTime()
        frameCount += 1

        if lastFrameTime > 0 {
            let delta = now - lastFrameTime
            frameTimeSamples.append(delta)

            // Detect dropped frames (frame took > 1.5x expected)
            if delta > expectedFrameTime * 1.5 {
                droppedFrames += 1
            }

            // Update stats every 0.5 seconds
            if now - lastStatsUpdate > 0.5 {
                let avgFrameTime = frameTimeSamples.reduce(0, +) / Double(frameTimeSamples.count)
                DispatchQueue.main.async {
                    self.frameTime = avgFrameTime * 1000 // ms
                    self.fps = 1.0 / avgFrameTime
                }
                frameTimeSamples.removeAll()
                lastStatsUpdate = now
            }
        }

        lastFrameTime = now
    }

    func reset() {
        DispatchQueue.main.async {
            self.fps = 0
            self.frameTime = 0
            self.frameCount = 0
            self.droppedFrames = 0
        }
        lastFrameTime = 0
        frameTimeSamples.removeAll()
        lastStatsUpdate = 0
    }
}

// MARK: - Metal View Coordinator

class WeftMetalViewCoordinator: NSObject, MTKViewDelegate {
    var weftCoordinator: Coordinator
    var startTime: CFTimeInterval = 0

    init(coordinator: Coordinator) {
        self.weftCoordinator = coordinator
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle resize if needed
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }

        // Calculate time
        if startTime == 0 {
            startTime = CACurrentMediaTime()
        }
        let time = CACurrentMediaTime() - startTime

        // Render frame
        weftCoordinator.renderVisual(to: drawable, time: time)

        // Record stats
        RenderStats.shared.recordFrame()
    }
}

// MARK: - Metal View Representable

struct WeftMetalView: NSViewRepresentable {
    let coordinator: Coordinator

    func makeCoordinator() -> WeftMetalViewCoordinator {
        WeftMetalViewCoordinator(coordinator: coordinator)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()

        if let device = coordinator.getMetalBackend()?.device {
            view.device = device
        } else {
            view.device = MTLCreateSystemDefaultDevice()
        }

        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Update if needed
    }
}
