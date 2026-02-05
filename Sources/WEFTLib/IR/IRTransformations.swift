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
        switch expr {
        case .num:
            return expr

        case .param(let name):
            return substitutions[name] ?? expr

        case .index(let bundle, let indexExpr):
            if let subst = substitutions[bundle] {
                if case .index(let newBundle, _) = subst {
                    return .index(
                        bundle: newBundle,
                        indexExpr: substituteParams(in: indexExpr, substitutions: substitutions)
                    )
                }
            }
            return .index(
                bundle: bundle,
                indexExpr: substituteParams(in: indexExpr, substitutions: substitutions)
            )

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: substituteParams(in: left, substitutions: substitutions),
                right: substituteParams(in: right, substitutions: substitutions)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(
                op: op,
                operand: substituteParams(in: operand, substitutions: substitutions)
            )

        case .call(let spindle, let args):
            return .call(
                spindle: spindle,
                args: args.map { substituteParams(in: $0, substitutions: substitutions) }
            )

        case .builtin(let name, let args):
            return .builtin(
                name: name,
                args: args.map { substituteParams(in: $0, substitutions: substitutions) }
            )

        case .extract(let call, let index):
            return .extract(
                call: substituteParams(in: call, substitutions: substitutions),
                index: index
            )

        case .remap(let base, let remapSubs):
            var newRemapSubs: [String: IRExpr] = [:]
            for (key, value) in remapSubs {
                newRemapSubs[key] = substituteParams(in: value, substitutions: substitutions)
            }
            return .remap(
                base: substituteParams(in: base, substitutions: substitutions),
                substitutions: newRemapSubs
            )

        case .cacheRead:
            // cacheRead has no params to substitute
            return expr
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
        switch expr {
        case .num:
            return expr

        case .param:
            return expr

        case .index(let bundle, let indexExpr):
            // Try to look up this index reference in substitutions
            var keysToTry: [String] = []

            if case .param(let field) = indexExpr {
                keysToTry.append("\(bundle).\(field)")
            } else if case .num(let idx) = indexExpr {
                keysToTry.append("\(bundle).\(Int(idx))")
            }

            for key in keysToTry {
                if let replacement = substitutions[key] {
                    return replacement
                }
            }

            // No substitution found, recurse into indexExpr
            return .index(
                bundle: bundle,
                indexExpr: substituteIndexRefs(in: indexExpr, substitutions: substitutions)
            )

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: substituteIndexRefs(in: left, substitutions: substitutions),
                right: substituteIndexRefs(in: right, substitutions: substitutions)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(
                op: op,
                operand: substituteIndexRefs(in: operand, substitutions: substitutions)
            )

        case .call(let spindle, let args):
            return .call(
                spindle: spindle,
                args: args.map { substituteIndexRefs(in: $0, substitutions: substitutions) }
            )

        case .builtin(let name, let args):
            return .builtin(
                name: name,
                args: args.map { substituteIndexRefs(in: $0, substitutions: substitutions) }
            )

        case .extract(let call, let index):
            return .extract(
                call: substituteIndexRefs(in: call, substitutions: substitutions),
                index: index
            )

        case .remap(let base, let remapSubs):
            var newRemapSubs: [String: IRExpr] = [:]
            for (key, value) in remapSubs {
                newRemapSubs[key] = substituteIndexRefs(in: value, substitutions: substitutions)
            }
            return .remap(
                base: substituteIndexRefs(in: base, substitutions: substitutions),
                substitutions: newRemapSubs
            )

        case .cacheRead:
            return expr
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

    /// Apply remap substitutions to an expression (coordinate remapping).
    /// Substitution keys are in "bundle.field" format (e.g., "me.x", "me.y").
    public static func applyRemap(
        to expr: IRExpr,
        substitutions: [String: IRExpr]
    ) -> IRExpr {
        switch expr {
        case .num:
            return expr

        case .param(let name):
            if let remapped = substitutions[name] {
                return remapped
            }
            if let remapped = substitutions["me.\(name)"] {
                return remapped
            }
            return expr

        case .index(let bundle, let indexExpr):
            var keysToTry: [String] = []

            if case .param(let field) = indexExpr {
                keysToTry.append("\(bundle).\(field)")
                if bundle == "me" {
                    // Visual coordinate indices
                    let visualIndices = ["x": 0, "y": 1, "u": 2, "v": 3, "w": 4, "h": 5, "t": 6]
                    // Audio coordinate indices
                    let audioIndices = ["i": 0, "sampleRate": 2]

                    if let idx = visualIndices[field] {
                        keysToTry.append("\(bundle).\(idx)")
                    }
                    if let idx = audioIndices[field] {
                        keysToTry.append("\(bundle).\(idx)")
                    }
                }
            } else if case .num(let idx) = indexExpr {
                keysToTry.append("\(bundle).\(Int(idx))")
            }

            for key in keysToTry {
                if let remapped = substitutions[key] {
                    return remapped
                }
            }
            return .index(bundle: bundle, indexExpr: applyRemap(to: indexExpr, substitutions: substitutions))

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: applyRemap(to: left, substitutions: substitutions),
                right: applyRemap(to: right, substitutions: substitutions)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(
                op: op,
                operand: applyRemap(to: operand, substitutions: substitutions)
            )

        case .call(let spindle, let args):
            return .call(
                spindle: spindle,
                args: args.map { applyRemap(to: $0, substitutions: substitutions) }
            )

        case .builtin(let name, let args):
            return .builtin(
                name: name,
                args: args.map { applyRemap(to: $0, substitutions: substitutions) }
            )

        case .extract(let call, let index):
            return .extract(
                call: applyRemap(to: call, substitutions: substitutions),
                index: index
            )

        case .remap(let base, let innerSubs):
            var composedSubs: [String: IRExpr] = [:]
            for (key, value) in innerSubs {
                composedSubs[key] = applyRemap(to: value, substitutions: substitutions)
            }
            return .remap(
                base: applyRemap(to: base, substitutions: substitutions),
                substitutions: composedSubs
            )

        case .cacheRead:
            // cacheRead has no coordinates to remap
            return expr
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

        func visit(_ e: IRExpr) {
            switch e {
            case .num, .param, .cacheRead:
                break

            case .index(let bundle, let indexExpr):
                if localNames.contains(bundle) {
                    result.insert(bundle)
                }
                visit(indexExpr)

            case .binaryOp(_, let left, let right):
                visit(left)
                visit(right)

            case .unaryOp(_, let operand):
                visit(operand)

            case .builtin(_, let args):
                args.forEach { visit($0) }

            case .call(_, let args):
                args.forEach { visit($0) }

            case .extract(let call, _):
                visit(call)

            case .remap(let base, let subs):
                visit(base)
                subs.values.forEach { visit($0) }
            }
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

        func visit(_ e: IRExpr) {
            switch e {
            case .index(let bundle, let indexExpr):
                if localNames.contains(bundle) {
                    let strandIdx: Int
                    if case .num(let idx) = indexExpr {
                        strandIdx = Int(idx)
                    } else {
                        strandIdx = 0
                    }
                    refs.append((bundle, strandIdx))
                }
                visit(indexExpr)

            case .binaryOp(_, let left, let right):
                visit(left)
                visit(right)

            case .unaryOp(_, let operand):
                visit(operand)

            case .builtin(_, let args):
                args.forEach { visit($0) }

            case .call(_, let args):
                args.forEach { visit($0) }

            case .extract(let call, _):
                visit(call)

            case .remap(let base, let subs):
                visit(base)
                subs.values.forEach { visit($0) }

            default:
                break
            }
        }

        visit(expr)
        return refs
    }

    /// Find all cache builtin calls in an expression and extract their value expression local refs
    public static func findCachesWithLocalRefs(
        _ expr: IRExpr,
        localNames: Set<String>
    ) -> [(valueLocalName: String, valueStrandIndex: Int)] {
        var results: [(String, Int)] = []

        func visit(_ e: IRExpr) {
            switch e {
            case .builtin(let name, let args) where name == "cache":
                guard args.count >= 1 else { return }
                // Find all local refs in the value expression (first arg)
                let valueLocalRefs = findLocalStrandRefs(args[0], localNames: localNames)
                results.append(contentsOf: valueLocalRefs)
                // Also check recursively in other args for nested caches
                args.forEach { visit($0) }

            case .binaryOp(_, let left, let right):
                visit(left)
                visit(right)

            case .unaryOp(_, let operand):
                visit(operand)

            case .builtin(_, let args):
                args.forEach { visit($0) }

            case .call(_, let args):
                args.forEach { visit($0) }

            case .extract(let call, _):
                visit(call)

            case .remap(let base, let subs):
                visit(base)
                subs.values.forEach { visit($0) }

            default:
                break
            }
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
        switch expr {
        case .num, .param, .cacheRead:
            return expr

        case .index(let bundle, let indexExpr):
            // Check if this is the reference to replace
            if bundle == localName {
                if case .num(let idx) = indexExpr, Int(idx) == strandIndex {
                    return replacement
                }
                if case .param(let field) = indexExpr {
                    // Check if field matches the strand index (by name or numeric)
                    if Int(field) == strandIndex {
                        return replacement
                    }
                }
            }
            return .index(
                bundle: bundle,
                indexExpr: substituteCyclicRef(in: indexExpr, localName: localName, strandIndex: strandIndex, replacement: replacement)
            )

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: substituteCyclicRef(in: left, localName: localName, strandIndex: strandIndex, replacement: replacement),
                right: substituteCyclicRef(in: right, localName: localName, strandIndex: strandIndex, replacement: replacement)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(
                op: op,
                operand: substituteCyclicRef(in: operand, localName: localName, strandIndex: strandIndex, replacement: replacement)
            )

        case .builtin(let name, let args):
            return .builtin(
                name: name,
                args: args.map { substituteCyclicRef(in: $0, localName: localName, strandIndex: strandIndex, replacement: replacement) }
            )

        case .call(let spindle, let args):
            return .call(
                spindle: spindle,
                args: args.map { substituteCyclicRef(in: $0, localName: localName, strandIndex: strandIndex, replacement: replacement) }
            )

        case .extract(let call, let index):
            return .extract(
                call: substituteCyclicRef(in: call, localName: localName, strandIndex: strandIndex, replacement: replacement),
                index: index
            )

        case .remap(let base, let subs):
            var newSubs: [String: IRExpr] = [:]
            for (key, value) in subs {
                newSubs[key] = substituteCyclicRef(in: value, localName: localName, strandIndex: strandIndex, replacement: replacement)
            }
            return .remap(
                base: substituteCyclicRef(in: base, localName: localName, strandIndex: strandIndex, replacement: replacement),
                substitutions: newSubs
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
        switch expr {
        case .num, .param, .cacheRead:
            return expr

        case .index(let bundle, let indexExpr):
            return .index(
                bundle: bundle,
                indexExpr: inlineExprWithTarget(expr: indexExpr, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program)
            )

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: inlineExprWithTarget(expr: left, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program),
                right: inlineExprWithTarget(expr: right, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(
                op: op,
                operand: inlineExprWithTarget(expr: operand, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program)
            )

        case .builtin(let name, let args):
            let inlinedArgs = args.map { arg in
                inlineExprWithTarget(expr: arg, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program)
            }
            return .builtin(name: name, args: inlinedArgs)

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle],
                  !spindleDef.returns.isEmpty else {
                // Unknown spindle or no returns, inline args and keep call
                let inlinedArgs = args.map { arg in
                    inlineExprWithTarget(expr: arg, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program)
                }
                return .call(spindle: spindle, args: inlinedArgs)
            }

            // First inline args
            let inlinedArgs = args.map { arg in
                inlineExprWithTarget(expr: arg, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program)
            }

            // Then inline spindle with target substitution
            let inlined = inlineSpindleCallWithTarget(
                spindleDef: spindleDef,
                args: inlinedArgs,
                targetBundle: targetBundle,
                targetStrandIndex: targetStrandIndex,
                returnIndex: 0
            )

            // Recursively process the inlined result
            return inlineExprWithTarget(
                expr: inlined,
                targetBundle: targetBundle,
                targetStrandIndex: targetStrandIndex,
                program: program
            )

        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr,
                  let spindleDef = program.spindles[spindle],
                  index < spindleDef.returns.count else {
                // Keep as-is if can't inline
                return .extract(
                    call: inlineExprWithTarget(expr: callExpr, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program),
                    index: index
                )
            }

            // First inline args
            let inlinedArgs = args.map { arg in
                inlineExprWithTarget(expr: arg, targetBundle: targetBundle, targetStrandIndex: targetStrandIndex, program: program)
            }

            // Inline spindle with target substitution for the specific return
            let inlined = inlineSpindleCallWithTarget(
                spindleDef: spindleDef,
                args: inlinedArgs,
                targetBundle: targetBundle,
                targetStrandIndex: targetStrandIndex,
                returnIndex: index
            )

            // Recursively process the inlined result
            return inlineExprWithTarget(
                expr: inlined,
                targetBundle: targetBundle,
                targetStrandIndex: targetStrandIndex,
                program: program
            )

        case .remap(let base, let subs):
            let inlinedBase = inlineExprWithTarget(
                expr: base,
                targetBundle: targetBundle,
                targetStrandIndex: targetStrandIndex,
                program: program
            )
            var inlinedSubs: [String: IRExpr] = [:]
            for (key, value) in subs {
                inlinedSubs[key] = inlineExprWithTarget(
                    expr: value,
                    targetBundle: targetBundle,
                    targetStrandIndex: targetStrandIndex,
                    program: program
                )
            }
            return .remap(base: inlinedBase, substitutions: inlinedSubs)
        }
    }

    // MARK: - Temporal Remap to Cache Conversion

    /// Convert temporal remaps to cache builtins where the base expression is stateful.
    /// Two-phase approach:
    /// - Phase 1: Convert non-self-ref stateful temporal remaps to cache in-place
    /// - Phase 2: If self-ref temporal remaps remain, unwrap them and wrap the entire strand in cache
    /// Pure temporal remaps are left as coordinate substitution.
    public static func convertTemporalRemapsToCache(
        program: inout IRProgram,
        statefulBuiltins: Set<String>
    ) {
        for (bundleName, bundle) in program.bundles {
            var modifiedStrands: [IRStrand] = []

            for strand in bundle.strands {
                let strandKey = "\(bundleName).\(strand.index)"
                let strandNameKey = "\(bundleName).\(strand.name)"
                let keys = [strandKey, strandNameKey, bundleName]

                // Phase 1: Convert non-self-ref stateful temporal remaps
                let phase1 = convertNonSelfRefTemporalRemaps(
                    in: strand.expr, strandKeys: keys, statefulBuiltins: statefulBuiltins, program: program
                )

                // Phase 2: Handle self-ref temporal remaps by wrapping entire strand
                let finalExpr: IRExpr
                if let info = findFirstSelfRefTemporalRemap(in: phase1, strandKeys: keys) {
                    let unwrapped = unwrapSelfRefTemporalRemaps(in: phase1, strandKeys: keys)
                    finalExpr = .builtin(name: "cache", args: [
                        unwrapped,
                        .num(Double(info.offset + 1)),
                        .num(Double(info.offset)),
                        info.signal
                    ])
                } else {
                    finalExpr = phase1
                }

                modifiedStrands.append(IRStrand(
                    name: strand.name, index: strand.index, expr: finalExpr
                ))
            }

            program.bundles[bundleName] = IRBundle(name: bundleName, strands: modifiedStrands)
        }
    }

    /// Resolve the builtins used by a remap base expression, following bundle indirection.
    /// For `.index(bundle, _)` where bundle is a user-defined bundle, looks up the strand's
    /// expression in the program to find the actual builtins (e.g., camera, microphone).
    private static func resolveBaseBuiltins(
        _ expr: IRExpr,
        program: IRProgram
    ) -> Set<String> {
        switch expr {
        case .index(let bundle, let indexExpr) where bundle != "me":
            if let targetBundle = program.bundles[bundle] {
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
        default:
            return expr.allBuiltins()
        }
    }

    /// Phase 1: Convert non-self-ref stateful temporal remaps to cache in-place.
    /// Self-ref temporal remaps are left as remap nodes for Phase 2.
    private static func convertNonSelfRefTemporalRemaps(
        in expr: IRExpr,
        strandKeys: [String],
        statefulBuiltins: Set<String>,
        program: IRProgram
    ) -> IRExpr {
        switch expr {
        case .num, .param, .cacheRead:
            return expr

        case .index(let bundle, let indexExpr):
            return .index(
                bundle: bundle,
                indexExpr: convertNonSelfRefTemporalRemaps(in: indexExpr, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program)
            )

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: convertNonSelfRefTemporalRemaps(in: left, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program),
                right: convertNonSelfRefTemporalRemaps(in: right, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(
                op: op,
                operand: convertNonSelfRefTemporalRemaps(in: operand, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program)
            )

        case .builtin(let name, let args):
            return .builtin(
                name: name,
                args: args.map { convertNonSelfRefTemporalRemaps(in: $0, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program) }
            )

        case .call(let spindle, let args):
            return .call(
                spindle: spindle,
                args: args.map { convertNonSelfRefTemporalRemaps(in: $0, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program) }
            )

        case .extract(let call, let index):
            return .extract(
                call: convertNonSelfRefTemporalRemaps(in: call, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program),
                index: index
            )

        case .remap(let base, let substitutions):
            // Check if this is a temporal remap (has "me.t" key)
            guard let temporalExpr = substitutions["me.t"] else {
                // Non-temporal remap: recurse into children
                let newBase = convertNonSelfRefTemporalRemaps(in: base, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program)
                var newSubs: [String: IRExpr] = [:]
                for (key, value) in substitutions {
                    newSubs[key] = convertNonSelfRefTemporalRemaps(in: value, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program)
                }
                return .remap(base: newBase, substitutions: newSubs)
            }

            // Temporal remap -- check statefulness and self-reference
            // Use resolveBaseBuiltins to follow bundle indirection (e.g. cam.r -> camera())
            let baseBuiltins = resolveBaseBuiltins(base, program: program)
            let isStateful = !baseBuiltins.isDisjoint(with: statefulBuiltins)
            let baseVars = base.freeVars()
            let isSelfRef = strandKeys.contains(where: { baseVars.contains($0) })

            if isStateful && !isSelfRef {
                // Non-self-ref stateful: convert to cache in-place
                let offset = extractTemporalOffset(temporalExpr)
                let signal = IRExpr.index(bundle: "me", indexExpr: .param("t"))
                return .builtin(name: "cache", args: [
                    base,
                    .num(Double(offset + 1)),
                    .num(Double(offset)),
                    signal
                ])
            }

            // Self-ref or pure: leave as remap, but recurse into children
            let newBase = convertNonSelfRefTemporalRemaps(in: base, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program)
            var newSubs: [String: IRExpr] = [:]
            for (key, value) in substitutions {
                newSubs[key] = convertNonSelfRefTemporalRemaps(in: value, strandKeys: strandKeys, statefulBuiltins: statefulBuiltins, program: program)
            }
            return .remap(base: newBase, substitutions: newSubs)
        }
    }

    /// Phase 2 helper: Find the first self-referencing temporal remap in an expression.
    /// Returns the temporal offset and signal expression, or nil if none found.
    private static func findFirstSelfRefTemporalRemap(
        in expr: IRExpr,
        strandKeys: [String]
    ) -> (offset: Int, signal: IRExpr)? {
        switch expr {
        case .num, .param, .cacheRead:
            return nil

        case .index(_, let indexExpr):
            return findFirstSelfRefTemporalRemap(in: indexExpr, strandKeys: strandKeys)

        case .binaryOp(_, let left, let right):
            return findFirstSelfRefTemporalRemap(in: left, strandKeys: strandKeys)
                ?? findFirstSelfRefTemporalRemap(in: right, strandKeys: strandKeys)

        case .unaryOp(_, let operand):
            return findFirstSelfRefTemporalRemap(in: operand, strandKeys: strandKeys)

        case .builtin(_, let args):
            for arg in args {
                if let result = findFirstSelfRefTemporalRemap(in: arg, strandKeys: strandKeys) {
                    return result
                }
            }
            return nil

        case .call(_, let args):
            for arg in args {
                if let result = findFirstSelfRefTemporalRemap(in: arg, strandKeys: strandKeys) {
                    return result
                }
            }
            return nil

        case .extract(let call, _):
            return findFirstSelfRefTemporalRemap(in: call, strandKeys: strandKeys)

        case .remap(let base, let substitutions):
            if let temporalExpr = substitutions["me.t"] {
                let baseVars = base.freeVars()
                let isSelfRef = strandKeys.contains(where: { baseVars.contains($0) })
                if isSelfRef {
                    let offset = extractTemporalOffset(temporalExpr)
                    let signal = IRExpr.index(bundle: "me", indexExpr: .param("t"))
                    return (offset: offset, signal: signal)
                }
            }
            // Recurse
            if let result = findFirstSelfRefTemporalRemap(in: base, strandKeys: strandKeys) {
                return result
            }
            for (_, value) in substitutions {
                if let result = findFirstSelfRefTemporalRemap(in: value, strandKeys: strandKeys) {
                    return result
                }
            }
            return nil
        }
    }

    /// Phase 2 helper: Replace self-ref temporal remap nodes with just their base expression.
    /// This "unwraps" the remap so the full strand expression can be wrapped in cache.
    private static func unwrapSelfRefTemporalRemaps(
        in expr: IRExpr,
        strandKeys: [String]
    ) -> IRExpr {
        switch expr {
        case .num, .param, .cacheRead:
            return expr

        case .index(let bundle, let indexExpr):
            return .index(
                bundle: bundle,
                indexExpr: unwrapSelfRefTemporalRemaps(in: indexExpr, strandKeys: strandKeys)
            )

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: unwrapSelfRefTemporalRemaps(in: left, strandKeys: strandKeys),
                right: unwrapSelfRefTemporalRemaps(in: right, strandKeys: strandKeys)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(
                op: op,
                operand: unwrapSelfRefTemporalRemaps(in: operand, strandKeys: strandKeys)
            )

        case .builtin(let name, let args):
            return .builtin(
                name: name,
                args: args.map { unwrapSelfRefTemporalRemaps(in: $0, strandKeys: strandKeys) }
            )

        case .call(let spindle, let args):
            return .call(
                spindle: spindle,
                args: args.map { unwrapSelfRefTemporalRemaps(in: $0, strandKeys: strandKeys) }
            )

        case .extract(let call, let index):
            return .extract(
                call: unwrapSelfRefTemporalRemaps(in: call, strandKeys: strandKeys),
                index: index
            )

        case .remap(let base, let substitutions):
            // Check if this is a self-ref temporal remap
            if substitutions.keys.contains("me.t") {
                let baseVars = base.freeVars()
                let isSelfRef = strandKeys.contains(where: { baseVars.contains($0) })
                if isSelfRef {
                    // Unwrap: return just the base (with recursive unwrapping)
                    return unwrapSelfRefTemporalRemaps(in: base, strandKeys: strandKeys)
                }
            }
            // Not a self-ref temporal remap: recurse normally
            let newBase = unwrapSelfRefTemporalRemaps(in: base, strandKeys: strandKeys)
            var newSubs: [String: IRExpr] = [:]
            for (key, value) in substitutions {
                newSubs[key] = unwrapSelfRefTemporalRemaps(in: value, strandKeys: strandKeys)
            }
            return .remap(base: newBase, substitutions: newSubs)
        }
    }

    /// Extract the integer offset N from a temporal substitution expression.
    /// Expects patterns like `me.t - N` -> returns N, or `me.t + N` -> returns -N.
    /// Falls back to 1 for unrecognized patterns.
    private static func extractTemporalOffset(_ expr: IRExpr) -> Int {
        // Pattern: (me.t - N) where N is a positive literal
        if case .binaryOp(let op, _, let right) = expr {
            if op == "-", case .num(let n) = right {
                let intN = Int(n)
                if intN > 0 { return intN }
            }
            if op == "+", case .num(let n) = right {
                let intN = Int(n)
                if intN < 0 { return -intN }
            }
        }
        // Fallback: assume offset 1
        return 1
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
