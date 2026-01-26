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

// MARK: - Builtin Argument Types

/// Type of argument for a builtin function.
/// Used by the lowering pass to determine how to handle arguments.
public enum BuiltinArgType: Equatable {
    /// Standard numeric expression
    case numeric
    /// String literal that becomes a resource ID after lowering
    case string
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

    /// Types for each argument (nil = all numeric, the default)
    public let argTypes: [BuiltinArgType]?

    /// Output width for multi-strand returns (nil = 1 for scalar builtins)
    public let outputWidth: Int?

    /// Whether this builtin requires string argument handling at lowering time
    public var isResourceBuiltin: Bool {
        argTypes?.contains(.string) ?? false
    }

    public init(
        name: String,
        arity: Int,
        category: BuiltinCategory,
        description: String,
        domainSpecific: Bool = false,
        argTypes: [BuiltinArgType]? = nil,
        outputWidth: Int? = nil
    ) {
        self.name = name
        self.arity = arity
        self.category = category
        self.description = description
        self.domainSpecific = domainSpecific
        self.argTypes = argTypes
        self.outputWidth = outputWidth
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
        BuiltinDef(name: "text", arity: 3, category: .hardware, description: "Render text (content, x, y) -> alpha", domainSpecific: true, argTypes: [.string, .numeric, .numeric], outputWidth: 1),
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

// MARK: - Operator Registry

/// Shared definitions and code generation for binary and unary operators.
/// Both Metal and Audio backends use identical logic for these operators.
public enum OperatorRegistry {
    /// All supported binary operators
    public static let binaryOps = ["+", "-", "*", "/", "%", "^", "<", ">", "<=", ">=", "==", "!=", "&&", "||"]

    /// All supported unary operators
    public static let unaryOps = ["-", "!"]

    /// Generate Metal code for binary operation
    public static func metalBinary(_ op: String, left: String, right: String) -> String? {
        switch op {
        case "+": return "(\(left) + \(right))"
        case "-": return "(\(left) - \(right))"
        case "*": return "(\(left) * \(right))"
        case "/": return "(\(left) / \(right))"
        case "%": return "fmod(\(left), \(right))"
        case "^": return "pow(\(left), \(right))"
        case "<": return "(\(left) < \(right) ? 1.0 : 0.0)"
        case ">": return "(\(left) > \(right) ? 1.0 : 0.0)"
        case "<=": return "(\(left) <= \(right) ? 1.0 : 0.0)"
        case ">=": return "(\(left) >= \(right) ? 1.0 : 0.0)"
        case "==": return "(\(left) == \(right) ? 1.0 : 0.0)"
        case "!=": return "(\(left) != \(right) ? 1.0 : 0.0)"
        case "&&": return "((\(left) != 0.0 && \(right) != 0.0) ? 1.0 : 0.0)"
        case "||": return "((\(left) != 0.0 || \(right) != 0.0) ? 1.0 : 0.0)"
        default: return nil
        }
    }

    /// Generate Metal code for unary operation
    public static func metalUnary(_ op: String, operand: String) -> String? {
        switch op {
        case "-": return "(-\(operand))"
        case "!": return "(\(operand) == 0.0 ? 1.0 : 0.0)"
        default: return nil
        }
    }

    /// Generate Audio evaluator for binary operation
    public static func audioBinary(
        _ op: String,
        left: @escaping (AudioContext) -> Float,
        right: @escaping (AudioContext) -> Float
    ) -> ((AudioContext) -> Float)? {
        switch op {
        case "+": return { ctx in left(ctx) + right(ctx) }
        case "-": return { ctx in left(ctx) - right(ctx) }
        case "*": return { ctx in left(ctx) * right(ctx) }
        case "/": return { ctx in left(ctx) / right(ctx) }
        case "%": return { ctx in fmodf(left(ctx), right(ctx)) }
        case "^": return { ctx in powf(left(ctx), right(ctx)) }
        case "<": return { ctx in left(ctx) < right(ctx) ? 1.0 : 0.0 }
        case ">": return { ctx in left(ctx) > right(ctx) ? 1.0 : 0.0 }
        case "<=": return { ctx in left(ctx) <= right(ctx) ? 1.0 : 0.0 }
        case ">=": return { ctx in left(ctx) >= right(ctx) ? 1.0 : 0.0 }
        case "==": return { ctx in left(ctx) == right(ctx) ? 1.0 : 0.0 }
        case "!=": return { ctx in left(ctx) != right(ctx) ? 1.0 : 0.0 }
        case "&&": return { ctx in (left(ctx) != 0 && right(ctx) != 0) ? 1.0 : 0.0 }
        case "||": return { ctx in (left(ctx) != 0 || right(ctx) != 0) ? 1.0 : 0.0 }
        default: return nil
        }
    }

    /// Generate Audio evaluator for unary operation
    public static func audioUnary(
        _ op: String,
        operand: @escaping (AudioContext) -> Float
    ) -> ((AudioContext) -> Float)? {
        switch op {
        case "-": return { ctx in -operand(ctx) }
        case "!": return { ctx in operand(ctx) == 0 ? 1.0 : 0.0 }
        default: return nil
        }
    }
}

// MARK: - Math Builtin Code Generation

extension SharedBuiltins {
    /// Generate Metal code for a math builtin based on arity
    public static func metalMath(_ name: String, args: [String]) -> String? {
        guard let def = builtin(named: name) else { return nil }

        switch def.arity {
        case 1:
            guard args.count >= 1 else { return nil }
            switch name {
            case "sin", "cos", "tan", "asin", "acos", "atan",
                 "abs", "floor", "ceil", "round", "sqrt", "exp", "log", "log2", "fract", "sign":
                return "\(name)(\(args[0]))"
            default: return nil
            }
        case 2:
            guard args.count >= 2 else { return nil }
            switch name {
            case "pow", "min", "max", "atan2": return "\(name)(\(args[0]), \(args[1]))"
            case "mod": return "fmod(\(args[0]), \(args[1]))"
            case "step": return "step(\(args[0]), \(args[1]))"
            default: return nil
            }
        case 3:
            guard args.count >= 3 else { return nil }
            switch name {
            case "clamp": return "clamp(\(args[0]), \(args[1]), \(args[2]))"
            case "lerp", "mix": return "mix(\(args[0]), \(args[1]), \(args[2]))"
            case "smoothstep": return "smoothstep(\(args[0]), \(args[1]), \(args[2]))"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Generate Metal code for noise
    public static func metalNoise(_ x: String, _ y: String) -> String {
        "fract(sin(dot(float2(\(x), \(y)), float2(12.9898, 78.233))) * 43758.5453)"
    }

    /// Generate Audio evaluator for a math builtin based on arity
    public static func audioMath(
        _ name: String,
        args: [(AudioContext) -> Float]
    ) -> ((AudioContext) -> Float)? {
        guard let def = builtin(named: name) else { return nil }

        switch def.arity {
        case 1:
            guard args.count >= 1 else { return nil }
            let a = args[0]
            switch name {
            case "sin": return { ctx in sinf(a(ctx)) }
            case "cos": return { ctx in cosf(a(ctx)) }
            case "tan": return { ctx in tanf(a(ctx)) }
            case "asin": return { ctx in asinf(a(ctx)) }
            case "acos": return { ctx in acosf(a(ctx)) }
            case "atan": return { ctx in atanf(a(ctx)) }
            case "abs": return { ctx in abs(a(ctx)) }
            case "floor": return { ctx in floorf(a(ctx)) }
            case "ceil": return { ctx in ceilf(a(ctx)) }
            case "round": return { ctx in roundf(a(ctx)) }
            case "sqrt": return { ctx in sqrtf(a(ctx)) }
            case "exp": return { ctx in expf(a(ctx)) }
            case "log": return { ctx in logf(a(ctx)) }
            case "log2": return { ctx in log2f(a(ctx)) }
            case "fract": return { ctx in let v = a(ctx); return v - floorf(v) }
            case "sign": return { ctx in
                let v = a(ctx)
                if v > 0 { return 1.0 }
                if v < 0 { return -1.0 }
                return 0.0
            }
            default: return nil
            }
        case 2:
            guard args.count >= 2 else { return nil }
            let a = args[0], b = args[1]
            switch name {
            case "pow": return { ctx in powf(a(ctx), b(ctx)) }
            case "min": return { ctx in min(a(ctx), b(ctx)) }
            case "max": return { ctx in max(a(ctx), b(ctx)) }
            case "atan2": return { ctx in atan2f(a(ctx), b(ctx)) }
            case "mod": return { ctx in fmodf(a(ctx), b(ctx)) }
            case "step": return { ctx in b(ctx) < a(ctx) ? 0.0 : 1.0 }
            default: return nil
            }
        case 3:
            guard args.count >= 3 else { return nil }
            let a = args[0], b = args[1], c = args[2]
            switch name {
            case "clamp": return { ctx in min(max(a(ctx), b(ctx)), c(ctx)) }
            case "lerp", "mix": return { ctx in
                let av = a(ctx), bv = b(ctx), t = c(ctx)
                return av + (bv - av) * t
            }
            case "smoothstep": return { ctx in
                let edge0 = a(ctx), edge1 = b(ctx), x = c(ctx)
                let t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
                return t * t * (3.0 - 2.0 * t)
            }
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Generate Audio evaluator for noise
    public static func audioNoise(
        x: @escaping (AudioContext) -> Float,
        y: @escaping (AudioContext) -> Float
    ) -> (AudioContext) -> Float {
        return { ctx in
            let xv = x(ctx), yv = y(ctx)
            let dot = xv * 12.9898 + yv * 78.233
            let scaled = sinf(dot) * 43758.5453
            return scaled - floorf(scaled)
        }
    }
}
