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
            if let sinkName = type.outputSinkName {
                result[sinkName] = identifier
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
}
