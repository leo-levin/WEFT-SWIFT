// AudioCodeGen.swift - Generate Swift audio render closures from IR

import Foundation

// MARK: - Audio Code Generator

public class AudioCodeGen {
    private let program: IRProgram
    private let swatch: Swatch

    public init(program: IRProgram, swatch: Swatch) {
        self.program = program
        self.swatch = swatch
    }

    /// Generate audio render function
    /// Returns a closure: (sampleIndex: Int, time: Double, sampleRate: Double) -> (left: Float, right: Float)
    public func generateRenderFunction() throws -> AudioRenderFunction {
        guard let playBundle = program.bundles["play"] else {
            throw BackendError.missingResource("play bundle not found")
        }

        // Build expression evaluators for each channel
        let channelEvaluators = try playBundle.strands.sorted(by: { $0.index < $1.index }).map { strand in
            try buildEvaluator(for: strand.expr)
        }

        // Return a render function that evaluates all channels
        return { (sampleIndex: Int, time: Double, sampleRate: Double) -> (Float, Float) in
            let context = AudioContext(
                sampleIndex: sampleIndex,
                time: time,
                sampleRate: sampleRate
            )

            // Evaluate channels
            let left = channelEvaluators.count > 0 ? channelEvaluators[0](context) : 0.0
            let right = channelEvaluators.count > 1 ? channelEvaluators[1](context) : left

            return (left, right)
        }
    }

    /// Build an evaluator closure for an expression
    private func buildEvaluator(for expr: IRExpr) throws -> (AudioContext) -> Float {
        switch expr {
        case .num(let value):
            let v = Float(value)
            return { _ in v }

        case .param(let name):
            // Return coordinate parameter
            return { context in
                switch name {
                case "i": return Float(context.sampleIndex)
                case "t": return Float(context.time)
                case "sampleRate": return Float(context.sampleRate)
                default: return 0.0
                }
            }

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                // Access coordinate
                if case .param(let field) = indexExpr {
                    return { context in
                        switch field {
                        case "i": return Float(context.sampleIndex)
                        case "t": return Float(context.time)
                        case "sampleRate": return Float(context.sampleRate)
                        default: return 0.0
                        }
                    }
                }
            }

            // Access another bundle
            if let targetBundle = program.bundles[bundle] {
                if case .num(let idx) = indexExpr {
                    let strandIdx = Int(idx)
                    if strandIdx < targetBundle.strands.count {
                        return try buildEvaluator(for: targetBundle.strands[strandIdx].expr)
                    }
                } else if case .param(let field) = indexExpr {
                    if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                        return try buildEvaluator(for: strand.expr)
                    }
                }
            }

            throw BackendError.unsupportedExpression("Cannot resolve bundle \(bundle)")

        case .binaryOp(let op, let left, let right):
            let leftEval = try buildEvaluator(for: left)
            let rightEval = try buildEvaluator(for: right)
            return try buildBinaryOp(op: op, left: leftEval, right: rightEval)

        case .unaryOp(let op, let operand):
            let operandEval = try buildEvaluator(for: operand)
            return try buildUnaryOp(op: op, operand: operandEval)

        case .builtin(let name, let args):
            let argEvals = try args.map { try buildEvaluator(for: $0) }
            return try buildBuiltin(name: name, args: argEvals)

        case .call(let spindle, let args):
            // Inline spindle call
            guard let spindleDef = program.spindles[spindle] else {
                throw BackendError.unsupportedExpression("Unknown spindle: \(spindle)")
            }
            guard !spindleDef.returns.isEmpty else {
                throw BackendError.unsupportedExpression("Spindle \(spindle) has no returns")
            }
            // Build substitution map
            var substitutions: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count {
                    substitutions[param] = args[i]
                }
            }
            // Inline the first return with substitutions
            let inlined = substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            return try buildEvaluator(for: inlined)

        case .extract(let callExpr, let index):
            // Extract specific return value from spindle call
            guard case .call(let spindle, let args) = callExpr else {
                throw BackendError.unsupportedExpression("Extract requires a call expression")
            }
            guard let spindleDef = program.spindles[spindle] else {
                throw BackendError.unsupportedExpression("Unknown spindle: \(spindle)")
            }
            guard index < spindleDef.returns.count else {
                throw BackendError.unsupportedExpression("Extract index \(index) out of bounds")
            }
            // Build substitution map
            var substitutions: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count {
                    substitutions[param] = args[i]
                }
            }
            // Inline the specific return with substitutions
            let inlined = substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            return try buildEvaluator(for: inlined)

        case .remap(let base, let substitutions):
            // Remap applies substitutions to the DIRECT expression of the base bundle,
            // without recursively inlining its dependencies.
            let directExpr = try getDirectExpression(base)
            let remapped = applyRemap(to: directExpr, substitutions: substitutions)
            return try buildEvaluator(for: remapped)

        case .texture:
            // Textures not applicable to audio - return 0
            return { _ in 0.0 }

        case .camera:
            // Camera not applicable to audio - return 0
            return { _ in 0.0 }

        case .microphone(let offset, let channel):
            // Sample from live microphone input
            let offsetEval = try buildEvaluator(for: offset)
            return { [weak self] ctx in
                guard let audioInput = self?.audioInput else { return 0.0 }
                let sampleOffset = Int(offsetEval(ctx))
                return audioInput.getSample(at: ctx.sampleIndex + sampleOffset, channel: channel)
            }
        }
    }

    // Audio input source (set by backend)
    public weak var audioInput: AudioInputSource?

    /// Substitute parameters in an expression
    private func substituteParams(in expr: IRExpr, substitutions: [String: IRExpr]) -> IRExpr {
        switch expr {
        case .num:
            return expr
        case .param(let name):
            return substitutions[name] ?? expr
        case .index(let bundle, let indexExpr):
            if let subst = substitutions[bundle], case .index(let newBundle, _) = subst {
                return .index(bundle: newBundle, indexExpr: substituteParams(in: indexExpr, substitutions: substitutions))
            }
            return .index(bundle: bundle, indexExpr: substituteParams(in: indexExpr, substitutions: substitutions))
        case .binaryOp(let op, let left, let right):
            return .binaryOp(op: op, left: substituteParams(in: left, substitutions: substitutions), right: substituteParams(in: right, substitutions: substitutions))
        case .unaryOp(let op, let operand):
            return .unaryOp(op: op, operand: substituteParams(in: operand, substitutions: substitutions))
        case .call(let spindle, let args):
            return .call(spindle: spindle, args: args.map { substituteParams(in: $0, substitutions: substitutions) })
        case .builtin(let name, let args):
            return .builtin(name: name, args: args.map { substituteParams(in: $0, substitutions: substitutions) })
        case .extract(let call, let index):
            return .extract(call: substituteParams(in: call, substitutions: substitutions), index: index)
        case .remap(let base, let remapSubs):
            var newSubs: [String: IRExpr] = [:]
            for (key, value) in remapSubs { newSubs[key] = substituteParams(in: value, substitutions: substitutions) }
            return .remap(base: substituteParams(in: base, substitutions: substitutions), substitutions: newSubs)
        case .texture(let rid, let u, let v, let ch):
            return .texture(resourceId: rid, u: substituteParams(in: u, substitutions: substitutions), v: substituteParams(in: v, substitutions: substitutions), channel: ch)
        case .camera(let u, let v, let ch):
            return .camera(u: substituteParams(in: u, substitutions: substitutions), v: substituteParams(in: v, substitutions: substitutions), channel: ch)
        case .microphone(let offset, let ch):
            return .microphone(offset: substituteParams(in: offset, substitutions: substitutions), channel: ch)
        }
    }

    /// Get the direct expression for a bundle reference WITHOUT recursively inlining dependencies.
    private func getDirectExpression(_ expr: IRExpr) throws -> IRExpr {
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
            var subs: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count { subs[param] = args[i] }
            }
            return substituteParams(in: spindleDef.returns[index], substitutions: subs)
        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle], !spindleDef.returns.isEmpty else { return expr }
            var subs: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count { subs[param] = args[i] }
            }
            return substituteParams(in: spindleDef.returns[0], substitutions: subs)
        default:
            return expr
        }
    }

    /// Inline bundle references to their actual expressions (at IR level)
    private func inlineExpression(_ expr: IRExpr) throws -> IRExpr {
        switch expr {
        case .num, .param:
            return expr
        case .index(let bundle, let indexExpr):
            if bundle == "me" { return expr }
            if let targetBundle = program.bundles[bundle] {
                if case .num(let idx) = indexExpr {
                    let strandIdx = Int(idx)
                    if strandIdx < targetBundle.strands.count {
                        return try inlineExpression(targetBundle.strands[strandIdx].expr)
                    }
                } else if case .param(let field) = indexExpr {
                    if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                        return try inlineExpression(strand.expr)
                    }
                }
            }
            return expr
        case .binaryOp(let op, let left, let right):
            return .binaryOp(op: op, left: try inlineExpression(left), right: try inlineExpression(right))
        case .unaryOp(let op, let operand):
            return .unaryOp(op: op, operand: try inlineExpression(operand))
        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle], !spindleDef.returns.isEmpty else { return expr }
            var subs: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count { subs[param] = try inlineExpression(args[i]) }
            }
            return try inlineExpression(substituteParams(in: spindleDef.returns[0], substitutions: subs))
        case .builtin(let name, let args):
            return .builtin(name: name, args: try args.map { try inlineExpression($0) })
        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr,
                  let spindleDef = program.spindles[spindle],
                  index < spindleDef.returns.count else { return expr }
            var subs: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count { subs[param] = try inlineExpression(args[i]) }
            }
            return try inlineExpression(substituteParams(in: spindleDef.returns[index], substitutions: subs))
        case .remap(let base, let substitutions):
            let inlinedBase = try inlineExpression(base)
            var inlinedSubs: [String: IRExpr] = [:]
            for (key, value) in substitutions { inlinedSubs[key] = try inlineExpression(value) }
            return applyRemap(to: inlinedBase, substitutions: inlinedSubs)
        case .texture(let rid, let u, let v, let ch):
            return .texture(resourceId: rid, u: try inlineExpression(u), v: try inlineExpression(v), channel: ch)
        case .camera(let u, let v, let ch):
            return .camera(u: try inlineExpression(u), v: try inlineExpression(v), channel: ch)
        case .microphone(let offset, let ch):
            return .microphone(offset: try inlineExpression(offset), channel: ch)
        }
    }

    /// Apply remap substitutions to an expression
    /// Substitution keys are in "bundle.field" format (e.g., "me.x", "foo.x")
    private func applyRemap(to expr: IRExpr, substitutions: [String: IRExpr]) -> IRExpr {
        switch expr {
        case .num:
            return expr
        case .param(let name):
            // Try bare name and me.name format
            if let remapped = substitutions[name] { return remapped }
            if let remapped = substitutions["me.\(name)"] { return remapped }
            return expr
        case .index(let bundle, let indexExpr):
            // Check if this coordinate is being remapped
            // Try multiple key formats since JS uses numeric indices but expressions use field names
            var keysToTry: [String] = []
            if case .param(let field) = indexExpr {
                keysToTry.append("\(bundle).\(field)")
                if bundle == "me" {
                    let meIndices = ["x": 0, "y": 1, "u": 2, "v": 3, "w": 4, "h": 5, "t": 6, "i": 0, "sampleRate": 2]
                    if let idx = meIndices[field] { keysToTry.append("\(bundle).\(idx)") }
                }
            } else if case .num(let idx) = indexExpr {
                keysToTry.append("\(bundle).\(Int(idx))")
            }
            for key in keysToTry {
                if let remapped = substitutions[key] { return remapped }
            }
            return .index(bundle: bundle, indexExpr: applyRemap(to: indexExpr, substitutions: substitutions))
        case .binaryOp(let op, let left, let right):
            return .binaryOp(op: op, left: applyRemap(to: left, substitutions: substitutions), right: applyRemap(to: right, substitutions: substitutions))
        case .unaryOp(let op, let operand):
            return .unaryOp(op: op, operand: applyRemap(to: operand, substitutions: substitutions))
        case .call(let spindle, let args):
            return .call(spindle: spindle, args: args.map { applyRemap(to: $0, substitutions: substitutions) })
        case .builtin(let name, let args):
            return .builtin(name: name, args: args.map { applyRemap(to: $0, substitutions: substitutions) })
        case .extract(let call, let index):
            return .extract(call: applyRemap(to: call, substitutions: substitutions), index: index)
        case .remap(let base, let innerSubs):
            var composed: [String: IRExpr] = [:]
            for (key, value) in innerSubs { composed[key] = applyRemap(to: value, substitutions: substitutions) }
            return .remap(base: applyRemap(to: base, substitutions: substitutions), substitutions: composed)
        case .texture(let rid, let u, let v, let ch):
            return .texture(resourceId: rid, u: applyRemap(to: u, substitutions: substitutions), v: applyRemap(to: v, substitutions: substitutions), channel: ch)
        case .camera(let u, let v, let ch):
            return .camera(u: applyRemap(to: u, substitutions: substitutions), v: applyRemap(to: v, substitutions: substitutions), channel: ch)
        case .microphone(let offset, let ch):
            return .microphone(offset: applyRemap(to: offset, substitutions: substitutions), channel: ch)
        }
    }

    /// Build binary operation evaluator
    private func buildBinaryOp(
        op: String,
        left: @escaping (AudioContext) -> Float,
        right: @escaping (AudioContext) -> Float
    ) throws -> (AudioContext) -> Float {
        switch op {
        case "+": return { ctx in left(ctx) + right(ctx) }
        case "-": return { ctx in left(ctx) - right(ctx) }
        case "*": return { ctx in left(ctx) * right(ctx) }
        case "/": return { ctx in left(ctx) / right(ctx) }
        case "%": return { ctx in fmodf(left(ctx), right(ctx)) }
        case "^": return { ctx in powf(left(ctx), right(ctx)) }
        case "<": return { ctx in left(ctx) < right(ctx) ? 1.0 : 0.0 }
        case ">": return { ctx in left(ctx) > right(ctx) ? 1.0 : 0.0 }
        case "<=": return { ctx in left(ctx) <= right(ctx) ? 1.0 : 0.0 }
        case ">=": return { ctx in left(ctx) >= right(ctx) ? 1.0 : 0.0 }
        case "==": return { ctx in left(ctx) == right(ctx) ? 1.0 : 0.0 }
        case "!=": return { ctx in left(ctx) != right(ctx) ? 1.0 : 0.0 }
        case "&&": return { ctx in (left(ctx) != 0 && right(ctx) != 0) ? 1.0 : 0.0 }
        case "||": return { ctx in (left(ctx) != 0 || right(ctx) != 0) ? 1.0 : 0.0 }
        default:
            throw BackendError.unsupportedExpression("Unknown binary operator: \(op)")
        }
    }

    /// Build unary operation evaluator
    private func buildUnaryOp(
        op: String,
        operand: @escaping (AudioContext) -> Float
    ) throws -> (AudioContext) -> Float {
        switch op {
        case "-": return { ctx in -operand(ctx) }
        case "!": return { ctx in operand(ctx) == 0 ? 1.0 : 0.0 }
        default:
            throw BackendError.unsupportedExpression("Unknown unary operator: \(op)")
        }
    }

    /// Build builtin function evaluator
    private func buildBuiltin(
        name: String,
        args: [(AudioContext) -> Float]
    ) throws -> (AudioContext) -> Float {
        switch name {
        // Math functions
        case "sin": return { ctx in sinf(args[0](ctx)) }
        case "cos": return { ctx in cosf(args[0](ctx)) }
        case "tan": return { ctx in tanf(args[0](ctx)) }
        case "asin": return { ctx in asinf(args[0](ctx)) }
        case "acos": return { ctx in acosf(args[0](ctx)) }
        case "atan": return { ctx in atanf(args[0](ctx)) }
        case "atan2": return { ctx in atan2f(args[0](ctx), args[1](ctx)) }
        case "abs": return { ctx in abs(args[0](ctx)) }
        case "floor": return { ctx in floorf(args[0](ctx)) }
        case "ceil": return { ctx in ceilf(args[0](ctx)) }
        case "round": return { ctx in roundf(args[0](ctx)) }
        case "sqrt": return { ctx in sqrtf(args[0](ctx)) }
        case "pow": return { ctx in powf(args[0](ctx), args[1](ctx)) }
        case "exp": return { ctx in expf(args[0](ctx)) }
        case "log": return { ctx in logf(args[0](ctx)) }
        case "log2": return { ctx in log2f(args[0](ctx)) }

        // Utility functions
        case "min": return { ctx in min(args[0](ctx), args[1](ctx)) }
        case "max": return { ctx in max(args[0](ctx), args[1](ctx)) }
        case "clamp": return { ctx in min(max(args[0](ctx), args[1](ctx)), args[2](ctx)) }
        case "lerp", "mix":
            return { ctx in
                let a = args[0](ctx)
                let b = args[1](ctx)
                let t = args[2](ctx)
                return a + (b - a) * t
            }
        case "step":
            return { ctx in args[1](ctx) < args[0](ctx) ? 0.0 : 1.0 }
        case "smoothstep":
            return { ctx in
                let edge0 = args[0](ctx)
                let edge1 = args[1](ctx)
                let x = args[2](ctx)
                let t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
                return t * t * (3.0 - 2.0 * t)
            }
        case "fract":
            return { ctx in
                let v = args[0](ctx)
                return v - floorf(v)
            }
        case "mod":
            return { ctx in fmodf(args[0](ctx), args[1](ctx)) }
        case "sign":
            return { ctx in
                let v = args[0](ctx)
                if v > 0 { return 1.0 }
                if v < 0 { return -1.0 }
                return 0.0
            }

        // Cache (simplified - just return value for now)
        case "cache":
            return args[0]  // Just pass through value

        // Dynamic bundle selection - short-circuit evaluation
        case "select":
            // select(index, branch0, branch1, ...)
            // Only evaluate the selected branch
            guard args.count >= 2 else {
                return { _ in 0.0 }
            }
            let indexEval = args[0]
            let branches = Array(args.dropFirst())
            return { ctx in
                let idx = Int(indexEval(ctx))
                let clampedIdx = max(0, min(idx, branches.count - 1))
                return branches[clampedIdx](ctx)  // Only selected branch is evaluated
            }

        default:
            throw BackendError.unsupportedExpression("Unknown builtin: \(name)")
        }
    }
}

// MARK: - Audio Context

public struct AudioContext {
    public let sampleIndex: Int
    public let time: Double
    public let sampleRate: Double

    public init(sampleIndex: Int, time: Double, sampleRate: Double) {
        self.sampleIndex = sampleIndex
        self.time = time
        self.sampleRate = sampleRate
    }
}

// MARK: - Audio Render Function Type

public typealias AudioRenderFunction = (Int, Double, Double) -> (Float, Float)

// MARK: - Audio Input Source Protocol

public protocol AudioInputSource: AnyObject {
    /// Get audio sample at given sample index and channel (0 = left, 1 = right)
    func getSample(at sampleIndex: Int, channel: Int) -> Float
}
