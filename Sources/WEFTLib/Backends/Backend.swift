// Backend.swift - Protocol for execution backends

import Foundation
import Metal
import os

// MARK: - Backend Bindings

/// Unified abstraction for all special backend interactions
public enum BackendBinding {
    /// External input: builtin that reads from outside world
    case input(InputBinding)

    /// Output sink: special bundle name that writes to outside world
    case output(OutputBinding)
}

/// Describes an external input (camera, microphone, texture)
public struct InputBinding: Hashable {
    /// Builtin function name in WEFT IR (e.g., "camera", "microphone")
    public let builtinName: String

    /// Metal shader parameter declaration (nil for CPU-only backends)
    public let shaderParam: String?

    /// GPU texture slot index (nil for CPU-only backends)
    public let textureIndex: Int?

    public init(builtinName: String, shaderParam: String? = nil, textureIndex: Int? = nil) {
        self.builtinName = builtinName
        self.shaderParam = shaderParam
        self.textureIndex = textureIndex
    }
}

/// Describes an output sink (display, play)
public struct OutputBinding: Hashable {
    /// Bundle name in WEFT IR (e.g., "display", "play")
    public let bundleName: String

    /// Kernel/callback name in generated code
    public let kernelName: String

    public init(bundleName: String, kernelName: String) {
        self.bundleName = bundleName
        self.kernelName = kernelName
    }
}

// MARK: - Buffer Protocol

/// Abstraction over Metal textures, audio buffers, etc.
public protocol Buffer {
    var name: String { get }
    var width: Int { get }
    var height: Int { get }  // 1 for audio buffers
}

// MARK: - Compiled Unit Protocol

/// Abstraction over compiled Metal pipeline, audio callback, etc.
public protocol CompiledUnit {
    var swatchId: UUID { get }
}

// MARK: - Backend Protocol

/// Backend protocol - minimal interface for execution backends.
///
/// A backend is a "renderer" for WEFT IR. It defines:
/// - What coordinates mean (pixels, samples, MIDI notes, etc.)
/// - How to execute expressions in that domain
/// - What resources it provides (camera, microphone, MIDI input, etc.)
///
/// The IR itself is domain-agnostic - it's just math. Backends give meaning to
/// coordinates like `me.x`, `me.y`, `me.t` etc.
///
/// ## Implementing a New Backend
///
/// 1. Create a new class conforming to `Backend`
/// 2. Define static properties for identification and capabilities
/// 3. Implement `compile(swatch:ir:)` to generate executable code
/// 4. Implement `execute(...)` to run the compiled code
/// 5. Register your backend with `BackendRegistry.shared.register(YourBackend.self)`
///
/// ## Example: Skeleton MIDIBackend
///
/// ```swift
/// public class MIDIBackend: Backend {
///     public static let identifier = "midi"
///     public static let ownedBuiltins: Set<String> = ["midiNote", "midiCC"]
///     public static let externalBuiltins: Set<String> = ["midiNote"]
///     public static let statefulBuiltins: Set<String> = ["cache"]
///     public static let coordinateFields = ["note", "velocity", "channel", "t"]
///     public static let bindings: [BackendBinding] = [
///         .input(InputBinding(builtinName: "midiNote")),
///         .output(OutputBinding(bundleName: "send", kernelName: "midiCallback"))
///     ]
///
///     public func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit {
///         // Generate MIDI message callbacks from IR expressions
///     }
///
///     public func execute(unit: CompiledUnit, inputs: [...], outputs: [...], time: Double) {
///         // Send MIDI messages
///     }
/// }
/// ```
///
public protocol Backend {
    /// Unique identifier for this backend (e.g., "visual", "audio", "midi").
    /// Used by the partitioner to route bundles to the correct backend.
    static var identifier: String { get }

    /// Hardware resources this backend claims ownership of.
    /// Signals requiring this hardware will be routed to this backend.
    /// Examples: [.camera, .gpu] for visual, [.microphone, .speaker] for audio
    static var hardwareOwned: Set<IRHardware> { get }

    /// Builtins this backend "owns" - bundles using these builtins are assigned to this backend.
    /// Examples: "camera" owned by visual, "microphone" owned by audio.
    /// Ownership is used during partitioning to determine which backend compiles each bundle.
    static var ownedBuiltins: Set<String> { get }

    /// External builtins - hardware or outside-world inputs that this backend provides.
    /// These require special handling (device setup, permissions, etc.).
    /// Subset of ownedBuiltins that represents actual hardware I/O.
    static var externalBuiltins: Set<String> { get }

    /// Stateful builtins - functions that maintain state across invocations.
    /// Currently just "cache" which implements signal-driven feedback.
    static var statefulBuiltins: Set<String> { get }

    /// Bindings define the special bundle names and builtins for this backend:
    /// - `.input(InputBinding)`: External inputs like camera, microphone
    /// - `.output(OutputBinding)`: Sink bundles like "display", "play"
    static var bindings: [BackendBinding] { get }

    /// Coordinate fields available in this domain via `me.field`.
    /// The IR uses `me.x`, `me.y`, etc. - backends define what these mean.
    ///
    /// - Visual: `["x", "y", "t", "w", "h"]` - normalized pixel coords + resolution
    /// - Audio: `["i", "t", "sampleRate"]` - sample index, time, sample rate
    /// - MIDI: `["note", "velocity", "channel", "t"]` - MIDI message fields
    static var coordinateFields: [String] { get }

    /// Compile a swatch (group of related bundles) to executable code.
    ///
    /// The swatch contains bundle names owned by this backend. The implementation should:
    /// 1. Look up bundle definitions in the IRProgram
    /// 2. Generate code for each strand expression
    /// 3. Return a CompiledUnit that can be executed later
    ///
    /// - Parameters:
    ///   - swatch: The swatch containing bundles to compile
    ///   - ir: The complete IR program for resolving references
    /// - Returns: A compiled unit ready for execution
    /// - Throws: `BackendError` if compilation fails
    func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit

    /// Execute a compiled unit.
    ///
    /// - Parameters:
    ///   - unit: The compiled unit from `compile()`
    ///   - inputs: Input buffers from other backends (cross-domain data)
    ///   - outputs: Output buffers to write results to
    ///   - time: Current execution time in seconds
    func execute(
        unit: CompiledUnit,
        inputs: [String: any Buffer],
        outputs: [String: any Buffer],
        time: Double
    )

    /// Set input providers before compilation.
    /// Called by Coordinator with providers matching this backend's externalBuiltins.
    ///
    /// - Parameter providers: Dictionary mapping builtin names to their providers
    func setInputProviders(_ providers: [String: any InputProvider])
}

// MARK: - Backend Default Implementations

public extension Backend {
    /// Default empty implementation - backends that don't need input providers can ignore this
    func setInputProviders(_ providers: [String: any InputProvider]) {
        // Default: do nothing
    }
}

// MARK: - Backend Errors

public enum BackendError: Error, LocalizedError {
    case compilationFailed(String)
    case executionFailed(String)
    case unsupportedExpression(String)
    case missingResource(String)
    case deviceNotAvailable(String)

    public var errorDescription: String? {
        switch self {
        case .compilationFailed(let msg):
            return "Compilation failed: \(msg)"
        case .executionFailed(let msg):
            return "Execution failed: \(msg)"
        case .unsupportedExpression(let msg):
            return "Unsupported expression: \(msg)"
        case .missingResource(let msg):
            return "Missing resource: \(msg)"
        case .deviceNotAvailable(let msg):
            return "Device not available: \(msg)"
        }
    }
}

// MARK: - Metal Buffer

/// Metal texture buffer
public class MetalBuffer: Buffer {
    public let name: String
    public let texture: MTLTexture
    public let width: Int
    public let height: Int

    public init(name: String, texture: MTLTexture) {
        self.name = name
        self.texture = texture
        self.width = texture.width
        self.height = texture.height
    }
}

// MARK: - Audio Buffer

/// Audio sample buffer
public class AudioBuffer: Buffer {
    public let name: String
    public var samples: [Float]
    public let width: Int
    public let height: Int = 1
    public let sampleRate: Double

    public init(name: String, sampleCount: Int, sampleRate: Double = 44100) {
        self.name = name
        self.samples = [Float](repeating: 0, count: sampleCount)
        self.width = sampleCount
        self.sampleRate = sampleRate
    }
}

// MARK: - Cross-Domain Buffer

/// Buffer for cross-domain data transfer (thread-safe for audio→Metal path)
public class CrossDomainBuffer: Buffer {
    public let name: String
    public let width: Int
    public let height: Int

    private let _lock: OSAllocatedUnfairLock<[Float]>

    public init(name: String, width: Int, height: Int = 1) {
        self.name = name
        self.width = width
        self.height = height
        self._lock = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: width * height))
    }

    /// Thread-safe read — returns a snapshot of the current data
    public var data: [Float] {
        _lock.withLock { $0 }
    }

    /// Thread-safe write at a specific index (call from audio render callback)
    public func write(index: Int, value: Float) {
        _lock.withLock { data in
            if index < data.count {
                data[index] = value
            }
        }
    }
}
