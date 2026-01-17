// Swatch.swift - Compilation unit per backend

import Foundation

// MARK: - Swatch

/// A Swatch is a connected subgraph of same-backend nodes.
/// It's the unit of compilation for a backend.
public struct Swatch: Identifiable, Hashable {
    public let id: UUID
    public let backend: BackendDomain
    public let bundles: Set<String>

    /// Cross-domain input buffers needed
    public var inputBuffers: Set<String>

    /// Output buffers produced (for cross-domain access)
    public var outputBuffers: Set<String>

    /// Whether this swatch contains an output sink (display/play)
    public var isSink: Bool

    public init(
        backend: BackendDomain,
        bundles: Set<String>,
        inputBuffers: Set<String> = [],
        outputBuffers: Set<String> = [],
        isSink: Bool = false
    ) {
        self.id = UUID()
        self.backend = backend
        self.bundles = bundles
        self.inputBuffers = inputBuffers
        self.outputBuffers = outputBuffers
        self.isSink = isSink
    }

    public static func == (lhs: Swatch, rhs: Swatch) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Swatch Description

extension Swatch: CustomStringConvertible {
    public var description: String {
        var parts = ["Swatch(\(backend.rawValue))"]
        parts.append("bundles: {\(bundles.sorted().joined(separator: ", "))}")
        if !inputBuffers.isEmpty {
            parts.append("inputs: {\(inputBuffers.sorted().joined(separator: ", "))}")
        }
        if !outputBuffers.isEmpty {
            parts.append("outputs: {\(outputBuffers.sorted().joined(separator: ", "))}")
        }
        if isSink {
            parts.append("[SINK]")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Swatch Graph

/// Directed acyclic graph of Swatches
public struct SwatchGraph {
    public var swatches: [Swatch]

    /// Edges: swatch ID -> set of swatch IDs it depends on
    public var dependencies: [UUID: Set<UUID>]

    /// Map from bundle name to swatch that contains it
    public var bundleToSwatch: [String: UUID]

    public init() {
        self.swatches = []
        self.dependencies = [:]
        self.bundleToSwatch = [:]
    }

    /// Get swatch by ID
    public func swatch(withId id: UUID) -> Swatch? {
        swatches.first { $0.id == id }
    }

    /// Get swatch containing a bundle
    public func swatch(containing bundleName: String) -> Swatch? {
        guard let id = bundleToSwatch[bundleName] else { return nil }
        return swatch(withId: id)
    }

    /// Topological sort of swatches
    public func topologicalSort() -> [Swatch]? {
        var result: [Swatch] = []
        var visited = Set<UUID>()
        var visiting = Set<UUID>()

        func visit(_ id: UUID) -> Bool {
            if visited.contains(id) { return true }
            if visiting.contains(id) { return false }

            visiting.insert(id)

            for dep in dependencies[id] ?? [] {
                if !visit(dep) { return false }
            }

            visiting.remove(id)
            visited.insert(id)
            if let swatch = swatch(withId: id) {
                result.append(swatch)
            }
            return true
        }

        for swatch in swatches {
            if !visit(swatch.id) { return nil }
        }

        return result
    }
}
