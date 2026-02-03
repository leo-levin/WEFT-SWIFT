// BackendRegistry.swift - Central registry for all backends

import Foundation

// MARK: - Backend Registry

/// Central registry that aggregates metadata from all registered backends.
/// Provides unified queries for ownership, purity analysis, and backend lookup.
public final class BackendRegistry {
    /// Shared singleton instance
    public static let shared = BackendRegistry()

    /// Registered backend types
    private var backendTypes: [String: any Backend.Type] = [:]

    private init() {
        // Register default backends
        register(MetalBackend.self)
        register(AudioBackend.self)
    }

    // MARK: - Registration

    /// Register a backend type
    public func register<B: Backend>(_ type: B.Type) {
        backendTypes[type.identifier] = type
    }

    /// Get backend type by identifier
    public func backendType(for identifier: String) -> (any Backend.Type)? {
        backendTypes[identifier]
    }

    /// All registered backend identifiers
    public var allIdentifiers: [String] {
        Array(backendTypes.keys)
    }

    // MARK: - Aggregate Queries

    /// Map from owned builtin name to backend identifier
    /// e.g., "camera" -> "visual", "microphone" -> "audio"
    public var allOwnedBuiltins: [String: String] {
        var result: [String: String] = [:]
        for (identifier, type) in backendTypes {
            for builtin in type.ownedBuiltins {
                result[builtin] = identifier
            }
        }
        return result
    }

    /// Set of all external builtins (hardware inputs) across all backends
    public var allExternalBuiltins: Set<String> {
        var result = Set<String>()
        for (_, type) in backendTypes {
            result.formUnion(type.externalBuiltins)
        }
        return result
    }

    /// Set of all stateful builtins across all backends
    public var allStatefulBuiltins: Set<String> {
        var result = Set<String>()
        for (_, type) in backendTypes {
            result.formUnion(type.statefulBuiltins)
        }
        return result
    }

    /// Map from output sink name to backend identifier
    /// e.g., "display" -> "visual", "play" -> "audio"
    public var outputSinks: [String: String] {
        var result: [String: String] = [:]
        for (identifier, type) in backendTypes {
            for binding in type.bindings {
                if case .output(let output) = binding {
                    result[output.bundleName] = identifier
                }
            }
        }
        return result
    }

    /// Map from input builtin name to (backendId, InputBinding)
    /// e.g., "camera" -> ("visual", InputBinding(...))
    public var allInputBindings: [String: (backendId: String, binding: InputBinding)] {
        var result: [String: (backendId: String, binding: InputBinding)] = [:]
        for (identifier, type) in backendTypes {
            for binding in type.bindings {
                if case .input(let input) = binding {
                    result[input.builtinName] = (identifier, input)
                }
            }
        }
        return result
    }

    /// Map from output sink name to (backendId, OutputBinding)
    /// e.g., "display" -> ("visual", OutputBinding(...))
    public var allOutputBindings: [String: (backendId: String, binding: OutputBinding)] {
        var result: [String: (backendId: String, binding: OutputBinding)] = [:]
        for (identifier, type) in backendTypes {
            for binding in type.bindings {
                if case .output(let output) = binding {
                    result[output.bundleName] = (identifier, output)
                }
            }
        }
        return result
    }

    /// Get owned builtins for a specific backend
    public func ownedBuiltins(for identifier: String) -> Set<String> {
        backendTypes[identifier]?.ownedBuiltins ?? []
    }

    /// Get external builtins for a specific backend
    public func externalBuiltins(for identifier: String) -> Set<String> {
        backendTypes[identifier]?.externalBuiltins ?? []
    }

    /// Get the backend identifier that owns a specific builtin
    public func backendOwning(builtin: String) -> String? {
        allOwnedBuiltins[builtin]
    }

    /// Get the backend identifier for an output sink
    public func backendFor(sink: String) -> String? {
        outputSinks[sink]
    }

    // MARK: - Hardware-based Routing

    /// Find the backend that owns the given hardware
    /// Returns nil if no backend claims this hardware
    public func backendOwning(hardware: IRHardware) -> String? {
        for (identifier, type) in backendTypes {
            if type.hardwareOwned.contains(hardware) {
                return identifier
            }
        }
        return nil
    }

    /// Find the backend identifier for a set of hardware requirements
    /// Returns the backend whose hardwareOwned intersects with the given hardware,
    /// or nil if no intersection (pure signal)
    public func backendFor(hardware: Set<IRHardware>) -> String? {
        for (identifier, type) in backendTypes {
            if !type.hardwareOwned.isDisjoint(with: hardware) {
                return identifier
            }
        }
        return nil
    }

    /// Get all registered backend types
    public var allBackendTypes: [String: any Backend.Type] {
        backendTypes
    }
}
