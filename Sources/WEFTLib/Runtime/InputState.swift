// InputState.swift - Global input state for mouse and keyboard

import Foundation

/// Thread-safe input state manager for mouse and keyboard events
/// These are universal inputs available to all backends (visual and audio)
public class InputState {
    /// Shared singleton instance
    public static let shared = InputState()

    // MARK: - Mouse State

    /// Normalized mouse X position (0-1, left to right)
    public private(set) var mouseX: Float = 0.5

    /// Normalized mouse Y position (0-1, bottom to top for WEFT convention)
    public private(set) var mouseY: Float = 0.5

    /// Mouse button state (1.0 if pressed, 0.0 otherwise)
    public private(set) var mouseDown: Float = 0.0

    /// Whether the mouse is currently over the canvas view (for probe activation)
    public private(set) var mouseOverCanvas: Bool = false

    // MARK: - Keyboard State

    /// Key states indexed by virtual key code (0-255)
    /// Value is 1.0 if pressed, 0.0 if released
    private var keyStates: [Float] = Array(repeating: 0.0, count: 256)

    /// Lock for thread-safe access
    private let lock = NSLock()

    private init() {}

    // MARK: - Mouse Updates

    /// Update mouse position (normalized 0-1 coordinates)
    /// - Parameters:
    ///   - x: Normalized X position (0 = left, 1 = right)
    ///   - y: Normalized Y position (0 = bottom, 1 = top) - WEFT convention
    public func updateMousePosition(x: Float, y: Float) {
        lock.lock()
        defer { lock.unlock() }
        mouseX = max(0, min(1, x))
        mouseY = max(0, min(1, y))
    }

    /// Update mouse button state
    /// - Parameter isDown: true if mouse button is pressed
    public func updateMouseButton(isDown: Bool) {
        lock.lock()
        defer { lock.unlock() }
        mouseDown = isDown ? 1.0 : 0.0
    }

    /// Update whether the mouse is over the canvas view
    public func updateMouseOverCanvas(_ over: Bool) {
        lock.lock()
        defer { lock.unlock() }
        mouseOverCanvas = over
    }

    // MARK: - Keyboard Updates

    /// Update key state
    /// - Parameters:
    ///   - keyCode: Virtual key code (0-255)
    ///   - isDown: true if key is pressed
    public func updateKey(keyCode: UInt16, isDown: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let index = Int(keyCode) & 0xFF
        keyStates[index] = isDown ? 1.0 : 0.0
    }

    /// Get state of a specific key
    /// - Parameter keyCode: Virtual key code to check
    /// - Returns: 1.0 if pressed, 0.0 otherwise
    public func getKeyState(keyCode: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        let index = keyCode & 0xFF
        return keyStates[index]
    }

    // MARK: - Bulk Access

    /// Get current mouse state as (x, y, down) tuple
    public func getMouseState() -> (x: Float, y: Float, down: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (mouseX, mouseY, mouseDown)
    }

    /// Copy all key states into provided buffer
    /// - Parameter buffer: Buffer to copy key states into (must have at least 256 elements)
    public func copyKeyStates(to buffer: UnsafeMutablePointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<256 {
            buffer[i] = keyStates[i]
        }
    }

    /// Reset all input state
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        mouseX = 0.5
        mouseY = 0.5
        mouseDown = 0.0
        mouseOverCanvas = false
        for i in 0..<256 {
            keyStates[i] = 0.0
        }
    }
}

// MARK: - Key Code Constants

/// Common key codes for macOS (for convenience in WEFT programs)
/// These match the JavaScript key codes used in std_io.weft
public enum WeftKeyCode: Int {
    // Arrow keys
    case leftArrow = 123   // macOS virtual key code
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126

    // Modifiers
    case shift = 56
    case control = 59
    case option = 58  // alt
    case command = 55

    // Common keys
    case space = 49
    case enter = 36
    case escape = 53
    case tab = 48
    case delete = 51

    // Letters (macOS key codes)
    case a = 0, b = 11, c = 8, d = 2, e = 14, f = 3, g = 5, h = 4
    case i = 34, j = 38, k = 40, l = 37, m = 46, n = 45, o = 31, p = 35
    case q = 12, r = 15, s = 1, t = 17, u = 32, v = 9, w = 13, x = 7
    case y = 16, z = 6

    // Numbers
    case n0 = 29, n1 = 18, n2 = 19, n3 = 20, n4 = 21
    case n5 = 23, n6 = 22, n7 = 26, n8 = 28, n9 = 25
}
