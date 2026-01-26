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

    /// Loaded audio samples by resource ID
    public var loadedSamples: [Int: AudioSampleBuffer] = [:]

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

            // Check if this index refers to a cache location - if so, return cache read to break cycle
            let cacheKey: String
            if case .param(let field) = indexExpr {
                cacheKey = "\(bundle).\(field)"
            } else if case .num(let idx) = indexExpr {
                cacheKey = "\(bundle).\(Int(idx))"
            } else {
                cacheKey = ""
            }

            // Look for matching cache descriptor
            if !cacheKey.isEmpty {
                for descriptor in cacheDescriptors {
                    let descKey1 = "\(descriptor.bundleName).\(descriptor.strandIndex)"
                    // Also check by strand name
                    if let targetBundle = program.bundles[descriptor.bundleName],
                       let strand = targetBundle.strands.first(where: { $0.index == descriptor.strandIndex }) {
                        let descKey2 = "\(descriptor.bundleName).\(strand.name)"
                        if cacheKey == descKey1 || cacheKey == descKey2 {
                            // This is a reference to a cache location - return cache read
                            let manager = self.cacheManager
                            let tapIndex = min(descriptor.tapIndex, descriptor.historySize - 1)
                            return { _ in
                                guard let mgr = manager else { return 0.0 }
                                return mgr.readAudioCache(descriptor: descriptor, tapIndex: tapIndex)
                            }
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
            // Build substitutions (params + locals) and inline the return expression
            let substitutions = IRTransformations.buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(in: inlined, substitutions: substitutions)
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
            // Build substitutions (params + locals) and inline the return expression
            let substitutions = IRTransformations.buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(in: inlined, substitutions: substitutions)
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

    // Audio input provider (set by backend via setInputProviders)
    public weak var audioInput: AudioInputProvider?

    /// Build binary operation evaluator (uses shared OperatorRegistry)
    private func buildBinaryOp(
        op: String,
        left: @escaping (AudioContext) -> Float,
        right: @escaping (AudioContext) -> Float
    ) throws -> (AudioContext) -> Float {
        guard let result = OperatorRegistry.audioBinary(op, left: left, right: right) else {
            throw BackendError.unsupportedExpression("Unknown binary operator: \(op)")
        }
        return result
    }

    /// Build unary operation evaluator (uses shared OperatorRegistry)
    private func buildUnaryOp(
        op: String,
        operand: @escaping (AudioContext) -> Float
    ) throws -> (AudioContext) -> Float {
        guard let result = OperatorRegistry.audioUnary(op, operand: operand) else {
            throw BackendError.unsupportedExpression("Unknown unary operator: \(op)")
        }
        return result
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

        // Try shared math builtins first
        if let result = SharedBuiltins.audioMath(name, args: argEvals) {
            return result
        }

        // Noise uses shared implementation
        if name == "noise" {
            let yEval = argEvals.count > 1 ? argEvals[1] : { (_: AudioContext) in Float(0.0) }
            return SharedBuiltins.audioNoise(x: argEvals[0], y: yEval)
        }

        switch name {

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
            // Capture audioInput directly (not through self, since AudioCodeGen is temporary)
            let audioInput = self.audioInput
            return { ctx in
                guard let audioInput = audioInput else { return 0.0 }
                let sampleOffset = Int(offsetEval(ctx))
                return audioInput.getSample(at: ctx.sampleIndex + sampleOffset, channel: channel)
            }

        case "camera", "texture":
            // Camera and texture not applicable to audio - return 0
            return { _ in 0.0 }

        case "sample":
            // sample(resourceId, offset, channel)
            guard args.count >= 3 else {
                return { _ in 0.0 }
            }

            // Get resource ID from first arg (must be static)
            let resourceId: Int
            if case .num(let rid) = args[0] {
                resourceId = Int(rid)
            } else {
                return { _ in 0.0 }
            }

            // Get channel from third arg (must be static)
            let channel: Int
            if case .num(let ch) = args[2] {
                channel = Int(ch)
            } else {
                channel = 0
            }

            let offsetEval = argEvals[1]
            let samples = self.loadedSamples

            return { ctx in
                guard let buffer = samples[resourceId] else { return 0.0 }
                let offset = Int(offsetEval(ctx))
                return buffer.getSample(at: offset, channel: channel)
            }

        // Universal input builtins
        case "mouse":
            // mouse(channel) - returns x, y, or down based on channel
            // channel 0 = x, channel 1 = y, channel 2 = down
            guard args.count >= 1 else {
                return { _ in 0.0 }
            }
            let channel: Int
            if case .num(let ch) = args[0] {
                channel = Int(ch)
            } else {
                // Dynamic channel - evaluate at runtime
                let channelEval = argEvals[0]
                return { ctx in
                    let ch = Int(channelEval(ctx))
                    let state = InputState.shared.getMouseState()
                    switch ch {
                    case 0: return state.x
                    case 1: return state.y
                    case 2: return state.down
                    default: return state.x
                    }
                }
            }
            // Static channel
            return { _ in
                let state = InputState.shared.getMouseState()
                switch channel {
                case 0: return state.x
                case 1: return state.y
                case 2: return state.down
                default: return state.x
                }
            }

        case "key":
            // key(keyCode) - returns 0.0 or 1.0 based on key state
            guard args.count >= 1 else {
                return { _ in 0.0 }
            }
            if case .num(let code) = args[0] {
                // Static key code - most common case
                let keyCode = Int(code)
                return { _ in
                    InputState.shared.getKeyState(keyCode: keyCode)
                }
            }
            // Dynamic key code - evaluate at runtime
            let keyCodeEval = argEvals[0]
            return { ctx in
                let keyCode = Int(keyCodeEval(ctx))
                return InputState.shared.getKeyState(keyCode: keyCode)
            }

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

// MARK: - Audio Input Source Protocol (Deprecated)

/// Deprecated: Use AudioInputProvider instead
/// This typealias exists for backward compatibility
public typealias AudioInputSource = AudioInputProvider
