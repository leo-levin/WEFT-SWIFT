// InputProvider.swift - Generic input provider protocol for backends
//
// This file defines the protocol hierarchy for hardware input providers.
// Backends declare their input requirements via bindings, and Coordinator
// wires up providers generically without backend-specific code.

import Foundation
import Metal

// MARK: - Base Input Provider Protocol

/// Protocol for hardware input providers.
/// Input providers represent external hardware inputs (microphone, camera, MIDI, etc.)
/// that can be registered with the Coordinator and passed to backends.
public protocol InputProvider: AnyObject {
    /// Unique identifier matching the builtin name (e.g., "microphone", "camera")
    static var builtinName: String { get }

    /// Hardware type this provider requires
    static var hardware: IRHardware { get }

    /// Setup the provider (request permissions, initialize hardware)
    /// - Parameter device: Optional Metal device for GPU-related setup
    func setup(device: MTLDevice?) throws

    /// Start capturing/receiving input
    func start() throws

    /// Stop capturing
    func stop()
}

// MARK: - Audio Input Provider

/// Protocol for audio input providers (microphone, audio files, etc.)
public protocol AudioInputProvider: InputProvider {
    /// Get audio sample at given sample index and channel
    /// - Parameters:
    ///   - sampleIndex: The sample index to retrieve
    ///   - channel: Channel number (0 = left, 1 = right)
    /// - Returns: The sample value as a Float
    func getSample(at sampleIndex: Int, channel: Int) -> Float
}

// MARK: - Visual Input Provider

/// Protocol for visual input providers (camera, video files, etc.)
public protocol VisualInputProvider: InputProvider {
    /// The current texture from this provider
    var texture: MTLTexture? { get }

    /// Sample a pixel value at normalized (u, v) coordinates for a specific channel.
    /// - Parameters:
    ///   - u: Horizontal coordinate (0.0 = left, 1.0 = right)
    ///   - v: Vertical coordinate (0.0 = top, 1.0 = bottom)
    ///   - channel: Color channel (0=R, 1=G, 2=B, 3=A)
    /// - Returns: Normalized pixel value [0, 1]
    func samplePixel(u: Double, v: Double, channel: Int) -> Double
}

extension VisualInputProvider {
    /// Default: returns 0 (override in concrete types)
    public func samplePixel(u: Double, v: Double, channel: Int) -> Double { 0.0 }
}
