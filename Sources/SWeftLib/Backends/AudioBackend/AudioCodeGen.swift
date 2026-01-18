// AudioCodeGen.swift - Generate Swift audio render closures from IR

import Foundation

// MARK: - Audio Code Generator

public class AudioCodeGen {
    private let program: IRProgram
    private let swatch: Swatch

    /// Cache manager for accessing shared buffers
    private weak var cacheManager: CacheManager?

    /// Cache descriptors for audio domain
    private var cacheDescriptors: [CacheNodeDescriptor] = []

    public init(program: IRProgram, swatch: Swatch, cacheManager: CacheManager? = nil) {
        self.program = program
        self.swatch = swatch
        self.cacheManager = cacheManager
        // Filter to only audio domain caches
        self.cacheDescriptors = cacheManager?.getDescriptors(for: .audio) ?? []
    }

    /// Generate audio render function
    /// Returns a closure: (sampleIndex: Int, time: Double, sampleRate: Double) -> (left: Float, right: Float)
    public func generateRenderFunction() throws -> AudioRenderFunction {
        // Get output bundle name from AudioBackend bindings
        let outputBundleName = AudioBackend.bindings.compactMap { binding -> String? in
            if case .output(let output) = binding { return output.bundleName }
            return nil
        }.first

        guard let bundleName = outputBundleName,
              let playBundle = program.bundles[bundleName] else {
            throw BackendError.missingResource("audio output bundle not found")
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
            return try buildBuiltin(name: name, args: args)

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
            let inlined = IRTransformations.substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
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
            let inlined = IRTransformations.substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            return try buildEvaluator(for: inlined)

        case .remap(let base, let substitutions):
            // Remap applies substitutions to the DIRECT expression of the base bundle,
            // without recursively inlining its dependencies.
            let directExpr = IRTransformations.getDirectExpression(base, program: program)
            let remapped = IRTransformations.applyRemap(to: directExpr, substitutions: substitutions)
            return try buildEvaluator(for: remapped)

        case .cacheRead(let cacheId, let tapIndex):
            // Read from cache history buffer (used to break cycles)
            // Find the descriptor for this cacheId
            guard let descriptor = cacheDescriptors.first(where: { $0.id == cacheId }) else {
                // Fallback: return 0 if no descriptor found
                return { _ in 0.0 }
            }
            let manager = self.cacheManager
            let clampedTap = min(tapIndex, descriptor.historySize - 1)
            return { _ in
                guard let mgr = manager else { return 0.0 }
                return mgr.readAudioCache(descriptor: descriptor, tapIndex: clampedTap)
            }
        }
    }

    // Audio input source (set by backend)
    public weak var audioInput: AudioInputSource?

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
        args: [IRExpr]
    ) throws -> (AudioContext) -> Float {
        // Handle cache specially - need to build closure that accesses shared buffer
        if name == "cache" {
            return try buildCacheAccess(args: args)
        }

        // Handle select specially - short-circuit evaluation
        if name == "select" {
            let argEvals = try args.map { try buildEvaluator(for: $0) }
            guard argEvals.count >= 2 else {
                return { _ in 0.0 }
            }
            let indexEval = argEvals[0]
            let branches = Array(argEvals.dropFirst())
            return { ctx in
                let idx = Int(indexEval(ctx))
                let clampedIdx = max(0, min(idx, branches.count - 1))
                return branches[clampedIdx](ctx)
            }
        }

        let argEvals = try args.map { try buildEvaluator(for: $0) }

        switch name {
        // Math functions
        case "sin": return { ctx in sinf(argEvals[0](ctx)) }
        case "cos": return { ctx in cosf(argEvals[0](ctx)) }
        case "tan": return { ctx in tanf(argEvals[0](ctx)) }
        case "asin": return { ctx in asinf(argEvals[0](ctx)) }
        case "acos": return { ctx in acosf(argEvals[0](ctx)) }
        case "atan": return { ctx in atanf(argEvals[0](ctx)) }
        case "atan2": return { ctx in atan2f(argEvals[0](ctx), argEvals[1](ctx)) }
        case "abs": return { ctx in abs(argEvals[0](ctx)) }
        case "floor": return { ctx in floorf(argEvals[0](ctx)) }
        case "ceil": return { ctx in ceilf(argEvals[0](ctx)) }
        case "round": return { ctx in roundf(argEvals[0](ctx)) }
        case "sqrt": return { ctx in sqrtf(argEvals[0](ctx)) }
        case "pow": return { ctx in powf(argEvals[0](ctx), argEvals[1](ctx)) }
        case "exp": return { ctx in expf(argEvals[0](ctx)) }
        case "log": return { ctx in logf(argEvals[0](ctx)) }
        case "log2": return { ctx in log2f(argEvals[0](ctx)) }

        // Utility functions
        case "min": return { ctx in min(argEvals[0](ctx), argEvals[1](ctx)) }
        case "max": return { ctx in max(argEvals[0](ctx), argEvals[1](ctx)) }
        case "clamp": return { ctx in min(max(argEvals[0](ctx), argEvals[1](ctx)), argEvals[2](ctx)) }
        case "lerp", "mix":
            return { ctx in
                let a = argEvals[0](ctx)
                let b = argEvals[1](ctx)
                let t = argEvals[2](ctx)
                return a + (b - a) * t
            }
        case "step":
            return { ctx in argEvals[1](ctx) < argEvals[0](ctx) ? 0.0 : 1.0 }
        case "smoothstep":
            return { ctx in
                let edge0 = argEvals[0](ctx)
                let edge1 = argEvals[1](ctx)
                let x = argEvals[2](ctx)
                let t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
                return t * t * (3.0 - 2.0 * t)
            }
        case "fract":
            return { ctx in
                let v = argEvals[0](ctx)
                return v - floorf(v)
            }
        case "mod":
            return { ctx in fmodf(argEvals[0](ctx), argEvals[1](ctx)) }
        case "sign":
            return { ctx in
                let v = argEvals[0](ctx)
                if v > 0 { return 1.0 }
                if v < 0 { return -1.0 }
                return 0.0
            }

        // Hardware inputs - now handled as builtins
        case "microphone":
            // microphone(offset, channel)
            guard args.count >= 2 else {
                return { _ in 0.0 }
            }
            let offsetEval = argEvals[0]
            // Extract channel as static value from raw args
            let channel: Int
            if case .num(let ch) = args[1] {
                channel = Int(ch)
            } else {
                channel = 0
            }
            return { [weak self] ctx in
                guard let audioInput = self?.audioInput else { return 0.0 }
                let sampleOffset = Int(offsetEval(ctx))
                return audioInput.getSample(at: ctx.sampleIndex + sampleOffset, channel: channel)
            }

        case "camera", "texture":
            // Camera and texture not applicable to audio - return 0
            return { _ in 0.0 }

        default:
            throw BackendError.unsupportedExpression("Unknown builtin: \(name)")
        }
    }

    /// Build cache access closure that uses shared buffer via CacheManager
    private func buildCacheAccess(args: [IRExpr]) throws -> (AudioContext) -> Float {
        // cache(value, history_size, tap_index, signal)
        guard args.count >= 4 else {
            throw BackendError.unsupportedExpression("cache requires 4 arguments")
        }

        // Find matching descriptor by comparing value and signal expressions
        // This is more robust than relying on traversal order
        guard let descriptor = cacheDescriptors.first(where: { desc in
            desc.valueExpr == args[0] && desc.signalExpr == args[3]
        }) else {
            // Fallback: no descriptor available, just return value
            let valueEval = try buildEvaluator(for: args[0])
            return valueEval
        }

        // Build evaluators for value and signal expressions
        let valueEval = try buildEvaluator(for: args[0])
        let signalEval = try buildEvaluator(for: args[3])

        // Capture cache manager and descriptor for closure
        let manager = self.cacheManager

        return { ctx in
            let value = valueEval(ctx)
            let signal = signalEval(ctx)

            // Use CacheManager's tick method for audio caches
            guard let mgr = manager else { return value }
            return mgr.tickAudioCache(descriptor: descriptor, value: value, signal: signal)
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
