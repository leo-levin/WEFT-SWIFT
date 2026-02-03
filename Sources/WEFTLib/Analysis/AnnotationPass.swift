// AnnotationPass.swift - Compute domain/hardware/state annotations for IR signals

import Foundation

/// Computes domain, hardware, and state annotations for all signals in an IR program
public class AnnotationPass {
    private let program: IRProgram
    private let coordinateSpecs: [String: IRDimension]
    private let primitiveSpecs: [String: PrimitiveSpec]

    /// Memoized annotation results
    private var annotatedSignals: [String: IRSignal] = [:]

    /// Track which signals are currently being computed (cycle detection)
    private var computing: Set<String> = []

    public init(
        program: IRProgram,
        coordinateSpecs: [String: IRDimension],
        primitiveSpecs: [String: PrimitiveSpec]
    ) {
        self.program = program
        self.coordinateSpecs = coordinateSpecs
        self.primitiveSpecs = primitiveSpecs
    }

    /// Annotate all signals in the program
    public func annotate() -> IRAnnotatedProgram {
        annotatedSignals = [:]

        // Process each bundle's strands
        for (bundleName, bundle) in program.bundles {
            for strand in bundle.strands {
                let key = "\(bundleName).\(strand.name)"
                let (domain, hardware, stateful) = annotateExpr(strand.expr, bundleName: bundleName)
                annotatedSignals[key] = IRSignal(
                    name: key,
                    strandIndex: strand.index,
                    expr: strand.expr,
                    domain: domain,
                    hardware: hardware,
                    stateful: stateful
                )
            }
        }

        return IRAnnotatedProgram(signals: annotatedSignals, original: program)
    }

    /// Annotate a single expression, returning (domain, hardware, stateful)
    private func annotateExpr(_ expr: IRExpr, bundleName: String) -> ([IRDimension], Set<IRHardware>, Bool) {
        switch expr {
        case .num:
            return ([], [], false)

        case .param(let name):
            // Bare param - check if it's a coordinate name
            if let dim = coordinateSpecs[name] {
                return ([dim], [], false)
            }
            return ([], [], false)

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                // Coordinate access: me.x, me.t, etc.
                if case .param(let field) = indexExpr {
                    if let dim = coordinateSpecs[field] {
                        return ([dim], [], false)
                    }
                }
                // Unknown coordinate - return empty
                return ([], [], false)
            }
            // Bundle reference - look up its annotation (or compute recursively)
            return annotateRef(bundle, indexExpr: indexExpr)

        case .binaryOp(_, let left, let right):
            let (lDom, lHw, lState) = annotateExpr(left, bundleName: bundleName)
            let (rDom, rHw, rState) = annotateExpr(right, bundleName: bundleName)
            return (mergeDomains([lDom, rDom]), lHw.union(rHw), lState || rState)

        case .unaryOp(_, let operand):
            return annotateExpr(operand, bundleName: bundleName)

        case .builtin(let name, let args):
            // Check if it's a primitive with special domain behavior
            if let spec = primitiveSpecs[name] {
                let argsAnnotations = args.map { annotateExpr($0, bundleName: bundleName) }
                let argsHardware = argsAnnotations.reduce(into: Set<IRHardware>()) { $0.formUnion($1.1) }
                let argsStateful = argsAnnotations.contains { $0.2 }

                // For primitives, the output domain replaces (not merges with) arg domains
                // unless the primitive has no output domain (like cache)
                let outputDomain: [IRDimension]
                if spec.outputDomain.isEmpty && spec.addsState {
                    // Stateful primitive (cache) - inherit domain from args
                    outputDomain = mergeDomains(argsAnnotations.map { $0.0 })
                } else if !spec.outputDomain.isEmpty {
                    // Primitive defines its output domain
                    outputDomain = spec.outputDomain
                } else {
                    // No domain from primitive, merge args
                    outputDomain = mergeDomains(argsAnnotations.map { $0.0 })
                }

                return (
                    outputDomain,
                    argsHardware.union(spec.hardwareRequired),
                    argsStateful || spec.addsState
                )
            }

            // Regular builtin (sin, cos, etc.) - merge args
            let argsAnnotations = args.map { annotateExpr($0, bundleName: bundleName) }
            return (
                mergeDomains(argsAnnotations.map { $0.0 }),
                argsAnnotations.reduce(into: Set<IRHardware>()) { $0.formUnion($1.1) },
                argsAnnotations.contains { $0.2 }
            )

        case .call(_, let args):
            // Spindle call - for now just merge args (spindle body is inlined)
            let argsAnnotations = args.map { annotateExpr($0, bundleName: bundleName) }
            return (
                mergeDomains(argsAnnotations.map { $0.0 }),
                argsAnnotations.reduce(into: Set<IRHardware>()) { $0.formUnion($1.1) },
                argsAnnotations.contains { $0.2 }
            )

        case .extract(let call, _):
            return annotateExpr(call, bundleName: bundleName)

        case .remap(let base, let substitutions):
            let (baseDom, baseHw, baseState) = annotateExpr(base, bundleName: bundleName)
            var resultDom = baseDom
            var resultHw = baseHw
            var resultState = baseState

            for (key, replacement) in substitutions {
                // Remove the remapped dimension
                let dimName = key.hasPrefix("me.") ? String(key.dropFirst(3)) : key
                resultDom = resultDom.filter { $0.name != dimName }

                // Add replacement's domain
                let (replDom, replHw, replState) = annotateExpr(replacement, bundleName: bundleName)
                resultDom = mergeDomains([resultDom, replDom])
                resultHw = resultHw.union(replHw)
                resultState = resultState || replState
            }
            return (resultDom, resultHw, resultState)

        case .cacheRead:
            // Reading from cache is stateful, domain depends on context
            return ([], [], true)
        }
    }

    /// Annotate a bundle reference
    private func annotateRef(_ bundle: String, indexExpr: IRExpr) -> ([IRDimension], Set<IRHardware>, Bool) {
        // Get strand name/index
        let strandKey: String
        if case .param(let field) = indexExpr {
            strandKey = "\(bundle).\(field)"
        } else if case .num(let idx) = indexExpr {
            strandKey = "\(bundle).\(Int(idx))"
        } else {
            // Dynamic index - need to annotate the index expression too
            // For now, return empty
            return ([], [], false)
        }

        // Check if already annotated
        if let existing = annotatedSignals[strandKey] {
            return (existing.domain, existing.hardware, existing.stateful)
        }

        // Cycle detection
        if computing.contains(strandKey) {
            // We're in a cycle - return stateful with empty domain
            return ([], [], true)
        }

        // Look up the bundle and annotate it
        guard let targetBundle = program.bundles[bundle] else {
            return ([], [], false)
        }

        // Find the strand
        let strand: IRStrand?
        if case .param(let field) = indexExpr {
            strand = targetBundle.strands.first { $0.name == field }
        } else if case .num(let idx) = indexExpr {
            strand = targetBundle.strands.first { $0.index == Int(idx) }
        } else {
            strand = nil
        }

        guard let s = strand else {
            return ([], [], false)
        }

        // Mark as computing and recursively annotate
        computing.insert(strandKey)
        let result = annotateExpr(s.expr, bundleName: bundle)
        computing.remove(strandKey)

        // Cache the result
        annotatedSignals[strandKey] = IRSignal(
            name: strandKey,
            strandIndex: s.index,
            expr: s.expr,
            domain: result.0,
            hardware: result.1,
            stateful: result.2
        )

        return result
    }

    /// Merge multiple domain lists, combining dimensions with same name
    private func mergeDomains(_ domains: [[IRDimension]]) -> [IRDimension] {
        var result: [String: IRAccess] = [:]

        for domain in domains {
            for dim in domain {
                if let existing = result[dim.name] {
                    // bound wins (more restrictive)
                    result[dim.name] = (existing == .bound || dim.access == .bound) ? .bound : .free
                } else {
                    result[dim.name] = dim.access
                }
            }
        }

        return result.map { IRDimension(name: $0.key, access: $0.value) }
            .sorted { $0.name < $1.name }
    }
}
