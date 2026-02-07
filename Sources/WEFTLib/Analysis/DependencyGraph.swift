// DependencyGraph.swift - Build and analyze dependency graph from IR

import Foundation

// MARK: - Graph Node

public struct GraphNode: Hashable {
    public let bundleName: String

    public init(_ bundleName: String) {
        self.bundleName = bundleName
    }
}

// MARK: - Dependency Graph

public class DependencyGraph {
    /// Map from bundle name to its dependencies (other bundle names)
    public private(set) var dependencies: [String: Set<String>] = [:]

    /// Map from bundle name to bundles that depend on it
    public private(set) var dependents: [String: Set<String>] = [:]

    /// All bundle names in the graph
    public var nodes: Set<String> {
        Set(dependencies.keys)
    }

    public init() {}

    /// Build dependency graph from IR program
    public func build(from program: IRProgram) {
        dependencies = [:]
        dependents = [:]

        // Initialize all bundles
        for bundleName in program.bundles.keys {
            dependencies[bundleName] = []
            dependents[bundleName] = []
        }

        // Analyze each bundle's dependencies
        for (bundleName, bundle) in program.bundles {
            var bundleDeps = Set<String>()

            for strand in bundle.strands {
                bundleDeps.formUnion(strand.expr.collectBundleReferences(excludeMe: true))
            }

            // Remove self-reference (handled separately for stateful analysis)
            bundleDeps.remove(bundleName)

            dependencies[bundleName] = bundleDeps

            // Update reverse mapping
            for dep in bundleDeps {
                dependents[dep, default: []].insert(bundleName)
            }
        }
    }

    /// Get topologically sorted order of bundles
    public func topologicalSort() -> [String]? {
        var result: [String] = []
        var visited = Set<String>()
        var visiting = Set<String>()

        func visit(_ node: String) -> Bool {
            if visited.contains(node) {
                return true
            }
            if visiting.contains(node) {
                // Cycle detected
                return false
            }

            visiting.insert(node)

            for dep in dependencies[node] ?? [] {
                if !visit(dep) {
                    return false
                }
            }

            visiting.remove(node)
            visited.insert(node)
            result.append(node)
            return true
        }

        for node in dependencies.keys.sorted() {
            if !visit(node) {
                return nil // Cycle detected
            }
        }

        return result
    }

    /// Check if graph has cycles (excluding self-references which are allowed)
    public func hasCycles() -> Bool {
        return topologicalSort() == nil
    }

    /// Get all transitive dependencies of a bundle
    public func transitiveDependencies(of bundleName: String) -> Set<String> {
        var result = Set<String>()
        var queue = Array(dependencies[bundleName] ?? [])

        while !queue.isEmpty {
            let dep = queue.removeFirst()
            if !result.contains(dep) {
                result.insert(dep)
                queue.append(contentsOf: dependencies[dep] ?? [])
            }
        }

        return result
    }
}
