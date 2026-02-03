// IRAnnotations.swift - Domain and access annotations for IR signals

import Foundation

// MARK: - Domain Dimension

/// A dimension with its access level (free or bound)
public struct IRDimension: Hashable, Codable {
    public let name: String
    public let access: IRAccess

    public init(name: String, access: IRAccess) {
        self.name = name
        self.access = access
    }
}

// MARK: - Access Level

/// Access level for a dimension
public enum IRAccess: String, Hashable, Codable {
    /// Seekable - can sample at any value (e.g., x, y coordinates)
    case free
    /// Only "now" - hardware/time constraint (e.g., time, resolution)
    case bound
}

// MARK: - Hardware Requirements

/// Hardware resources that a signal may require
public enum IRHardware: Hashable, Codable {
    case camera
    case microphone
    case speaker
    case gpu
    case custom(String)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "camera": self = .camera
        case "microphone": self = .microphone
        case "speaker": self = .speaker
        case "gpu": self = .gpu
        case "custom":
            let value = try container.decode(String.self, forKey: .value)
            self = .custom(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown hardware type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .camera:
            try container.encode("camera", forKey: .type)
        case .microphone:
            try container.encode("microphone", forKey: .type)
        case .speaker:
            try container.encode("speaker", forKey: .type)
        case .gpu:
            try container.encode("gpu", forKey: .type)
        case .custom(let value):
            try container.encode("custom", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - Annotated Signal

/// An annotated signal wrapping an IR expression with computed metadata
public struct IRSignal {
    /// Full name: "bundle.strand"
    public let name: String

    /// Strand index within the bundle
    public let strandIndex: Int

    /// The underlying IR expression
    public let expr: IRExpr

    /// Computed domain dimensions with access levels
    public let domain: [IRDimension]

    /// Hardware resources required by this signal
    public let hardware: Set<IRHardware>

    /// Whether this signal uses stateful operations (cache, feedback)
    public let stateful: Bool

    public init(
        name: String,
        strandIndex: Int,
        expr: IRExpr,
        domain: [IRDimension],
        hardware: Set<IRHardware>,
        stateful: Bool
    ) {
        self.name = name
        self.strandIndex = strandIndex
        self.expr = expr
        self.domain = domain
        self.hardware = hardware
        self.stateful = stateful
    }

    // MARK: - Derived Properties

    /// True if signal has no hardware dependencies and is not stateful
    public var isPure: Bool {
        hardware.isEmpty && !stateful
    }

    /// True if signal requires external hardware
    public var isExternal: Bool {
        !hardware.isEmpty
    }

    /// Dimension names that are bound (time-constrained)
    public var boundDimensions: [String] {
        domain.filter { $0.access == .bound }.map { $0.name }
    }

    /// Dimension names that are free (seekable)
    public var freeDimensions: [String] {
        domain.filter { $0.access == .free }.map { $0.name }
    }
}

// MARK: - Annotated Program

/// A program with all signals annotated
public struct IRAnnotatedProgram {
    /// Annotated signals indexed by "bundle.strand" key
    public let signals: [String: IRSignal]

    /// The original IR program
    public let original: IRProgram

    public init(signals: [String: IRSignal], original: IRProgram) {
        self.signals = signals
        self.original = original
    }
}

// MARK: - Primitive Specification

/// Specification for a primitive builtin that has special domain behavior
public struct PrimitiveSpec {
    /// Name of the primitive (e.g., "camera", "microphone")
    public let name: String

    /// Output domain dimensions
    public let outputDomain: [IRDimension]

    /// Hardware resources required
    public let hardwareRequired: Set<IRHardware>

    /// Whether this primitive adds state
    public let addsState: Bool

    public init(
        name: String,
        outputDomain: [IRDimension],
        hardwareRequired: Set<IRHardware>,
        addsState: Bool
    ) {
        self.name = name
        self.outputDomain = outputDomain
        self.hardwareRequired = hardwareRequired
        self.addsState = addsState
    }
}

// MARK: - Annotated Program Extensions

extension IRAnnotatedProgram {
    /// Get hardware requirements for a bundle (union of all strands)
    public func bundleHardware(_ bundleName: String) -> Set<IRHardware> {
        var hardware = Set<IRHardware>()
        for (key, signal) in signals {
            if key.hasPrefix("\(bundleName).") {
                hardware.formUnion(signal.hardware)
            }
        }
        return hardware
    }

    /// Check if a bundle is pure (no hardware, not stateful)
    public func isPure(_ bundleName: String) -> Bool {
        for (key, signal) in signals {
            if key.hasPrefix("\(bundleName).") {
                return signal.isPure
            }
        }
        return true  // Unknown bundle is considered pure
    }
}
