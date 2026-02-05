// Partitioner.swift - Partition IR graph into Swatches

import Foundation

// MARK: - Partitioner

public class Partitioner {
    private let program: IRProgram
    private let graph: DependencyGraph
    private let annotations: IRAnnotatedProgram
    private let registry: BackendRegistry

    public init(
        program: IRProgram,
        graph: DependencyGraph,
        annotations: IRAnnotatedProgram,
        registry: BackendRegistry = .shared
    ) {
        self.program = program
        self.graph = graph
        self.annotations = annotations
        self.registry = registry
    }

    /// Get output bundle name for a backend from registry
    private func outputBundleName(for backendId: String) -> String? {
        registry.allOutputBindings.first { $0.value.backendId == backendId }?.key
    }

    /// Check if a bundle is a sink for a backend
    private func isSinkBundle(_ bundleName: String, for backendId: String) -> Bool {
        guard let binding = registry.allOutputBindings[bundleName] else { return false }
        return binding.backendId == backendId
    }

    /// Check if program has a sink bundle for a backend
    private func hasSinkFor(backendId: String) -> Bool {
        for (bundleName, binding) in registry.allOutputBindings {
            if binding.backendId == backendId && program.bundles[bundleName] != nil {
                return true
            }
        }
        return false
    }

    /// Partition the IR into Swatches
    ///
    /// Routing algorithm:
    /// 1. For each bundle, get its hardware requirements from annotations
    /// 2. Find the backend whose hardwareOwned intersects with the hardware
    /// 3. If no intersection (pure), the bundle can be duplicated to any backend that needs it
    public func partition() -> SwatchGraph {
        var swatchGraph = SwatchGraph()

        // Group bundles by backend based on hardware requirements
        var bundlesByBackend: [String: Set<String>] = [:]
        var pureBundles = Set<String>()

        for (bundleName, _) in program.bundles {
            let hardware = annotations.bundleHardware(bundleName)

            if let backendId = registry.backendFor(hardware: hardware) {
                // Bundle requires hardware owned by this backend
                bundlesByBackend[backendId, default: []].insert(bundleName)
            } else {
                // Pure bundle - no hardware requirements
                pureBundles.insert(bundleName)
            }
        }

        // Create a swatch for each backend that has bundles or a sink
        for (backendId, backendType) in registry.allBackendTypes {
            let outputBundle = outputBundleName(for: backendId)
            var backendBundles = bundlesByBackend[backendId] ?? []

            // Check if this backend has a sink in the program
            let hasSink = hasSinkFor(backendId: backendId)

            // Skip if no bundles and no sink
            if backendBundles.isEmpty && !hasSink {
                continue
            }

            // Add pure bundles that this backend's bundles depend on
            for bundle in backendBundles {
                let deps = graph.transitiveDependencies(of: bundle)
                for dep in deps {
                    if pureBundles.contains(dep) {
                        backendBundles.insert(dep)
                    }
                }
            }

            // Include output bundle if present in program
            if let outputBundle = outputBundle, program.bundles[outputBundle] != nil {
                backendBundles.insert(outputBundle)

                // Also add pure dependencies of the output bundle
                let deps = graph.transitiveDependencies(of: outputBundle)
                for dep in deps {
                    if pureBundles.contains(dep) {
                        backendBundles.insert(dep)
                    }
                }
            }

            let swatch = Swatch(
                backend: backendId,
                bundles: backendBundles,
                isSink: outputBundle.map { isSinkBundle($0, for: backendId) } ?? false
            )
            swatchGraph.swatches.append(swatch)

            for bundle in backendBundles {
                swatchGraph.bundleToSwatch[bundle] = swatch.id
            }
        }

        // Compute cross-domain dependencies
        computeCrossDomainBuffers(&swatchGraph)

        return swatchGraph
    }

    /// Compute input/output buffers for cross-domain access
    private func computeCrossDomainBuffers(_ swatchGraph: inout SwatchGraph) {
        for i in 0..<swatchGraph.swatches.count {
            var swatch = swatchGraph.swatches[i]
            var inputs = Set<String>()
            var outputs = Set<String>()

            for bundleName in swatch.bundles {
                guard let bundle = program.bundles[bundleName] else { continue }

                // Check dependencies for cross-domain
                for strand in bundle.strands {
                    let refs = strand.expr.collectBundleReferences(excludeMe: true)

                    for ref in refs {
                        // Check if referenced bundle is in a different swatch
                        if let refSwatchId = swatchGraph.bundleToSwatch[ref],
                           refSwatchId != swatch.id {
                            // Cross-domain dependency
                            inputs.insert(ref)

                            // Also mark the other swatch's output
                            if let refIndex = swatchGraph.swatches.firstIndex(where: { $0.id == refSwatchId }) {
                                swatchGraph.swatches[refIndex].outputBuffers.insert(ref)
                            }
                        }
                    }
                }
            }

            swatch.inputBuffers = inputs
            swatchGraph.swatches[i] = swatch

            // Build dependency edges
            for input in inputs {
                if let depSwatchId = swatchGraph.bundleToSwatch[input] {
                    swatchGraph.dependencies[swatch.id, default: []].insert(depSwatchId)
                }
            }
        }
    }

}
