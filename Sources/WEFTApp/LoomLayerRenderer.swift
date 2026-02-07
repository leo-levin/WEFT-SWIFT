// LoomLayerRenderer.swift - GPU compute shader for evaluating Loom layer expressions

import Metal
import WEFTLib

/// Uniforms passed to Loom evaluation kernel
struct LoomUniforms {
    var time: Float
    var regionMinX: Float
    var regionMinY: Float
    var regionMaxX: Float
    var regionMaxY: Float
    var resolution: UInt32
    var width: Float   // Canvas width for me.w
    var height: Float  // Canvas height for me.h
}

/// Compiles and evaluates a single Loom layer on the GPU
class LoomLayerRenderer {
    let pipeline: MTLComputePipelineState
    let device: MTLDevice
    let outputBuffer: MTLBuffer
    let uniformBuffer: MTLBuffer
    let layerType: LoomLayerSpec.LayerType
    let usesCamera: Bool
    let usedTextureIds: Set<Int>

    /// Maximum resolution supported
    static let maxResolution = 64

    /// Buffer size for max resolution
    private static var maxSampleCount: Int { maxResolution * maxResolution }

    init(layer: LoomLayer, program: IRProgram, device: MTLDevice) throws {
        self.device = device
        self.layerType = layer.type

        // Generate shader source for this layer
        let (shaderSource, usesCamera, textureIds) = try Self.generateShader(
            layer: layer,
            program: program
        )
        self.usesCamera = usesCamera
        self.usedTextureIds = textureIds

        // Debug: print shader source
        #if DEBUG
        print("Loom shader for \(layer.label):")
        print(shaderSource)
        #endif

        // Compile shader
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw LoomRendererError.compilationFailed("Metal compilation error: \(error.localizedDescription)\n\nShader source:\n\(shaderSource)")
        }

        guard let kernelFunction = library.makeFunction(name: "loomEvalKernel") else {
            throw LoomRendererError.compilationFailed("Could not find loomEvalKernel function")
        }

        self.pipeline = try device.makeComputePipelineState(function: kernelFunction)

        // Create output buffer (SIMD2<Float> per sample)
        let bufferSize = Self.maxSampleCount * MemoryLayout<SIMD2<Float>>.stride
        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            throw LoomRendererError.bufferCreationFailed
        }
        self.outputBuffer = buffer

        // Create uniform buffer
        guard let uniforms = device.makeBuffer(length: MemoryLayout<LoomUniforms>.stride, options: .storageModeShared) else {
            throw LoomRendererError.bufferCreationFailed
        }
        self.uniformBuffer = uniforms
    }

    /// Encode evaluation commands to a command buffer
    func encode(
        resolution: Int,
        regionMin: SIMD2<Double>,
        regionMax: SIMD2<Double>,
        time: Double,
        cameraTexture: MTLTexture?,
        loadedTextures: [Int: MTLTexture],
        samplerState: MTLSamplerState?,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        // Update uniforms
        var uniforms = LoomUniforms(
            time: Float(time),
            regionMinX: Float(regionMin.x),
            regionMinY: Float(regionMin.y),
            regionMaxX: Float(regionMax.x),
            regionMaxY: Float(regionMax.y),
            resolution: UInt32(resolution),
            width: 512.0,  // Default canvas size for me.w
            height: 512.0  // Default canvas size for me.h
        )
        uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<LoomUniforms>.stride)

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(outputBuffer, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 1)

        // Bind camera texture if used
        if usesCamera, let camTex = cameraTexture {
            encoder.setTexture(camTex, index: 0)
        }

        // Bind loaded textures
        for textureId in usedTextureIds {
            if let tex = loadedTextures[textureId] {
                encoder.setTexture(tex, index: 1 + textureId)
            }
        }

        // Bind sampler if we have any textures
        if usesCamera || !usedTextureIds.isEmpty {
            if let sampler = samplerState {
                encoder.setSamplerState(sampler, index: 0)
            }
        }

        // Dispatch threads (one per sample)
        let sampleCount = resolution * resolution
        let threadGroupSize = min(64, pipeline.maxTotalThreadsPerThreadgroup)
        let threadGroups = (sampleCount + threadGroupSize - 1) / threadGroupSize

        encoder.dispatchThreadgroups(
            MTLSize(width: threadGroups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadGroupSize, height: 1, depth: 1)
        )

        encoder.endEncoding()
    }

    /// Read results from buffer after command buffer completes
    func readResults(resolution: Int) -> [SIMD2<Double>] {
        let sampleCount = resolution * resolution
        let ptr = outputBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: sampleCount)

        var results: [SIMD2<Double>] = []
        results.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let val = ptr[i]
            results.append(SIMD2<Double>(Double(val.x), Double(val.y)))
        }

        return results
    }

    // MARK: - Shader Generation

    private static func generateShader(
        layer: LoomLayer,
        program: IRProgram
    ) throws -> (String, Bool, Set<Int>) {
        let codegen = LoomCodeGen(program: program)
        return try codegen.generateLoomKernel(layer: layer)
    }
}

// MARK: - LoomCodeGen

/// Generates Metal compute shaders for Loom layer evaluation
class LoomCodeGen {
    private let program: IRProgram

    init(program: IRProgram) {
        self.program = program
    }

    /// Generate a compute kernel for evaluating a Loom layer
    /// Returns: (shaderSource, usesCamera, usedTextureIds)
    func generateLoomKernel(layer: LoomLayer) throws -> (String, Bool, Set<Int>) {
        var usesCamera = false
        var usedTextureIds = Set<Int>()

        // Collect resource usage
        for (_, expr) in layer.strandExprs {
            collectResourceUsage(from: expr, usesCamera: &usesCamera, textureIds: &usedTextureIds)
        }

        // Generate expressions
        let exprs = layer.strandExprs.map { $0.expr }
        let expr0Code = try generateExpression(exprs.count > 0 ? exprs[0] : .num(0))
        let expr1Code: String

        switch layer.type {
        case .plane:
            expr1Code = try generateExpression(exprs.count > 1 ? exprs[1] : .num(0))
        case .axis:
            expr1Code = "0.0"
        }

        // Build texture parameters
        var textureParams = ""
        if usesCamera {
            textureParams += ",\n    texture2d<float, access::sample> cameraTexture [[texture(0)]]"
        }
        for textureId in usedTextureIds.sorted() {
            textureParams += ",\n    texture2d<float, access::sample> texture\(textureId) [[texture(\(1 + textureId))]]"
        }
        if usesCamera || !usedTextureIds.isEmpty {
            textureParams += ",\n    sampler textureSampler [[sampler(0)]]"
        }

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct LoomUniforms {
            float time;
            float regionMinX;
            float regionMinY;
            float regionMaxX;
            float regionMaxY;
            uint resolution;
            float width;
            float height;
        };

        kernel void loomEvalKernel(
            device float2* output [[buffer(0)]],
            constant LoomUniforms& uniforms [[buffer(1)]]\(textureParams),
            uint gid [[thread_position_in_grid]]
        ) {
            uint resolution = uniforms.resolution;
            if (gid >= resolution * resolution) return;

            uint xi = gid % resolution;
            uint yi = gid / resolution;

            float x, y;
            if (resolution <= 1) {
                x = (uniforms.regionMinX + uniforms.regionMaxX) * 0.5;
                y = (uniforms.regionMinY + uniforms.regionMaxY) * 0.5;
            } else {
                x = uniforms.regionMinX + (uniforms.regionMaxX - uniforms.regionMinX) * float(xi) / float(resolution - 1);
                y = uniforms.regionMinY + (uniforms.regionMaxY - uniforms.regionMinY) * float(yi) / float(resolution - 1);
            }

            float t = uniforms.time;
            float w = uniforms.width;
            float h = uniforms.height;

            float value0 = \(expr0Code);
            float value1 = \(expr1Code);

            output[gid] = float2(value0, value1);
        }
        """

        return (shaderSource, usesCamera, usedTextureIds)
    }

    // MARK: - Expression Generation (simplified from MetalCodeGen)

    func generateExpression(_ expr: IRExpr) throws -> String {
        switch expr {
        case .num(let value):
            return formatNumber(value)

        case .param(let name):
            return name

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                if case .param(let field) = indexExpr {
                    return field
                }
                throw LoomRendererError.unsupportedExpression("Dynamic me index")
            }

            // Resolve bundle reference
            if let targetBundle = program.bundles[bundle] {
                if case .num(let idx) = indexExpr {
                    let strandIdx = Int(idx)
                    if strandIdx < targetBundle.strands.count {
                        return try generateExpression(targetBundle.strands[strandIdx].expr)
                    }
                } else if case .param(let field) = indexExpr {
                    if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                        return try generateExpression(strand.expr)
                    }
                }
            }
            throw LoomRendererError.unsupportedExpression("Cannot resolve bundle \(bundle)")

        case .binaryOp(let op, let left, let right):
            let leftCode = try generateExpression(left)
            let rightCode = try generateExpression(right)
            return try generateBinaryOp(op: op, left: leftCode, right: rightCode)

        case .unaryOp(let op, let operand):
            let operandCode = try generateExpression(operand)
            return try generateUnaryOp(op: op, operand: operandCode)

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle],
                  !spindleDef.returns.isEmpty else {
                throw LoomRendererError.unsupportedExpression("Unknown spindle: \(spindle)")
            }
            let substitutions = IRTransformations.buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(in: inlined, substitutions: substitutions)
            return try generateExpression(inlined)

        case .builtin(let name, let args):
            return try generateBuiltin(name: name, args: args)

        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr,
                  let spindleDef = program.spindles[spindle],
                  index < spindleDef.returns.count else {
                throw LoomRendererError.unsupportedExpression("Invalid extract")
            }
            let substitutions = IRTransformations.buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(in: inlined, substitutions: substitutions)
            return try generateExpression(inlined)

        case .remap(let base, let substitutions):
            let directExpr = IRTransformations.getDirectExpression(base, program: program)
            let remapped = IRTransformations.applyRemap(to: directExpr, substitutions: substitutions)
            return try generateExpression(remapped)

        case .cacheRead:
            return "0.0" // Cache not supported in Loom
        }
    }

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
            throw LoomRendererError.unsupportedExpression("Unknown binary operator: \(op)")
        }
    }

    private func generateUnaryOp(op: String, operand: String) throws -> String {
        switch op {
        case "-": return "(-\(operand))"
        case "!": return "(\(operand) == 0.0 ? 1.0 : 0.0)"
        default:
            throw LoomRendererError.unsupportedExpression("Unknown unary operator: \(op)")
        }
    }

    private func generateBuiltin(name: String, args: [IRExpr]) throws -> String {
        // Handle select specially for short-circuit evaluation
        if name == "select" {
            guard args.count >= 2 else {
                throw LoomRendererError.unsupportedExpression("select needs at least index and one branch")
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
                var result = try generateExpression(branches[branches.count - 1])
                for i in stride(from: branches.count - 2, through: 0, by: -1) {
                    let branchCode = try generateExpression(branches[i])
                    result = "((\(indexCode)) < \(Float(i + 1)) ? (\(branchCode)) : (\(result)))"
                }
                return result
            }
        }

        // Handle cache: just return value expression (no history in Loom)
        if name == "cache" && !args.isEmpty {
            return try generateExpression(args[0])
        }

        let argCodes = try args.map { try generateExpression($0) }

        switch name {
        // Math - single arg
        case "sin": return "sin(\(argCodes[0]))"
        case "cos": return "cos(\(argCodes[0]))"
        case "tan": return "tan(\(argCodes[0]))"
        case "asin": return "asin(\(argCodes[0]))"
        case "acos": return "acos(\(argCodes[0]))"
        case "atan": return "atan(\(argCodes[0]))"
        case "abs": return "abs(\(argCodes[0]))"
        case "floor": return "floor(\(argCodes[0]))"
        case "ceil": return "ceil(\(argCodes[0]))"
        case "round": return "round(\(argCodes[0]))"
        case "sqrt": return "sqrt(\(argCodes[0]))"
        case "exp": return "exp(\(argCodes[0]))"
        case "log": return "log(\(argCodes[0]))"
        case "log2": return "log2(\(argCodes[0]))"
        case "sign": return "sign(\(argCodes[0]))"
        case "fract": return "fract(\(argCodes[0]))"

        // Math - two arg
        case "atan2": return "atan2(\(argCodes[0]), \(argCodes[1]))"
        case "pow": return "pow(\(argCodes[0]), \(argCodes[1]))"
        case "mod": return "fmod(\(argCodes[0]), \(argCodes[1]))"
        case "min": return "min(\(argCodes[0]), \(argCodes[1]))"
        case "max": return "max(\(argCodes[0]), \(argCodes[1]))"
        case "step": return "step(\(argCodes[0]), \(argCodes[1]))"

        // Math - three arg
        case "clamp": return "clamp(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"
        case "lerp", "mix": return "mix(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"
        case "smoothstep": return "smoothstep(\(argCodes[0]), \(argCodes[1]), \(argCodes[2]))"

        // Oscillator
        case "osc":
            return "(sin((\(argCodes[0])) * 2.0 * 3.14159265359) * 0.5 + 0.5)"

        // Noise
        case "noise":
            let y = argCodes.count > 1 ? argCodes[1] : "0.0"
            return "fract(sin((\(argCodes[0])) * 12.9898 + (\(y)) * 78.233) * 43758.5453)"

        // Camera
        case "camera":
            guard args.count >= 3 else {
                throw LoomRendererError.unsupportedExpression("camera requires 3 arguments")
            }
            let channelNames = ["r", "g", "b", "a"]
            let channelIdx: Int
            if case .num(let ch) = args[2] {
                channelIdx = Int(ch)
            } else {
                channelIdx = 0
            }
            let channelName = channelIdx < channelNames.count ? channelNames[channelIdx] : "r"
            return "cameraTexture.sample(textureSampler, float2(\(argCodes[0]), \(argCodes[1]))).\(channelName)"

        // Loaded texture
        case "texture":
            guard args.count >= 4 else {
                throw LoomRendererError.unsupportedExpression("texture requires 4 arguments")
            }
            let resourceId: Int
            if case .num(let rid) = args[0] {
                resourceId = Int(rid)
            } else {
                resourceId = 0
            }
            let channelNames = ["r", "g", "b", "a"]
            let channelIdx: Int
            if case .num(let ch) = args[3] {
                channelIdx = Int(ch)
            } else {
                channelIdx = 0
            }
            let channelName = channelIdx < channelNames.count ? channelNames[channelIdx] : "r"
            return "texture\(resourceId).sample(textureSampler, float2(\(argCodes[1]), \(argCodes[2]))).\(channelName)"

        // Hardware builtins not supported in Loom - return 0
        case "microphone", "mouse", "key", "text":
            return "0.0"

        default:
            throw LoomRendererError.unsupportedExpression("Unknown builtin: \(name)")
        }
    }

    private func collectResourceUsage(from expr: IRExpr, usesCamera: inout Bool, textureIds: inout Set<Int>) {
        switch expr {
        case .builtin(let name, let args):
            if name == "camera" {
                usesCamera = true
            } else if name == "texture" {
                if args.count >= 1, case .num(let id) = args[0] {
                    textureIds.insert(Int(id))
                }
            }
            for arg in args {
                collectResourceUsage(from: arg, usesCamera: &usesCamera, textureIds: &textureIds)
            }

        case .binaryOp(_, let left, let right):
            collectResourceUsage(from: left, usesCamera: &usesCamera, textureIds: &textureIds)
            collectResourceUsage(from: right, usesCamera: &usesCamera, textureIds: &textureIds)

        case .unaryOp(_, let operand):
            collectResourceUsage(from: operand, usesCamera: &usesCamera, textureIds: &textureIds)

        case .call(_, let args):
            for arg in args {
                collectResourceUsage(from: arg, usesCamera: &usesCamera, textureIds: &textureIds)
            }

        case .extract(let call, _):
            collectResourceUsage(from: call, usesCamera: &usesCamera, textureIds: &textureIds)

        case .remap(let base, let substitutions):
            collectResourceUsage(from: base, usesCamera: &usesCamera, textureIds: &textureIds)
            for (_, sub) in substitutions {
                collectResourceUsage(from: sub, usesCamera: &usesCamera, textureIds: &textureIds)
            }

        case .index(let bundle, let indexExpr):
            collectResourceUsage(from: indexExpr, usesCamera: &usesCamera, textureIds: &textureIds)
            // Follow bundle references
            if bundle != "me", let targetBundle = program.bundles[bundle] {
                for strand in targetBundle.strands {
                    collectResourceUsage(from: strand.expr, usesCamera: &usesCamera, textureIds: &textureIds)
                }
            }

        case .num, .param, .cacheRead:
            break
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value == Double(Int(value)) {
            return "\(Int(value)).0"
        }
        return String(format: "%.6f", value)
    }
}

// MARK: - Errors

enum LoomRendererError: Error {
    case compilationFailed(String)
    case bufferCreationFailed
    case unsupportedExpression(String)
}
