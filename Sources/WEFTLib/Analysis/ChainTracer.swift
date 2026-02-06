// ChainTracer.swift - Auto-trace signal chain for Draft visualization

import Foundation

// MARK: - Draft Layer Spec

/// Describes a layer in the Draft coordinate visualization.
public struct DraftLayerSpec: Identifiable {
    public let id: UUID

    public enum LayerType: Equatable {
        case plane(xStrand: String, yStrand: String) // 2D coordinate pair
        case axis(strand: String)                     // 1D scalar value
    }

    /// Bundle name (or "me" for the input coordinate layer)
    public let bundleName: String

    /// Whether this is a plane (2D) or axis (1D)
    public let type: LayerType

    /// Display label (e.g., "me.x, me.y" or "grid.x, grid.y" or "img.r")
    public let label: String

    /// The strand expressions to evaluate for this layer
    public let strandExprs: [(strandName: String, expr: IRExpr)]

    public init(bundleName: String, type: LayerType, label: String,
                strandExprs: [(strandName: String, expr: IRExpr)]) {
        self.id = UUID()
        self.bundleName = bundleName
        self.type = type
        self.label = label
        self.strandExprs = strandExprs
    }
}

// MARK: - Chain Tracer

/// Traces upstream from a selected bundle to build an ordered list of Draft layers.
public class ChainTracer {
    private let program: IRProgram
    private let graph: DependencyGraph
    private let swatchGraph: SwatchGraph?

    public init(program: IRProgram, graph: DependencyGraph, swatchGraph: SwatchGraph? = nil) {
        self.program = program
        self.graph = graph
        self.swatchGraph = swatchGraph
    }

    /// Trace upstream from the selected bundle, returning layers from input coordinates to the target.
    public func trace(from bundleName: String) -> [DraftLayerSpec] {
        guard program.bundles[bundleName] != nil else { return [] }

        // Get all transitive dependencies
        var relevantBundles = graph.transitiveDependencies(of: bundleName)
        relevantBundles.insert(bundleName)

        // Filter to same swatch if available
        if let swatchGraph = swatchGraph,
           let targetSwatch = swatchGraph.swatch(containing: bundleName) {
            relevantBundles = relevantBundles.filter { name in
                swatchGraph.bundleToSwatch[name] == targetSwatch.id
            }
            // Always include the target
            relevantBundles.insert(bundleName)
        }

        // Remove "me" — we synthesize it as the first layer
        relevantBundles.remove("me")

        // Topologically sort
        guard let fullOrder = graph.topologicalSort() else { return [] }
        let ordered = fullOrder.filter { relevantBundles.contains($0) }

        // Determine domain (visual vs audio) from the target bundle's swatch
        let isVisual = determineIsVisual(bundleName: bundleName)

        // Build layers
        var layers: [DraftLayerSpec] = []

        // Prepend synthetic "me" input layer
        if isVisual {
            layers.append(DraftLayerSpec(
                bundleName: "me",
                type: .plane(xStrand: "me.x", yStrand: "me.y"),
                label: "me.x, me.y",
                strandExprs: [
                    ("x", .index(bundle: "me", indexExpr: .param("x"))),
                    ("y", .index(bundle: "me", indexExpr: .param("y")))
                ]
            ))
        } else {
            layers.append(DraftLayerSpec(
                bundleName: "me",
                type: .axis(strand: "me.i"),
                label: "me.i",
                strandExprs: [
                    ("i", .index(bundle: "me", indexExpr: .param("i")))
                ]
            ))
        }

        // Add each bundle as a layer
        for name in ordered {
            guard let bundle = program.bundles[name] else { continue }
            let bundleLayers = layersForBundle(bundle)
            layers.append(contentsOf: bundleLayers)
        }

        return layers
    }

    /// Get all available bundles that could be added as layers (for the "add layer" dropdown).
    public func availableBundles(forSwatchContaining bundleName: String) -> [String] {
        if let swatchGraph = swatchGraph,
           let targetSwatch = swatchGraph.swatch(containing: bundleName) {
            return targetSwatch.bundles.sorted()
        }
        return program.bundles.keys.sorted()
    }

    // MARK: - Private

    private func determineIsVisual(bundleName: String) -> Bool {
        if let swatchGraph = swatchGraph,
           let swatch = swatchGraph.swatch(containing: bundleName) {
            return swatch.backend == "visual"
        }
        // Fallback: check if bundle references visual coordinates
        if let bundle = program.bundles[bundleName] {
            for strand in bundle.strands {
                let vars = strand.expr.freeVars()
                if vars.contains("me.x") || vars.contains("me.y") {
                    return true
                }
            }
        }
        return true // Default to visual
    }

    private func layersForBundle(_ bundle: IRBundle) -> [DraftLayerSpec] {
        let strands = bundle.strands.sorted(by: { $0.index < $1.index })

        if strands.count == 2 {
            // Natural pair → plane
            return [DraftLayerSpec(
                bundleName: bundle.name,
                type: .plane(
                    xStrand: "\(bundle.name).\(strands[0].name)",
                    yStrand: "\(bundle.name).\(strands[1].name)"
                ),
                label: "\(bundle.name).\(strands[0].name), \(bundle.name).\(strands[1].name)",
                strandExprs: strands.map { ($0.name, $0.expr) }
            )]
        } else if strands.count == 1 {
            // Single strand → axis
            return [DraftLayerSpec(
                bundleName: bundle.name,
                type: .axis(strand: "\(bundle.name).\(strands[0].name)"),
                label: "\(bundle.name).\(strands[0].name)",
                strandExprs: [( strands[0].name, strands[0].expr)]
            )]
        } else if strands.count >= 3 {
            // 3+ strands: first two as plane, rest as axes
            var layers: [DraftLayerSpec] = []
            layers.append(DraftLayerSpec(
                bundleName: bundle.name,
                type: .plane(
                    xStrand: "\(bundle.name).\(strands[0].name)",
                    yStrand: "\(bundle.name).\(strands[1].name)"
                ),
                label: "\(bundle.name).\(strands[0].name), \(bundle.name).\(strands[1].name)",
                strandExprs: [(strands[0].name, strands[0].expr), (strands[1].name, strands[1].expr)]
            ))
            for strand in strands.dropFirst(2) {
                layers.append(DraftLayerSpec(
                    bundleName: bundle.name,
                    type: .axis(strand: "\(bundle.name).\(strand.name)"),
                    label: "\(bundle.name).\(strand.name)",
                    strandExprs: [(strand.name, strand.expr)]
                ))
            }
            return layers
        }
        return []
    }
}
