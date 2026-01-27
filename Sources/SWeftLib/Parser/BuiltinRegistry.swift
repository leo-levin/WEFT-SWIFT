// BuiltinRegistry.swift - Central registry of WEFT builtin functions

import Foundation

// MARK: - Builtin Categories

/// Simple mathematical and utility builtins that return a single value
public let SCALAR_BUILTINS: Set<String> = [
    "sin", "cos", "tan", "abs", "floor", "ceil", "sqrt", "pow",
    "min", "max", "lerp", "clamp", "step", "smoothstep", "fract", "mod",
    "osc", "cache", "key"
]

/// Resource builtins that return multiple channels (RGB, stereo, etc.)
public struct ResourceBuiltinSpec {
    /// Number of output channels (e.g., 3 for RGB, 2 for stereo)
    public let width: Int

    /// Minimum number of arguments
    public let minArgs: Int

    /// Maximum number of arguments
    public let maxArgs: Int

    public init(width: Int, argCount: Int) {
        self.width = width
        self.minArgs = argCount
        self.maxArgs = argCount
    }

    public init(width: Int, minArgs: Int, maxArgs: Int) {
        self.width = width
        self.minArgs = minArgs
        self.maxArgs = maxArgs
    }
}

/// Registry of resource builtins with their specifications
public let RESOURCE_BUILTINS: [String: ResourceBuiltinSpec] = [
    "texture": ResourceBuiltinSpec(width: 3, argCount: 3),      // texture(path, u, v) -> [r, g, b]
    "camera": ResourceBuiltinSpec(width: 3, argCount: 2),       // camera(u, v) -> [r, g, b]
    "microphone": ResourceBuiltinSpec(width: 2, argCount: 1),   // microphone(offset) -> [l, r]
    "mouse": ResourceBuiltinSpec(width: 3, argCount: 0),        // mouse() -> [x, y, down]
    "load": ResourceBuiltinSpec(width: 3, minArgs: 1, maxArgs: 3),   // load(path) or load(path, u, v)
    "sample": ResourceBuiltinSpec(width: 2, minArgs: 1, maxArgs: 2), // sample(path) or sample(path, offset)
    "text": ResourceBuiltinSpec(width: 1, argCount: 3)          // text(content, x, y) -> alpha
]

/// All builtin names (scalar + resource)
public var ALL_BUILTINS: Set<String> {
    SCALAR_BUILTINS.union(Set(RESOURCE_BUILTINS.keys))
}

// MARK: - Coordinate Strands

/// Built-in `me` strands and their indices
/// Visual: x, y, u, v, w, h, t
/// Audio: i, rate/sampleRate, duration, t
public let ME_STRANDS: [String: Int] = [
    // Visual coordinates
    "x": 0, "y": 1, "u": 2, "v": 3, "w": 4, "h": 5,
    // Time
    "t": 6,
    // Audio coordinates
    "i": 0, "rate": 7, "duration": 8, "sampleRate": 7
]

// MARK: - Builtin Lookup Utilities

/// Check if a name is a scalar builtin
public func isScalarBuiltin(_ name: String) -> Bool {
    SCALAR_BUILTINS.contains(name)
}

/// Check if a name is a resource builtin
public func isResourceBuiltin(_ name: String) -> Bool {
    RESOURCE_BUILTINS[name] != nil
}

/// Check if a name is any builtin (scalar or resource)
public func isBuiltin(_ name: String) -> Bool {
    SCALAR_BUILTINS.contains(name) || RESOURCE_BUILTINS[name] != nil
}

/// Get the output width for a builtin (1 for scalars, spec.width for resources)
public func builtinWidth(_ name: String) -> Int? {
    if SCALAR_BUILTINS.contains(name) {
        return 1
    }
    return RESOURCE_BUILTINS[name]?.width
}
