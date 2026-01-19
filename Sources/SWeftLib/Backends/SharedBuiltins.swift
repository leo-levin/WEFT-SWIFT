// SharedBuiltins.swift - Shared builtin definitions for all backends
//
// This file defines the canonical list of builtins that backends should support.
// Each backend implements these in its native language (Metal MSL, Swift, etc.)
// but the semantics should be identical.

import Foundation

// MARK: - Builtin Categories

/// Categories of builtin functions, used for documentation and validation.
public enum BuiltinCategory: String, CaseIterable {
    case math           // sin, cos, etc.
    case utility        // min, max, clamp, etc.
    case noise          // noise, perlin, etc.
    case state          // cache
    case control        // select
    case hardware       // camera, microphone, texture
}

// MARK: - Builtin Definitions

/// Definition of a builtin function.
public struct BuiltinDef {
    /// Function name in WEFT IR
    public let name: String

    /// Number of arguments (-1 for variadic)
    public let arity: Int

    /// Category for documentation
    public let category: BuiltinCategory

    /// Brief description
    public let description: String

    /// Whether this is domain-specific (false = should work in all backends)
    public let domainSpecific: Bool

    public init(
        name: String,
        arity: Int,
        category: BuiltinCategory,
        description: String,
        domainSpecific: Bool = false
    ) {
        self.name = name
        self.arity = arity
        self.category = category
        self.description = description
        self.domainSpecific = domainSpecific
    }
}

// MARK: - Canonical Builtin List

/// Shared definitions of all builtins that backends should support.
/// This is the single source of truth for builtin function signatures.
public enum SharedBuiltins {

    /// All builtin definitions
    public static let all: [BuiltinDef] = [
        // Math - single argument
        BuiltinDef(name: "sin", arity: 1, category: .math, description: "Sine"),
        BuiltinDef(name: "cos", arity: 1, category: .math, description: "Cosine"),
        BuiltinDef(name: "tan", arity: 1, category: .math, description: "Tangent"),
        BuiltinDef(name: "asin", arity: 1, category: .math, description: "Arc sine"),
        BuiltinDef(name: "acos", arity: 1, category: .math, description: "Arc cosine"),
        BuiltinDef(name: "atan", arity: 1, category: .math, description: "Arc tangent"),
        BuiltinDef(name: "abs", arity: 1, category: .math, description: "Absolute value"),
        BuiltinDef(name: "floor", arity: 1, category: .math, description: "Floor"),
        BuiltinDef(name: "ceil", arity: 1, category: .math, description: "Ceiling"),
        BuiltinDef(name: "round", arity: 1, category: .math, description: "Round to nearest"),
        BuiltinDef(name: "sqrt", arity: 1, category: .math, description: "Square root"),
        BuiltinDef(name: "exp", arity: 1, category: .math, description: "e^x"),
        BuiltinDef(name: "log", arity: 1, category: .math, description: "Natural log"),
        BuiltinDef(name: "log2", arity: 1, category: .math, description: "Log base 2"),
        BuiltinDef(name: "sign", arity: 1, category: .math, description: "Sign (-1, 0, 1)"),
        BuiltinDef(name: "fract", arity: 1, category: .math, description: "Fractional part"),

        // Math - two arguments
        BuiltinDef(name: "atan2", arity: 2, category: .math, description: "Arc tangent of y/x"),
        BuiltinDef(name: "pow", arity: 2, category: .math, description: "Power x^y"),
        BuiltinDef(name: "mod", arity: 2, category: .math, description: "Modulo"),
        BuiltinDef(name: "min", arity: 2, category: .utility, description: "Minimum"),
        BuiltinDef(name: "max", arity: 2, category: .utility, description: "Maximum"),
        BuiltinDef(name: "step", arity: 2, category: .utility, description: "Step function (0 if x < edge, else 1)"),

        // Utility - three arguments
        BuiltinDef(name: "clamp", arity: 3, category: .utility, description: "Clamp to range"),
        BuiltinDef(name: "lerp", arity: 3, category: .utility, description: "Linear interpolation"),
        BuiltinDef(name: "mix", arity: 3, category: .utility, description: "Linear interpolation (alias for lerp)"),
        BuiltinDef(name: "smoothstep", arity: 3, category: .utility, description: "Smooth Hermite interpolation"),

        // Noise
        BuiltinDef(name: "noise", arity: -1, category: .noise, description: "Hash-based pseudo-random noise (1-2 args)"),

        // State
        BuiltinDef(name: "cache", arity: 4, category: .state, description: "Signal-driven cache (value, historySize, tapIndex, signal)"),

        // Control
        BuiltinDef(name: "select", arity: -1, category: .control, description: "Select branch by index"),

        // Hardware - domain specific
        BuiltinDef(name: "camera", arity: 3, category: .hardware, description: "Camera input (u, v, channel)", domainSpecific: true),
        BuiltinDef(name: "texture", arity: 4, category: .hardware, description: "Texture sample (id, u, v, channel)", domainSpecific: true),
        BuiltinDef(name: "microphone", arity: 2, category: .hardware, description: "Microphone input (offset, channel)", domainSpecific: true),
    ]

    /// Get builtin by name
    public static func builtin(named name: String) -> BuiltinDef? {
        all.first { $0.name == name }
    }

    /// Get all builtins in a category
    public static func builtins(in category: BuiltinCategory) -> [BuiltinDef] {
        all.filter { $0.category == category }
    }

    /// Get all domain-agnostic builtins (should work in all backends)
    public static var domainAgnostic: [BuiltinDef] {
        all.filter { !$0.domainSpecific }
    }

    /// Set of all builtin names
    public static var allNames: Set<String> {
        Set(all.map { $0.name })
    }

    /// Set of domain-agnostic builtin names
    public static var domainAgnosticNames: Set<String> {
        Set(domainAgnostic.map { $0.name })
    }
}

// MARK: - Backend Validation

extension SharedBuiltins {
    /// Validate that a backend implements all required builtins.
    /// Returns list of missing builtin names.
    public static func validateBackend(
        identifier: String,
        implementedBuiltins: Set<String>,
        ownedBuiltins: Set<String>
    ) -> [String] {
        // Backend should implement all domain-agnostic builtins
        // plus any hardware builtins it owns
        var required = domainAgnosticNames
        required.formUnion(ownedBuiltins)

        let missing = required.subtracting(implementedBuiltins)
        return Array(missing).sorted()
    }
}
