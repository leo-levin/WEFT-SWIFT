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
            var substitutions: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count {
                    substitutions[param] = args[i]
                }
            }
            return substituteParams(in: spindleDef.returns[index], substitutions: substitutions)

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle] else {
                return expr
            }
            guard !spindleDef.returns.isEmpty else {
                return expr
            }
            var substitutions: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count {
                    substitutions[param] = args[i]
                }
            }
            return substituteParams(in: spindleDef.returns[0], substitutions: substitutions)

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
            var substitutions: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count {
                    substitutions[param] = try inlineExpression(args[i], program: program)
                }
            }
            let inlined = substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            return try inlineExpression(inlined, program: program)

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
            var substitutions: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count {
                    substitutions[param] = try inlineExpression(args[i], program: program)
                }
            }
            let inlined = substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            return try inlineExpression(inlined, program: program)

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
}
