// Backend.swift - Protocol for execution backends

import Foundation
import Metal

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

/// Backend protocol - minimal interface for execution backends
public protocol Backend {
    /// Unique identifier for this backend
    static var identifier: String { get }

    /// Builtins this backend owns (determines ownership of bundles using these)
    static var ownedBuiltins: Set<String> { get }

    /// External builtins - hardware/outside world inputs (camera, microphone)
    static var externalBuiltins: Set<String> { get }

    /// Stateful builtins - functions that maintain state (cache)
    static var statefulBuiltins: Set<String> { get }

    /// All bindings (inputs and outputs) for this backend
    static var bindings: [BackendBinding] { get }

    /// Coordinate fields provided by this backend (e.g., ["x", "y", "t"] for visual)
    static var coordinateFields: [String] { get }

    /// Compile a swatch to native code
    func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit

    /// Execute a compiled unit
    func execute(
        unit: CompiledUnit,
        inputs: [String: any Buffer],
        outputs: [String: any Buffer],
        time: Double
    )
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

/// Buffer for cross-domain data transfer
public class CrossDomainBuffer: Buffer {
    public let name: String
    public var data: [Float]
    public let width: Int
    public let height: Int

    public init(name: String, width: Int, height: Int = 1) {
        self.name = name
        self.width = width
        self.height = height
        self.data = [Float](repeating: 0, count: width * height)
    }
}
