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
                let refs = collectBundleReferences(expr: strand.expr, program: program)
                bundleDeps.formUnion(refs)
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

    /// Collect all bundle references from an expression
    private func collectBundleReferences(expr: IRExpr, program: IRProgram) -> Set<String> {
        switch expr {
        case .num, .param:
            return []

        case .index(let bundle, let indexExpr):
            var refs = collectBundleReferences(expr: indexExpr, program: program)
            // Only add if it's a real bundle (not "me" which is special)
            if bundle != "me" {
                refs.insert(bundle)
            }
            return refs

        case .binaryOp(_, let left, let right):
            return collectBundleReferences(expr: left, program: program)
                .union(collectBundleReferences(expr: right, program: program))

        case .unaryOp(_, let operand):
            return collectBundleReferences(expr: operand, program: program)

        case .call(_, let args):
            return args.reduce(into: Set<String>()) {
                $0.formUnion(collectBundleReferences(expr: $1, program: program))
            }

        case .builtin(_, let args):
            return args.reduce(into: Set<String>()) {
                $0.formUnion(collectBundleReferences(expr: $1, program: program))
            }

        case .extract(let call, _):
            return collectBundleReferences(expr: call, program: program)

        case .remap(let base, let substitutions):
            var refs = collectBundleReferences(expr: base, program: program)
            for (_, subExpr) in substitutions {
                refs.formUnion(collectBundleReferences(expr: subExpr, program: program))
            }
            return refs

        case .texture(_, let u, let v, _):
            return collectBundleReferences(expr: u, program: program)
                .union(collectBundleReferences(expr: v, program: program))

        case .camera(let u, let v, _):
            return collectBundleReferences(expr: u, program: program)
                .union(collectBundleReferences(expr: v, program: program))

        case .microphone(let offset, _):
            return collectBundleReferences(expr: offset, program: program)
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
