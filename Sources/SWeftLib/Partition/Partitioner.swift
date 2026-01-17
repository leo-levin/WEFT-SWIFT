// Partitioner.swift - Partition IR graph into Swatches

import Foundation

// MARK: - Partitioner

public class Partitioner {
    private let program: IRProgram
    private let ownership: OwnershipAnalysis
    private let purity: PurityAnalysis
    private let graph: DependencyGraph

    public init(
        program: IRProgram,
        ownership: OwnershipAnalysis,
        purity: PurityAnalysis,
        graph: DependencyGraph
    ) {
        self.program = program
        self.ownership = ownership
        self.purity = purity
        self.graph = graph
    }

    /// Partition the IR into Swatches
    public func partition() -> SwatchGraph {
        var swatchGraph = SwatchGraph()

        // Group bundles by backend (pure nodes can duplicate, so we handle them specially)
        var visualBundles = Set<String>()
        var audioBundles = Set<String>()
        var pureBundles = Set<String>()

        for (bundleName, _) in program.bundles {
            let domain = ownership.ownership[bundleName] ?? .none
            let isPure = purity.isPure(bundleName)

            switch domain {
            case .visual:
                visualBundles.insert(bundleName)
            case .audio:
                audioBundles.insert(bundleName)
            case .none:
                if isPure {
                    pureBundles.insert(bundleName)
                }
                // Pure bundles with .none domain will be duplicated as needed
            }
        }

        // For simplicity, create one swatch per backend (can be refined later for interleaving)
        // Pure bundles are duplicated into each backend that needs them

        // Visual swatch
        if !visualBundles.isEmpty || ownership.sinks.values.contains(.display) {
            var allVisualBundles = visualBundles

            // Add pure bundles that visual depends on
            for bundle in visualBundles {
                let deps = graph.transitiveDependencies(of: bundle)
                for dep in deps {
                    if pureBundles.contains(dep) {
                        allVisualBundles.insert(dep)
                    }
                }
            }

            // Also include display if present
            if program.bundles["display"] != nil {
                allVisualBundles.insert("display")
            }

            let visualSwatch = Swatch(
                backend: .visual,
                bundles: allVisualBundles,
                isSink: ownership.sinks["display"] != nil
            )
            swatchGraph.swatches.append(visualSwatch)

            for bundle in allVisualBundles {
                swatchGraph.bundleToSwatch[bundle] = visualSwatch.id
            }
        }

        // Audio swatch
        if !audioBundles.isEmpty || ownership.sinks.values.contains(.play) {
            var allAudioBundles = audioBundles

            // Add pure bundles that audio depends on
            for bundle in audioBundles {
                let deps = graph.transitiveDependencies(of: bundle)
                for dep in deps {
                    if pureBundles.contains(dep) {
                        allAudioBundles.insert(dep)
                    }
                }
            }

            // Also include play if present
            if program.bundles["play"] != nil {
                allAudioBundles.insert("play")
            }

            let audioSwatch = Swatch(
                backend: .audio,
                bundles: allAudioBundles,
                isSink: ownership.sinks["play"] != nil
            )
            swatchGraph.swatches.append(audioSwatch)

            for bundle in allAudioBundles {
                swatchGraph.bundleToSwatch[bundle] = audioSwatch.id
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
                    let refs = collectBundleReferences(expr: strand.expr)

                    for ref in refs {
                        if ref == "me" { continue }

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

    /// Collect bundle references from expression
    private func collectBundleReferences(expr: IRExpr) -> Set<String> {
        switch expr {
        case .num, .param:
            return []

        case .index(let bundle, let indexExpr):
            var refs = collectBundleReferences(expr: indexExpr)
            refs.insert(bundle)
            return refs

        case .binaryOp(_, let left, let right):
            return collectBundleReferences(expr: left)
                .union(collectBundleReferences(expr: right))

        case .unaryOp(_, let operand):
            return collectBundleReferences(expr: operand)

        case .call(_, let args):
            return args.reduce(into: Set<String>()) {
                $0.formUnion(collectBundleReferences(expr: $1))
            }

        case .builtin(_, let args):
            return args.reduce(into: Set<String>()) {
                $0.formUnion(collectBundleReferences(expr: $1))
            }

        case .extract(let call, _):
            return collectBundleReferences(expr: call)

        case .remap(let base, let substitutions):
            var refs = collectBundleReferences(expr: base)
            for (_, subExpr) in substitutions {
                refs.formUnion(collectBundleReferences(expr: subExpr))
            }
            return refs

        case .texture(_, let u, let v, _):
            return collectBundleReferences(expr: u)
                .union(collectBundleReferences(expr: v))

        case .camera(let u, let v, _):
            return collectBundleReferences(expr: u)
                .union(collectBundleReferences(expr: v))

        case .microphone(let offset, _):
            return collectBundleReferences(expr: offset)
        }
    }
}
