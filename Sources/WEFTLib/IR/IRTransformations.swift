// IRTransformations.swift - Shared IR transformation utilities

import Foundation

/// Shared utilities for IR expression transformations.
/// Used by both Metal and Audio code generators.
public enum IRTransformations {

    // MARK: - Parameter Substitution

    /// Substitute parameter references with actual argument expressions.
    /// Used when inlining spindle calls.
    public static func substituteParams(
        in expr: IRExpr,
        substitutions: [String: IRExpr]
    ) -> IRExpr {
        switch expr {
        case .param(let name):
            return substitutions[name] ?? expr
        case .index(let bundle, let indexExpr):
            if let subst = substitutions[bundle],
               case .index(let newBundle, _) = subst {
                return .index(
                    bundle: newBundle,
                    indexExpr: substituteParams(in: indexExpr, substitutions: substitutions)
                )
            }
            return .index(
                bundle: bundle,
                indexExpr: substituteParams(in: indexExpr, substitutions: substitutions)
            )
        default:
            return expr.mapChildren { substituteParams(in: $0, substitutions: substitutions) }
        }
    }

    // MARK: - Spindle Substitution Builder

    /// Build complete substitution map for inlining a spindle call.
    /// Includes both parameter substitutions and local bundle resolutions.
    public static func buildSpindleSubstitutions(
        spindleDef: IRSpindle,
        args: [IRExpr]
    ) -> [String: IRExpr] {
        var substitutions: [String: IRExpr] = [:]
        for (i, param) in spindleDef.params.enumerated() {
            if i < args.count {
                substitutions[param] = args[i]
            }
        }

        for local in spindleDef.locals {
            for strand in local.strands {
                let localExpr = substituteParams(in: strand.expr, substitutions: substitutions)
                let fullyInlined = substituteIndexRefs(in: localExpr, substitutions: substitutions)
                substitutions["\(local.name).\(strand.index)"] = fullyInlined
                substitutions["\(local.name).\(strand.name)"] = fullyInlined
            }
        }

        return substitutions
    }

    // MARK: - Index Reference Substitution

    /// Substitute .index expressions where the bundle.strand key exists in substitutions.
    public static func substituteIndexRefs(
        in expr: IRExpr,
        substitutions: [String: IRExpr]
    ) -> IRExpr {
        switch expr {
        case .index(let bundle, let indexExpr):
            if case .param(let field) = indexExpr,
               let replacement = substitutions["\(bundle).\(field)"] {
                return replacement
            }
            if case .num(let idx) = indexExpr,
               let replacement = substitutions["\(bundle).\(Int(idx))"] {
                return replacement
            }
            return .index(
                bundle: bundle,
                indexExpr: substituteIndexRefs(in: indexExpr, substitutions: substitutions)
            )
        default:
            return expr.mapChildren { substituteIndexRefs(in: $0, substitutions: substitutions) }
        }
    }

    // MARK: - Direct Expression

    /// Get the direct expression for a bundle reference WITHOUT recursively inlining dependencies.
    public static func getDirectExpression(
        _ expr: IRExpr,
        program: IRProgram
    ) -> IRExpr {
        switch expr {
        case .index(let bundle, let indexExpr):
            if bundle == "me" { return expr }
            if let targetBundle = program.bundles[bundle] {
                if case .num(let idx) = indexExpr {
                    let strandIdx = Int(idx)
                    if strandIdx < targetBundle.strands.count {
                        return targetBundle.strands[strandIdx].expr
                    }
                } else if case .param(let field) = indexExpr {
                    if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                        return strand.expr
                    }
                }
            }
            return expr

        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr,
                  let spindleDef = program.spindles[spindle],
                  index < spindleDef.returns.count else { return expr }
            let subs = buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var result = substituteParams(in: spindleDef.returns[index], substitutions: subs)
            result = substituteIndexRefs(in: result, substitutions: subs)
            return result

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle],
                  !spindleDef.returns.isEmpty else { return expr }
            let subs = buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var result = substituteParams(in: spindleDef.returns[0], substitutions: subs)
            result = substituteIndexRefs(in: result, substitutions: subs)
            return result

        default:
            return expr
        }
    }

    // MARK: - Expression Inlining

    /// Inline bundle references to their actual expressions (at IR level, no code generation).
    public static func inlineExpression(
        _ expr: IRExpr,
        program: IRProgram
    ) throws -> IRExpr {
        switch expr {
        case .num, .param, .cacheRead:
            return expr

        case .index(let bundle, let indexExpr):
            if bundle == "me" { return expr }
            if let targetBundle = program.bundles[bundle] {
                if case .num(let idx) = indexExpr {
                    let strandIdx = Int(idx)
                    if strandIdx < targetBundle.strands.count {
                        return try inlineExpression(targetBundle.strands[strandIdx].expr, program: program)
                    }
                } else if case .param(let field) = indexExpr {
                    if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                        return try inlineExpression(strand.expr, program: program)
                    }
                }
            }
            return expr

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle],
                  !spindleDef.returns.isEmpty else { return expr }
            let inlinedArgs = try args.map { try inlineExpression($0, program: program) }
            let subs = buildSpindleSubstitutions(spindleDef: spindleDef, args: inlinedArgs)
            var result = substituteParams(in: spindleDef.returns[0], substitutions: subs)
            result = substituteIndexRefs(in: result, substitutions: subs)
            return try inlineExpression(result, program: program)

        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr,
                  let spindleDef = program.spindles[spindle],
                  index < spindleDef.returns.count else { return expr }
            let inlinedArgs = try args.map { try inlineExpression($0, program: program) }
            let subs = buildSpindleSubstitutions(spindleDef: spindleDef, args: inlinedArgs)
            var result = substituteParams(in: spindleDef.returns[index], substitutions: subs)
            result = substituteIndexRefs(in: result, substitutions: subs)
            return try inlineExpression(result, program: program)

        case .remap(let base, let substitutions):
            let inlinedBase = try inlineExpression(base, program: program)
            var inlinedSubs: [String: IRExpr] = [:]
            for (key, value) in substitutions {
                inlinedSubs[key] = try inlineExpression(value, program: program)
            }
            return applyRemap(to: inlinedBase, substitutions: inlinedSubs)

        default:
            return try expr.mapChildren { try inlineExpression($0, program: program) }
        }
    }

    // MARK: - Remap Application

    /// Apply remap substitutions to an expression (coordinate remapping).
    /// Substitution keys are in "bundle.field" format (e.g., "me.x", "me.y").
    public static func applyRemap(
        to expr: IRExpr,
        substitutions: [String: IRExpr]
    ) -> IRExpr {
        switch expr {
        case .param(let name):
            return substitutions[name] ?? substitutions["me.\(name)"] ?? expr

        case .index(let bundle, let indexExpr):
            var keysToTry: [String] = []
            if case .param(let field) = indexExpr {
                keysToTry.append("\(bundle).\(field)")
                if bundle == "me" {
                    let visualIndices = ["x": 0, "y": 1, "u": 2, "v": 3, "w": 4, "h": 5, "t": 6]
                    let audioIndices = ["i": 0, "sampleRate": 2]
                    if let idx = visualIndices[field] { keysToTry.append("\(bundle).\(idx)") }
                    if let idx = audioIndices[field] { keysToTry.append("\(bundle).\(idx)") }
                }
            } else if case .num(let idx) = indexExpr {
                keysToTry.append("\(bundle).\(Int(idx))")
            }
            for key in keysToTry {
                if let remapped = substitutions[key] { return remapped }
            }
            return .index(bundle: bundle, indexExpr: applyRemap(to: indexExpr, substitutions: substitutions))

        default:
            return expr.mapChildren { applyRemap(to: $0, substitutions: substitutions) }
        }
    }

    // MARK: - Spindle Cache Inlining

    /// Describes a cache in a spindle that has a cyclic dependency
    public struct SpindleCyclicCache {
        public let cacheLocalName: String
        public let cacheStrandName: String
        public let cyclicLocalName: String
        public let cyclicStrandIndex: Int
    }

    /// Collect all local bundle names referenced by an expression
    public static func collectLocalReferences(
        _ expr: IRExpr,
        localNames: Set<String>
    ) -> Set<String> {
        var result = Set<String>()
        func visit(_ e: IRExpr) {
            if case .index(let bundle, _) = e, localNames.contains(bundle) {
                result.insert(bundle)
            }
            e.forEachChild(visit)
        }
        visit(expr)
        return result
    }

    /// Get transitive dependencies of a local (what other locals it depends on, recursively)
    public static func transitiveLocalDeps(
        _ localName: String,
        locals: [IRBundle],
        visited: Set<String> = []
    ) -> Set<String> {
        guard !visited.contains(localName) else { return [] }
        let localNames = Set(locals.map { $0.name })
        guard let local = locals.first(where: { $0.name == localName }) else { return [] }

        var newVisited = visited
        newVisited.insert(localName)

        var result = Set<String>()
        for strand in local.strands {
            let directDeps = collectLocalReferences(strand.expr, localNames: localNames)
            result.formUnion(directDeps)
            for dep in directDeps {
                result.formUnion(transitiveLocalDeps(dep, locals: locals, visited: newVisited))
            }
        }
        return result
    }

    /// Find all local.strand references in an expression
    private static func findLocalStrandRefs(
        _ expr: IRExpr,
        localNames: Set<String>
    ) -> [(localName: String, strandIndex: Int)] {
        var refs: [(String, Int)] = []
        func visit(_ e: IRExpr) {
            if case .index(let bundle, let indexExpr) = e, localNames.contains(bundle) {
                if case .num(let idx) = indexExpr {
                    refs.append((bundle, Int(idx)))
                } else {
                    refs.append((bundle, 0))
                }
            }
            e.forEachChild(visit)
        }
        visit(expr)
        return refs
    }

    /// Find all cache builtin calls and extract their value expression local refs
    public static func findCachesWithLocalRefs(
        _ expr: IRExpr,
        localNames: Set<String>
    ) -> [(valueLocalName: String, valueStrandIndex: Int)] {
        var results: [(String, Int)] = []
        func visit(_ e: IRExpr) {
            if case .builtin(let name, let args) = e, name == "cache", args.count >= 1 {
                results.append(contentsOf: findLocalStrandRefs(args[0], localNames: localNames))
            }
            e.forEachChild(visit)
        }
        visit(expr)
        return results
    }

    /// Find caches in spindle that have cyclic dependencies through their value expression
    public static func findCyclicCachesInSpindle(
        _ spindleDef: IRSpindle
    ) -> [SpindleCyclicCache] {
        var cycles: [SpindleCyclicCache] = []
        let localNames = Set(spindleDef.locals.map { $0.name })

        for returnExpr in spindleDef.returns {
            let returnLocalRefs = collectLocalReferences(returnExpr, localNames: localNames)
            var allReturnDeps = returnLocalRefs
            for localName in returnLocalRefs {
                allReturnDeps.formUnion(transitiveLocalDeps(localName, locals: spindleDef.locals))
            }

            for localName in allReturnDeps {
                guard let local = spindleDef.locals.first(where: { $0.name == localName }) else { continue }
                for strand in local.strands {
                    let cacheRefs = findCachesWithLocalRefs(strand.expr, localNames: localNames)
                    for (refLocalName, refStrandIdx) in cacheRefs {
                        guard allReturnDeps.contains(refLocalName) else { continue }
                        let refDeps = transitiveLocalDeps(refLocalName, locals: spindleDef.locals)
                        if refDeps.contains(localName) || refLocalName == localName {
                            cycles.append(SpindleCyclicCache(
                                cacheLocalName: localName,
                                cacheStrandName: strand.name,
                                cyclicLocalName: refLocalName,
                                cyclicStrandIndex: refStrandIdx
                            ))
                        }
                    }
                }
            }
        }
        return cycles
    }

    /// Substitute references to a specific local.strand with replacement expression
    public static func substituteCyclicRef(
        in expr: IRExpr,
        localName: String,
        strandIndex: Int,
        replacement: IRExpr
    ) -> IRExpr {
        switch expr {
        case .index(let bundle, let indexExpr) where bundle == localName:
            if case .num(let idx) = indexExpr, Int(idx) == strandIndex { return replacement }
            if case .param(let field) = indexExpr, Int(field) == strandIndex { return replacement }
            return .index(
                bundle: bundle,
                indexExpr: substituteCyclicRef(in: indexExpr, localName: localName, strandIndex: strandIndex, replacement: replacement)
            )
        default:
            return expr.mapChildren {
                substituteCyclicRef(in: $0, localName: localName, strandIndex: strandIndex, replacement: replacement)
            }
        }
    }

    /// Inline a spindle call, substituting cyclic cache refs with the assignment target
    public static func inlineSpindleCallWithTarget(
        spindleDef: IRSpindle,
        args: [IRExpr],
        targetBundle: String,
        targetStrandIndex: Int,
        returnIndex: Int = 0
    ) -> IRExpr {
        let cycles = findCyclicCachesInSpindle(spindleDef)

        guard !cycles.isEmpty else {
            let subs = buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            guard returnIndex < spindleDef.returns.count else { return .num(0) }
            var result = substituteParams(in: spindleDef.returns[returnIndex], substitutions: subs)
            result = substituteIndexRefs(in: result, substitutions: subs)
            return result
        }

        let targetRef = IRExpr.index(bundle: targetBundle, indexExpr: .num(Double(targetStrandIndex)))

        var modifiedLocals: [IRBundle] = []
        for local in spindleDef.locals {
            var modifiedStrands: [IRStrand] = []
            for strand in local.strands {
                let relevantCycles = cycles.filter {
                    $0.cacheLocalName == local.name && $0.cacheStrandName == strand.name
                }
                if !relevantCycles.isEmpty {
                    var modifiedExpr = strand.expr
                    for cycle in relevantCycles {
                        modifiedExpr = substituteCyclicRef(
                            in: modifiedExpr, localName: cycle.cyclicLocalName,
                            strandIndex: cycle.cyclicStrandIndex, replacement: targetRef
                        )
                    }
                    modifiedStrands.append(IRStrand(name: strand.name, index: strand.index, expr: modifiedExpr))
                } else {
                    modifiedStrands.append(strand)
                }
            }
            modifiedLocals.append(IRBundle(name: local.name, strands: modifiedStrands))
        }

        let modifiedSpindle = IRSpindle(
            name: spindleDef.name, params: spindleDef.params,
            locals: modifiedLocals, returns: spindleDef.returns
        )
        let subs = buildSpindleSubstitutions(spindleDef: modifiedSpindle, args: args)
        guard returnIndex < spindleDef.returns.count else { return .num(0) }
        var result = substituteParams(in: spindleDef.returns[returnIndex], substitutions: subs)
        result = substituteIndexRefs(in: result, substitutions: subs)
        return result
    }

    /// Recursively inline spindle calls in expression with given target
    private static func inlineExprWithTarget(
        expr: IRExpr,
        targetBundle: String,
        targetStrandIndex: Int,
        program: IRProgram
    ) -> IRExpr {
        let recurse = { (e: IRExpr) -> IRExpr in
            inlineExprWithTarget(expr: e, targetBundle: targetBundle,
                                 targetStrandIndex: targetStrandIndex, program: program)
        }

        switch expr {
        case .call(let spindle, let args):
            let inlinedArgs = args.map(recurse)
            guard let spindleDef = program.spindles[spindle],
                  !spindleDef.returns.isEmpty else {
                return .call(spindle: spindle, args: inlinedArgs)
            }
            let inlined = inlineSpindleCallWithTarget(
                spindleDef: spindleDef, args: inlinedArgs,
                targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, returnIndex: 0
            )
            return recurse(inlined)

        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr,
                  let spindleDef = program.spindles[spindle],
                  index < spindleDef.returns.count else {
                return .extract(call: recurse(callExpr), index: index)
            }
            let inlinedArgs = args.map(recurse)
            let inlined = inlineSpindleCallWithTarget(
                spindleDef: spindleDef, args: inlinedArgs,
                targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, returnIndex: index
            )
            return recurse(inlined)

        default:
            return expr.mapChildren(recurse)
        }
    }

    // MARK: - Temporal Remap to Cache Conversion

    /// Convert temporal remaps to cache builtins where the base expression is stateful.
    /// Two-phase approach:
    /// - Phase 1: Convert non-self-ref stateful temporal remaps to cache in-place
    /// - Phase 2: If self-ref temporal remaps remain, unwrap them and wrap the entire strand in cache
    public static func convertTemporalRemapsToCache(
        program: inout IRProgram,
        statefulBuiltins: Set<String>
    ) {
        for (bundleName, bundle) in program.bundles {
            var modifiedStrands: [IRStrand] = []
            for strand in bundle.strands {
                let keys = ["\(bundleName).\(strand.index)", "\(bundleName).\(strand.name)", bundleName]

                let phase1 = convertNonSelfRefTemporalRemaps(
                    in: strand.expr, strandKeys: keys, statefulBuiltins: statefulBuiltins, program: program
                )

                let finalExpr: IRExpr
                if let info = findFirstSelfRefTemporalRemap(in: phase1, strandKeys: keys) {
                    let unwrapped = unwrapSelfRefTemporalRemaps(in: phase1, strandKeys: keys)
                    finalExpr = .builtin(name: "cache", args: [
                        unwrapped, .num(Double(info.offset + 1)),
                        .num(Double(info.offset)), info.signal
                    ])
                } else {
                    finalExpr = phase1
                }
                modifiedStrands.append(IRStrand(name: strand.name, index: strand.index, expr: finalExpr))
            }
            program.bundles[bundleName] = IRBundle(name: bundleName, strands: modifiedStrands)
        }
    }

    /// Resolve builtins used by a remap base, following bundle indirection.
    private static func resolveBaseBuiltins(_ expr: IRExpr, program: IRProgram) -> Set<String> {
        if case .index(let bundle, let indexExpr) = expr, bundle != "me",
           let targetBundle = program.bundles[bundle] {
            if case .num(let idx) = indexExpr {
                let strandIdx = Int(idx)
                if strandIdx < targetBundle.strands.count {
                    return targetBundle.strands[strandIdx].expr.allBuiltins()
                }
            } else if case .param(let field) = indexExpr {
                if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                    return strand.expr.allBuiltins()
                }
            }
        }
        return expr.allBuiltins()
    }

    /// Phase 1: Convert non-self-ref stateful temporal remaps to cache in-place.
    private static func convertNonSelfRefTemporalRemaps(
        in expr: IRExpr,
        strandKeys: [String],
        statefulBuiltins: Set<String>,
        program: IRProgram
    ) -> IRExpr {
        let recurse = { (e: IRExpr) -> IRExpr in
            convertNonSelfRefTemporalRemaps(
                in: e, strandKeys: strandKeys,
                statefulBuiltins: statefulBuiltins, program: program
            )
        }

        guard case .remap(let base, let substitutions) = expr else {
            return expr.mapChildren(recurse)
        }

        guard let temporalExpr = substitutions["me.t"] else {
            return expr.mapChildren(recurse)
        }

        // Temporal remap -- check statefulness and self-reference
        let baseBuiltins = resolveBaseBuiltins(base, program: program)
        let isStateful = !baseBuiltins.isDisjoint(with: statefulBuiltins)
        let baseVars = base.freeVars()
        let isSelfRef = strandKeys.contains(where: { baseVars.contains($0) })

        if isStateful && !isSelfRef {
            let offset = extractTemporalOffset(temporalExpr)
            let signal = IRExpr.index(bundle: "me", indexExpr: .param("t"))
            return .builtin(name: "cache", args: [
                base, .num(Double(offset + 1)), .num(Double(offset)), signal
            ])
        }

        // Self-ref or pure: leave as remap, recurse into children
        return expr.mapChildren(recurse)
    }

    /// Phase 2 helper: Find the first self-referencing temporal remap.
    private static func findFirstSelfRefTemporalRemap(
        in expr: IRExpr,
        strandKeys: [String]
    ) -> (offset: Int, signal: IRExpr)? {
        if case .remap(let base, let substitutions) = expr,
           let temporalExpr = substitutions["me.t"] {
            let baseVars = base.freeVars()
            if strandKeys.contains(where: { baseVars.contains($0) }) {
                let offset = extractTemporalOffset(temporalExpr)
                return (offset: offset, signal: IRExpr.index(bundle: "me", indexExpr: .param("t")))
            }
        }
        var result: (offset: Int, signal: IRExpr)?
        expr.forEachChild { child in
            if result == nil {
                result = findFirstSelfRefTemporalRemap(in: child, strandKeys: strandKeys)
            }
        }
        return result
    }

    /// Phase 2 helper: Replace self-ref temporal remap nodes with their base.
    private static func unwrapSelfRefTemporalRemaps(
        in expr: IRExpr,
        strandKeys: [String]
    ) -> IRExpr {
        let recurse = { (e: IRExpr) -> IRExpr in
            unwrapSelfRefTemporalRemaps(in: e, strandKeys: strandKeys)
        }

        if case .remap(let base, let substitutions) = expr,
           substitutions.keys.contains("me.t") {
            let baseVars = base.freeVars()
            if strandKeys.contains(where: { baseVars.contains($0) }) {
                return recurse(base)
            }
        }
        return expr.mapChildren(recurse)
    }

    /// Extract temporal offset from substitution expression (me.t - N -> N).
    private static func extractTemporalOffset(_ expr: IRExpr) -> Int {
        if case .binaryOp(let op, _, let right) = expr {
            if op == "-", case .num(let n) = right, Int(n) > 0 { return Int(n) }
            if op == "+", case .num(let n) = right, Int(n) < 0 { return -Int(n) }
        }
        return 1
    }

    /// Transform program by inlining all spindle calls with proper cache target substitution
    public static func inlineSpindleCacheCalls(program: inout IRProgram) {
        for (bundleName, bundle) in program.bundles {
            var modifiedStrands: [IRStrand] = []
            for strand in bundle.strands {
                let inlinedExpr = inlineExprWithTarget(
                    expr: strand.expr, targetBundle: bundleName,
                    targetStrandIndex: strand.index, program: program
                )
                modifiedStrands.append(IRStrand(name: strand.name, index: strand.index, expr: inlinedExpr))
            }
            program.bundles[bundleName] = IRBundle(name: bundleName, strands: modifiedStrands)
        }
    }
}
