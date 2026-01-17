// MetalCodeGen.swift - Generate Metal Shading Language from IR

import Foundation

// MARK: - Metal Code Generator

public class MetalCodeGen {
    private let program: IRProgram
    private let swatch: Swatch

    /// Cache descriptors for visual domain (provided by CacheManager)
    private var cacheDescriptors: [CacheNodeDescriptor] = []

    /// Counter for matching cache() calls to descriptors during codegen
    private var cacheNodeCounter: Int = 0

    /// Starting buffer index for cache buffers (after uniforms)
    private let cacheBufferStartIndex: Int = 1

    public init(program: IRProgram, swatch: Swatch, cacheDescriptors: [CacheNodeDescriptor] = []) {
        self.program = program
        self.swatch = swatch
        // Filter to only visual domain caches
        self.cacheDescriptors = cacheDescriptors.filter { $0.domain == .visual }
    }

    /// Generate complete Metal shader source
    public func generate() throws -> String {
        // Reset cache counter for fresh generation
        cacheNodeCounter = 0

        var code = """
        #include <metal_stdlib>
        using namespace metal;

        // Uniforms passed from CPU
        struct Uniforms {
            float time;
            float width;
            float height;
        };

        """

        // Generate compute kernel for display output
        if swatch.bundles.contains("display") {
            code += try generateDisplayKernel()
        }

        return code
    }

    /// Check if program uses camera
    public func usesCamera() -> Bool {
        for (_, bundle) in program.bundles {
            for strand in bundle.strands {
                if strand.expr.usesBuiltin("camera") {
                    return true
                }
            }
        }
        return false
    }

    /// Check if program uses microphone
    public func usesMicrophone() -> Bool {
        for (_, bundle) in program.bundles {
            for strand in bundle.strands {
                if strand.expr.usesBuiltin("microphone") {
                    return true
                }
            }
        }
        return false
    }

    /// Check if program uses cache
    public func usesCache() -> Bool {
        return !cacheDescriptors.isEmpty
    }

    /// Get the number of cache buffer pairs needed
    public func cacheBufferCount() -> Int {
        return cacheDescriptors.count * 2  // history + signal per cache
    }

    /// Generate display compute kernel
    private func generateDisplayKernel() throws -> String {
        guard let displayBundle = program.bundles["display"] else {
            throw BackendError.missingResource("display bundle not found")
        }

        // Reset cache counter before generating expressions
        cacheNodeCounter = 0

        // Collect expressions for each strand (r, g, b)
        var colorExprs: [String] = []
        for strand in displayBundle.strands.sorted(by: { $0.index < $1.index }) {
            let expr = try generateExpression(strand.expr)
            colorExprs.append(expr)
        }

        // Pad to 3 channels if needed
        while colorExprs.count < 3 {
            colorExprs.append("0.0")
        }

        // Check if we need camera or microphone textures
        let needsCamera = usesCamera()
        let needsMicrophone = usesMicrophone()
        let needsSampler = needsCamera || needsMicrophone

        // Build parameter list
        var extraParams = ""
        if needsCamera {
            extraParams += "\n    texture2d<float, access::sample> cameraTexture [[texture(1)]],"
        }
        if needsMicrophone {
            extraParams += "\n    texture2d<float, access::sample> audioBuffer [[texture(2)]],"
        }
        if needsSampler {
            extraParams += "\n    sampler textureSampler [[sampler(0)]],"
        }

        // Add cache buffer parameters
        for (i, descriptor) in cacheDescriptors.enumerated() {
            let historyIdx = cacheBufferStartIndex + i * 2
            let signalIdx = cacheBufferStartIndex + i * 2 + 1
            extraParams += "\n    device float* cache\(i)_history [[buffer(\(historyIdx))]],"
            extraParams += "\n    device float* cache\(i)_signal [[buffer(\(signalIdx))]],"
            _ = descriptor  // Silence unused warning
        }

        // Generate cache helper code if needed
        var cacheHelpers = ""
        if !cacheDescriptors.isEmpty {
            cacheHelpers = """

                // Pixel index for cache buffer access
                uint pixelIndex = gid.y * uint(uniforms.width) + gid.x;

            """
        }

        return """
        kernel void displayKernel(
            texture2d<float, access::write> output [[texture(0)]],\(extraParams)
            constant Uniforms& uniforms [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            float x = float(gid.x) / uniforms.width;
            float y = float(gid.y) / uniforms.height;
            float t = uniforms.time;
            float w = uniforms.width;
            float h = uniforms.height;
        \(cacheHelpers)
            float r = \(colorExprs[0]);
            float g = \(colorExprs[1]);
            float b = \(colorExprs.count > 2 ? colorExprs[2] : "0.0");

            output.write(float4(r, g, b, 1.0), gid);
        }
        """
    }

    /// Generate Metal expression from IR expression
    public func generateExpression(_ expr: IRExpr) throws -> String {
        switch expr {
        case .num(let value):
            return formatNumber(value)

        case .param(let name):
            // Coordinate parameters
            return name

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                // Access coordinate: me.x, me.y, me.t, etc.
                if case .param(let field) = indexExpr {
                    return field
                }
                throw BackendError.unsupportedExpression("Dynamic me index")
            }

            // Access another bundle's strand
            if let targetBundle = program.bundles[bundle] {
                if case .num(let idx) = indexExpr {
                    let strandIdx = Int(idx)
                    if strandIdx < targetBundle.strands.count {
                        return try generateExpression(targetBundle.strands[strandIdx].expr)
                    }
                } else if case .param(let field) = indexExpr {
                    // Named strand access
                    if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                        return try generateExpression(strand.expr)
                    }
                }
            }

            throw BackendError.unsupportedExpression("Cannot resolve bundle \(bundle)")

        case .binaryOp(let op, let left, let right):
            let leftCode = try generateExpression(left)
            let rightCode = try generateExpression(right)
            return try generateBinaryOp(op: op, left: leftCode, right: rightCode)

        case .unaryOp(let op, let operand):
            let operandCode = try generateExpression(operand)
            return try generateUnaryOp(op: op, operand: operandCode)

        case .call(let spindle, let args):
            // Inline spindle call - substitute args for params and return first value
            guard let spindleDef = program.spindles[spindle] else {
                throw BackendError.unsupportedExpression("Unknown spindle: \(spindle)")
            }
            guard !spindleDef.returns.isEmpty else {
                throw BackendError.unsupportedExpression("Spindle \(spindle) has no returns")
            }
            // Build substitution map: param name -> arg expression
            var substitutions: [String: IRExpr] = [:]
            for (i, param) in spindleDef.params.enumerated() {
                if i < args.count {
                    substitutions[param] = args[i]
                }
            }
            // Inline the first return with substitutions
            let inlined = IRTransformations.substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            return try generateExpression(inlined)

        case .builtin(let name, let args):
            return try generateBuiltin(name: name, args: args)

        case .extract(let callExpr, let index):
            // Extract specific return value from spindle call
            guard case .call(let spindle, let args) = callExpr else {
                throw BackendError.unsupportedExpression("Extract requires a call expression")
            }
            guard let spindleDef = program.spindles[spindle] else {
                throw BackendError.unsupportedExpression("Unknown spindle: \(spindle)")
            }
            guard index < spindleDef.returns.count else {
                throw BackendError.unsupportedExpression("Extract index \(index) out of bounds for spindle \(spindle)")
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
            return try generateExpression(inlined)

        case .remap(let base, let substitutions):
            // Remap applies substitutions to the DIRECT expression of the base bundle,
            // without recursively inlining its dependencies.
            // e.g., bar.x(me.y ~ me.y-5) only affects me.y in bar.x's direct expression,
            // not in foo.x if bar.x references foo.x
            let directExpr = IRTransformations.getDirectExpression(base, program: program)
            let remapped = IRTransformations.applyRemap(to: directExpr, substitutions: substitutions)
            return try generateExpression(remapped)
        }
    }

    /// Generate binary operation
    private func generateBinaryOp(op: String, left: String, right: String) throws -> String {
        switch op {
        case "+": return "(\(left) + \(right))"
        case "-": return "(\(left) - \(right))"
        case "*": return "(\(left) * \(right))"
        case "/": return "(\(left) / \(right))"
        case "%": return "fmod(\(left), \(right))"
        case "^": return "pow(\(left), \(right))"
        case "<": return "(\(left) < \(right) ? 1.0 : 0.0)"
        case ">": return "(\(left) > \(right) ? 1.0 : 0.0)"
        case "<=": return "(\(left) <= \(right) ? 1.0 : 0.0)"
        case ">=": return "(\(left) >= \(right) ? 1.0 : 0.0)"
        case "==": return "(\(left) == \(right) ? 1.0 : 0.0)"
        case "!=": return "(\(left) != \(right) ? 1.0 : 0.0)"
        case "&&": return "((\(left) != 0.0 && \(right) != 0.0) ? 1.0 : 0.0)"
        case "||": return "((\(left) != 0.0 || \(right) != 0.0) ? 1.0 : 0.0)"
        default:
            throw BackendError.unsupportedExpression("Unknown binary operator: \(op)")
        }
    }

    /// Generate unary operation
    private func generateUnaryOp(op: String, operand: String) throws -> String {
        switch op {
        case "-": return "(-\(operand))"
        case "!": return "(\(operand) == 0.0 ? 1.0 : 0.0)"
        default:
            throw BackendError.unsupportedExpression("Unknown unary operator: \(op)")
        }
    }

    /// Generate builtin function call
    private func generateBuiltin(name: String, args: [IRExpr]) throws -> String {
        // Handle select specially - we need short-circuit evaluation
        if name == "select" {
            // select(index, branch0, branch1, ...)
            // Generate nested ternary: (idx < 1 ? b0 : (idx < 2 ? b1 : b2))
            guard args.count >= 2 else {
                throw BackendError.unsupportedExpression("select needs at least index and one branch")
            }
            let indexCode = try generateExpression(args[0])
            let branches = Array(args.dropFirst())

            if branches.count == 1 {
                return try generateExpression(branches[0])
            } else if branches.count == 2 {
                let b0 = try generateExpression(branches[0])
                let b1 = try generateExpression(branches[1])
                return "((\(indexCode)) != 0.0 ? (\(b1)) : (\(b0)))"
            } else {
                // Build nested ternary from right to left
                var result = try generateExpression(branches[branches.count - 1])
                for i in stride(from: branches.count - 2, through: 0, by: -1) {
                    let branchCode = try generateExpression(branches[i])
                    result = "((\(indexCode)) < \(Float(i + 1)) ? (\(branchCode)) : (\(result)))"
                }
                return result
            }
        }

        // Handle cache specially - need to generate inline tick logic
        if name == "cache" {
            return try generateCacheAccess(args: args)
        }

        let argCodes = try args.map { try generateExpression($0) }

        switch name {
        // Math functions
        case "sin": return "sin(\(argCodes[0]))"
        case "cos": return "cos(\(argCodes[0]))"
        case "tan": return "tan(\(argCodes[0]))"
        case "asin": return "asin(\(argCodes[0]))"
        case "acos": return "acos(\(argCodes[0]))"
        case "atan": return "atan(\(argCodes[0]))"
        case "atan2": return "atan2(\(argCodes[0]), \(argCodes[1]))"
        case "abs": return "abs(\(argCodes[0]))"
        case "floor": return "floor(\(argCodes[0]))"
        case "ceil": return "ceil(\(argCodes[0]))"
        case "round": return "round(\(argCodes[0]))"
        case "sqrt": return "sqrt(\(argCodes[0]))"
        case "pow": return "pow(\(argCodes[0]), \(argCodes[1]))"
        case "exp": return "exp(\(argCodes[0]))"
        case "log": return "log(\(argCodes[0]))"
        case "log2": return "log2(\(argCodes[0]))"

        // Utility functions
        case "min": return "min(\(argCodes[0]), \(argCodes[1]))"
        case "max": return "max(\(argCodes[0]), \(argCodes[1]))"
        case "clamp": return "clamp(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"
        case "lerp", "mix": return "mix(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"
        case "step": return "step(\(argCodes[0]), \(argCodes[1]))"
        case "smoothstep": return "smoothstep(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"
        case "fract": return "fract(\(argCodes[0]))"
        case "mod": return "fmod(\(argCodes[0]), \(argCodes[1]))"
        case "sign": return "sign(\(argCodes[0]))"

        // Noise (simplified - would need actual implementation)
        case "noise": return "fract(sin(dot(float2(\(argCodes[0]), \(argCodes.count > 1 ? argCodes[1] : "0.0")), float2(12.9898, 78.233))) * 43758.5453)"

        // Hardware inputs - now handled as builtins
        case "camera":
            // camera(u, v, channel)
            guard args.count >= 3 else {
                throw BackendError.unsupportedExpression("camera requires 3 arguments: u, v, channel")
            }
            let uCode = argCodes[0]
            let vCode = argCodes[1]
            let channel = args[2]
            let channelNames = ["r", "g", "b", "a"]
            let channelIdx: Int
            if case .num(let ch) = channel {
                channelIdx = Int(ch)
            } else {
                channelIdx = 0
            }
            let channelName = channelIdx < channelNames.count ? channelNames[channelIdx] : "r"
            return "cameraTexture.sample(textureSampler, float2(\(uCode), \(vCode))).\(channelName)"

        case "texture":
            // texture(resourceId, u, v, channel)
            guard args.count >= 4 else {
                throw BackendError.unsupportedExpression("texture requires 4 arguments: resourceId, u, v, channel")
            }
            let resourceId: Int
            if case .num(let rid) = args[0] {
                resourceId = Int(rid)
            } else {
                resourceId = 0
            }
            let uCode = argCodes[1]
            let vCode = argCodes[2]
            let channel = args[3]
            let texChannelNames = ["r", "g", "b", "a"]
            let texChannelIdx: Int
            if case .num(let ch) = channel {
                texChannelIdx = Int(ch)
            } else {
                texChannelIdx = 0
            }
            let texChannelName = texChannelIdx < texChannelNames.count ? texChannelNames[texChannelIdx] : "r"
            return "texture\(resourceId).sample(textureSampler, float2(\(uCode), \(vCode))).\(texChannelName)"

        case "microphone":
            // microphone(offset, channel)
            guard args.count >= 2 else {
                throw BackendError.unsupportedExpression("microphone requires 2 arguments: offset, channel")
            }
            let offsetCode = argCodes[0]
            let channel = args[1]
            let micChannelName: String
            if case .num(let ch) = channel {
                micChannelName = Int(ch) == 0 ? "r" : "g"
            } else {
                micChannelName = "r"
            }
            return "audioBuffer.sample(textureSampler, float2(\(offsetCode), 0.5)).\(micChannelName)"

        default:
            throw BackendError.unsupportedExpression("Unknown builtin: \(name)")
        }
    }

    /// Generate cache access code with tick logic
    private func generateCacheAccess(args: [IRExpr]) throws -> String {
        // cache(value, history_size, tap_index, signal)
        guard args.count >= 4 else {
            throw BackendError.unsupportedExpression("cache requires 4 arguments")
        }

        // Get the descriptor for this cache node
        let cacheIndex = cacheNodeCounter
        cacheNodeCounter += 1

        guard cacheIndex < cacheDescriptors.count else {
            // Fallback: no descriptor available, just return value
            return try generateExpression(args[0])
        }

        let descriptor = cacheDescriptors[cacheIndex]

        // Generate code for value and signal expressions
        let valueCode = try generateExpression(args[0])
        let signalCode = try generateExpression(args[3])

        let historySize = descriptor.historySize
        let tapIndex = min(descriptor.tapIndex, historySize - 1)

        // Generate inline cache tick logic using IIFE pattern for expression context
        // This creates a lambda that is immediately invoked
        return """
        [&]() -> float {
                float cacheValue = \(valueCode);
                float cacheSignal = \(signalCode);
                uint historyBase = pixelIndex * \(historySize);

                float prevSignal = cache\(cacheIndex)_signal[pixelIndex];
                bool shouldTick = isnan(prevSignal) || prevSignal != cacheSignal;

                if (shouldTick) {
                    cache\(cacheIndex)_signal[pixelIndex] = cacheSignal;
                    // Shift history (newest at index 0)
                    for (int i = \(historySize - 1); i > 0; i--) {
                        cache\(cacheIndex)_history[historyBase + i] = cache\(cacheIndex)_history[historyBase + i - 1];
                    }
                    cache\(cacheIndex)_history[historyBase] = cacheValue;
                }

                return cache\(cacheIndex)_history[historyBase + \(tapIndex)];
            }()
        """
    }

    /// Format a number for Metal code
    private func formatNumber(_ value: Double) -> String {
        if value == Double(Int(value)) {
            return "\(Int(value)).0"
        }
        return String(format: "%.6f", value)
    }
}
