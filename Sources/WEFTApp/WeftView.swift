// WeftView.swift - Metal view for WEFT rendering with input handling

import SwiftUI
import MetalKit
import WEFTLib
import AppKit

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

// MARK: - Input-Aware MTKView

/// Custom MTKView subclass that handles mouse and keyboard input
class InputAwareMTKView: MTKView {
    /// Tracking area for mouse events
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking area
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        // Create new tracking area covering the entire view
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseMoved,
            .mouseEnteredAndExited,
            .inVisibleRect
        ]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Become first responder to receive keyboard events
        window?.makeFirstResponder(self)
    }

    // MARK: - Mouse Events

    private func updateMousePosition(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let normalizedX = Float(location.x / bounds.width)
        // Flip Y coordinate: NSView origin is bottom-left, WEFT uses bottom-left too
        let normalizedY = Float(location.y / bounds.height)
        InputState.shared.updateMousePosition(x: normalizedX, y: normalizedY)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
        updateMousePosition(with: event)
        InputState.shared.updateMouseButton(isDown: true)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        updateMousePosition(with: event)
        InputState.shared.updateMouseButton(isDown: false)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateMousePosition(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        updateMousePosition(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateMousePosition(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Don't update position when exiting - keep last known position
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        InputState.shared.updateKey(keyCode: event.keyCode, isDown: true)
        // Don't call super to avoid system beep
    }

    override func keyUp(with event: NSEvent) {
        InputState.shared.updateKey(keyCode: event.keyCode, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Handle modifier keys (shift, control, option, command)
        let flags = event.modifierFlags

        // Shift (key code 56)
        InputState.shared.updateKey(keyCode: 56, isDown: flags.contains(.shift))
        // Control (key code 59)
        InputState.shared.updateKey(keyCode: 59, isDown: flags.contains(.control))
        // Option/Alt (key code 58)
        InputState.shared.updateKey(keyCode: 58, isDown: flags.contains(.option))
        // Command (key code 55)
        InputState.shared.updateKey(keyCode: 55, isDown: flags.contains(.command))
    }
}

// MARK: - Metal View Representable

struct WeftMetalView: NSViewRepresentable {
    let coordinator: Coordinator

    func makeCoordinator() -> WeftMetalViewCoordinator {
        WeftMetalViewCoordinator(coordinator: coordinator)
    }

    func makeNSView(context: Context) -> InputAwareMTKView {
        let view = InputAwareMTKView()

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

    func updateNSView(_ nsView: InputAwareMTKView, context: Context) {
        // Update if needed
    }
}
