// IRTransformations.swift - Shared IR transformation utilities

import Foundation

// MARK: - IR Transformations

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
        return expr.transform { e in
            switch e {
            case .param(let name):
                return substitutions[name]

            case .index(let bundle, let indexExpr):
                // Special handling: if bundle maps to another index, replace bundle name
                let newBundle: String
                if let subst = substitutions[bundle],
                   case .index(let substBundle, _) = subst {
                    newBundle = substBundle
                } else {
                    newBundle = bundle
                }
                return .index(
                    bundle: newBundle,
                    indexExpr: substituteParams(in: indexExpr, substitutions: substitutions)
                )

            default:
                return nil  // Use default recursive transform
            }
        }
    }

    // MARK: - Spindle Substitution Builder

    /// Build complete substitution map for inlining a spindle call.
    /// Includes both parameter substitutions and local bundle resolutions.
    /// Locals are processed in definition order, so later locals can reference earlier ones.
    public static func buildSpindleSubstitutions(
        spindleDef: IRSpindle,
        args: [IRExpr]
    ) -> [String: IRExpr] {
        // Start with parameter substitutions
        var substitutions: [String: IRExpr] = [:]
        for (i, param) in spindleDef.params.enumerated() {
            if i < args.count {
                substitutions[param] = args[i]
            }
        }

        // Process local bundles - add their strand expressions to substitutions
        // Locals are processed in order, so later locals can reference earlier ones
        for local in spindleDef.locals {
            for strand in local.strands {
                // Substitute params in the local's expression first
                let localExpr = substituteParams(in: strand.expr, substitutions: substitutions)
                // Now substitute any references to earlier locals
                let fullyInlined = substituteIndexRefs(in: localExpr, substitutions: substitutions)
                // Add to substitutions using both index and name formats
                substitutions["\(local.name).\(strand.index)"] = fullyInlined
                substitutions["\(local.name).\(strand.name)"] = fullyInlined
            }
        }

        return substitutions
    }

    // MARK: - Index Reference Substitution

    /// Substitute .index expressions where the bundle.strand key exists in substitutions.
    /// Used when inlining spindle calls that have local bundles.
    /// For example, if substitutions contains "diff.y" -> someExpr,
    /// then .index(bundle: "diff", indexExpr: .param("y")) will be replaced with someExpr.
    public static func substituteIndexRefs(
        in expr: IRExpr,
        substitutions: [String: IRExpr]
    ) -> IRExpr {
        return expr.transform { e in
            guard case .index(let bundle, let indexExpr) = e else {
                return nil  // Use default recursive transform
            }

            // Build keys to look up in substitutions
            let key: String?
            if case .param(let field) = indexExpr {
                key = "\(bundle).\(field)"
            } else if case .num(let idx) = indexExpr {
                key = "\(bundle).\(Int(idx))"
            } else {
                key = nil
            }

            // If we find a substitution, use it
            if let key = key, let replacement = substitutions[key] {
                return replacement
            }

            // Otherwise, recurse into indexExpr
            return .index(
                bundle: bundle,
                indexExpr: substituteIndexRefs(in: indexExpr, substitutions: substitutions)
            )
        }
    }

    // MARK: - Direct Expression

    /// Get the direct expression for a bundle reference WITHOUT recursively inlining dependencies.
    /// This is used for remap so that substitutions only affect the immediate expression.
    public static func getDirectExpression(
        _ expr: IRExpr,
        program: IRProgram
    ) -> IRExpr {
        switch expr {
        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                return expr
            }
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
            guard case .call(let spindle, let args) = callExpr else {
                return expr
            }
            guard let spindleDef = program.spindles[spindle] else {
                return expr
            }
            guard index < spindleDef.returns.count else {
                return expr
            }
            let substitutions = buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var result = substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            result = substituteIndexRefs(in: result, substitutions: substitutions)
            return result

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle] else {
                return expr
            }
            guard !spindleDef.returns.isEmpty else {
                return expr
            }
            let substitutions = buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var result = substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            result = substituteIndexRefs(in: result, substitutions: substitutions)
            return result

        default:
            return expr
        }
    }

    // MARK: - Expression Inlining

    /// Inline bundle references to their actual expressions (at IR level, no code generation).
    /// This resolves bundle.strand references to their defining expressions.
    public static func inlineExpression(
        _ expr: IRExpr,
        program: IRProgram
    ) throws -> IRExpr {
        switch expr {
        case .num, .param:
            return expr

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                return expr
            }

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

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: try inlineExpression(left, program: program),
                right: try inlineExpression(right, program: program)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(op: op, operand: try inlineExpression(operand, program: program))

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle] else {
                return expr
            }
            guard !spindleDef.returns.isEmpty else {
                return expr
            }
            // Inline args first, then build substitutions including locals
            let inlinedArgs = try args.map { try inlineExpression($0, program: program) }
            let substitutions = buildSpindleSubstitutions(spindleDef: spindleDef, args: inlinedArgs)
            var result = substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            result = substituteIndexRefs(in: result, substitutions: substitutions)
            return try inlineExpression(result, program: program)

        case .builtin(let name, let args):
            return .builtin(name: name, args: try args.map { try inlineExpression($0, program: program) })

        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr else {
                return expr
            }
            guard let spindleDef = program.spindles[spindle] else {
                return expr
            }
            guard index < spindleDef.returns.count else {
                return expr
            }
            // Inline args first, then build substitutions including locals
            let inlinedArgs = try args.map { try inlineExpression($0, program: program) }
            let substitutions = buildSpindleSubstitutions(spindleDef: spindleDef, args: inlinedArgs)
            var result = substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            result = substituteIndexRefs(in: result, substitutions: substitutions)
            return try inlineExpression(result, program: program)

        case .remap(let base, let substitutions):
            let inlinedBase = try inlineExpression(base, program: program)
            var inlinedSubs: [String: IRExpr] = [:]
            for (key, value) in substitutions {
                inlinedSubs[key] = try inlineExpression(value, program: program)
            }
            return applyRemap(to: inlinedBase, substitutions: inlinedSubs)

        case .cacheRead:
            // cacheRead is already resolved
            return expr
        }
    }

    // MARK: - Remap Application

    // Coordinate field to index mappings (shared for remap operations)
    private static let visualCoordIndices = ["x": 0, "y": 1, "u": 2, "v": 3, "w": 4, "h": 5, "t": 6]
    private static let audioCoordIndices = ["i": 0, "sampleRate": 2]

    /// Apply remap substitutions to an expression (coordinate remapping).
    /// Substitution keys are in "bundle.field" format (e.g., "me.x", "me.y").
    public static func applyRemap(
        to expr: IRExpr,
        substitutions: [String: IRExpr]
    ) -> IRExpr {
        return expr.transform { e in
            switch e {
            case .param(let name):
                // Try direct lookup, then prefixed with "me."
                return substitutions[name] ?? substitutions["me.\(name)"]

            case .index(let bundle, let indexExpr):
                // Build keys to try
                var keysToTry: [String] = []

                if case .param(let field) = indexExpr {
                    keysToTry.append("\(bundle).\(field)")
                    if bundle == "me" {
                        // Also try numeric index for coordinate fields
                        if let idx = visualCoordIndices[field] {
                            keysToTry.append("\(bundle).\(idx)")
                        }
                        if let idx = audioCoordIndices[field] {
                            keysToTry.append("\(bundle).\(idx)")
                        }
                    }
                } else if case .num(let idx) = indexExpr {
                    keysToTry.append("\(bundle).\(Int(idx))")
                }

                // Try each key
                for key in keysToTry {
                    if let remapped = substitutions[key] {
                        return remapped
                    }
                }

                // No match, recurse into indexExpr
                return .index(bundle: bundle, indexExpr: applyRemap(to: indexExpr, substitutions: substitutions))

            default:
                return nil  // Use default recursive transform
            }
        }
    }

    // MARK: - Spindle Cache Inlining

    /// Describes a cache in a spindle that has a cyclic dependency
    public struct SpindleCyclicCache {
        public let cacheLocalName: String      // Local containing the cache
        public let cacheStrandName: String     // Strand containing the cache
        public let cyclicLocalName: String     // Local referenced in cache value that forms cycle
        public let cyclicStrandIndex: Int      // Strand index referenced
    }

    /// Collect all local bundle names referenced by an expression
    public static func collectLocalReferences(
        _ expr: IRExpr,
        localNames: Set<String>
    ) -> Set<String> {
        var result = Set<String>()
        expr.forEach { e in
            if case .index(let bundle, _) = e, localNames.contains(bundle) {
                result.insert(bundle)
            }
        }
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
        guard let local = locals.first(where: { $0.name == localName }) else {
            return []
        }

        var newVisited = visited
        newVisited.insert(localName)

        var result = Set<String>()
        for strand in local.strands {
            let directDeps = collectLocalReferences(strand.expr, localNames: localNames)
            result.formUnion(directDeps)

            // Recursively get transitive deps
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
        expr.forEach { e in
            if case .index(let bundle, let indexExpr) = e, localNames.contains(bundle) {
                let strandIdx: Int
                if case .num(let idx) = indexExpr {
                    strandIdx = Int(idx)
                } else {
                    strandIdx = 0
                }
                refs.append((bundle, strandIdx))
            }
        }
        return refs
    }

    /// Find all cache builtin calls in an expression and extract their value expression local refs
    public static func findCachesWithLocalRefs(
        _ expr: IRExpr,
        localNames: Set<String>
    ) -> [(valueLocalName: String, valueStrandIndex: Int)] {
        var results: [(String, Int)] = []
        expr.forEach { e in
            if case .builtin(let name, let args) = e, name == "cache", args.count >= 1 {
                // Find all local refs in the value expression (first arg)
                results.append(contentsOf: findLocalStrandRefs(args[0], localNames: localNames))
            }
        }
        return results
    }

    /// Find caches in spindle that have cyclic dependencies through their value expression
    public static func findCyclicCachesInSpindle(
        _ spindleDef: IRSpindle
    ) -> [SpindleCyclicCache] {
        var cycles: [SpindleCyclicCache] = []
        let localNames = Set(spindleDef.locals.map { $0.name })

        // For each return, find which locals it depends on (directly + transitively)
        for returnExpr in spindleDef.returns {
            let returnLocalRefs = collectLocalReferences(returnExpr, localNames: localNames)

            // Get transitive deps for all directly referenced locals
            var allReturnDeps = returnLocalRefs
            for localName in returnLocalRefs {
                allReturnDeps.formUnion(transitiveLocalDeps(localName, locals: spindleDef.locals))
            }

            // For each local that feeds into the return path
            for localName in allReturnDeps {
                guard let local = spindleDef.locals.first(where: { $0.name == localName }) else {
                    continue
                }

                for strand in local.strands {
                    // Find caches in this strand's expression
                    let cacheRefs = findCachesWithLocalRefs(strand.expr, localNames: localNames)

                    for (refLocalName, refStrandIdx) in cacheRefs {
                        // Check if the referenced local is in the return path
                        guard allReturnDeps.contains(refLocalName) else { continue }

                        // Check if the referenced local transitively depends back on this local (cycle)
                        let refDeps = transitiveLocalDeps(refLocalName, locals: spindleDef.locals)
                        if refDeps.contains(localName) || refLocalName == localName {
                            // Found a cycle!
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
        return expr.transform { e in
            guard case .index(let bundle, let indexExpr) = e else {
                return nil  // Use default recursive transform
            }

            // Check if this is the reference to replace
            if bundle == localName {
                if case .num(let idx) = indexExpr, Int(idx) == strandIndex {
                    return replacement
                }
                if case .param(let field) = indexExpr, Int(field) == strandIndex {
                    return replacement
                }
            }

            // Recurse into indexExpr
            return .index(
                bundle: bundle,
                indexExpr: substituteCyclicRef(in: indexExpr, localName: localName, strandIndex: strandIndex, replacement: replacement)
            )
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
        // 1. Find cyclic caches in this spindle
        let cycles = findCyclicCachesInSpindle(spindleDef)

        // 2. If no cycles, use standard inlining
        guard !cycles.isEmpty else {
            let subs = buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            guard returnIndex < spindleDef.returns.count else {
                return .num(0)
            }
            var result = substituteParams(in: spindleDef.returns[returnIndex], substitutions: subs)
            result = substituteIndexRefs(in: result, substitutions: subs)
            return result
        }

        // 3. Build the target reference
        let targetRef = IRExpr.index(
            bundle: targetBundle,
            indexExpr: .num(Double(targetStrandIndex))
        )

        // 4. Create modified locals where cyclic references are replaced with target
        var modifiedLocals: [IRBundle] = []

        for local in spindleDef.locals {
            var modifiedStrands: [IRStrand] = []

            for strand in local.strands {
                // Check if this strand has any cyclic cache
                let relevantCycles = cycles.filter { cycle in
                    cycle.cacheLocalName == local.name && cycle.cacheStrandName == strand.name
                }

                if !relevantCycles.isEmpty {
                    // Substitute all cyclic references in this strand's expression
                    var modifiedExpr = strand.expr
                    for cycle in relevantCycles {
                        modifiedExpr = substituteCyclicRef(
                            in: modifiedExpr,
                            localName: cycle.cyclicLocalName,
                            strandIndex: cycle.cyclicStrandIndex,
                            replacement: targetRef
                        )
                    }
                    modifiedStrands.append(IRStrand(
                        name: strand.name,
                        index: strand.index,
                        expr: modifiedExpr
                    ))
                } else {
                    modifiedStrands.append(strand)
                }
            }

            modifiedLocals.append(IRBundle(name: local.name, strands: modifiedStrands))
        }

        // 5. Create modified spindle for substitution building
        let modifiedSpindle = IRSpindle(
            name: spindleDef.name,
            params: spindleDef.params,
            locals: modifiedLocals,
            returns: spindleDef.returns
        )

        // 6. Build substitutions with modified locals
        let subs = buildSpindleSubstitutions(spindleDef: modifiedSpindle, args: args)

        // 7. Inline the return expression
        guard returnIndex < spindleDef.returns.count else {
            return .num(0)
        }
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
        // Helper to recursively inline
        func recurse(_ e: IRExpr) -> IRExpr {
            inlineExprWithTarget(expr: e, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program)
        }

        return expr.transform { e in
            switch e {
            case .call(let spindle, let args):
                let inlinedArgs = args.map(recurse)
                guard let spindleDef = program.spindles[spindle],
                      !spindleDef.returns.isEmpty else {
                    return .call(spindle: spindle, args: inlinedArgs)
                }

                let inlined = inlineSpindleCallWithTarget(
                    spindleDef: spindleDef,
                    args: inlinedArgs,
                    targetBundle: targetBundle,
                    targetStrandIndex: targetStrandIndex,
                    returnIndex: 0
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
                    spindleDef: spindleDef,
                    args: inlinedArgs,
                    targetBundle: targetBundle,
                    targetStrandIndex: targetStrandIndex,
                    returnIndex: index
                )
                return recurse(inlined)

            default:
                return nil  // Use default recursive transform
            }
        }
    }

    /// Transform program by inlining all spindle calls with proper cache target substitution
    public static func inlineSpindleCacheCalls(program: inout IRProgram) {
        for (bundleName, bundle) in program.bundles {
            var modifiedStrands: [IRStrand] = []

            for strand in bundle.strands {
                let inlinedExpr = inlineExprWithTarget(
                    expr: strand.expr,
                    targetBundle: bundleName,
                    targetStrandIndex: strand.index,
                    program: program
                )
                modifiedStrands.append(IRStrand(
                    name: strand.name,
                    index: strand.index,
                    expr: inlinedExpr
                ))
            }

            program.bundles[bundleName] = IRBundle(name: bundleName, strands: modifiedStrands)
        }
    }
}
