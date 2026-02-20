// MetalBackend.swift - Metal rendering backend

import Foundation
import Metal
import MetalKit

// MARK: - Metal Compiled Unit

public class MetalCompiledUnit: CompiledUnit {
    public let swatchId: UUID
    public let pipelineState: MTLComputePipelineState
    public let shaderSource: String
    public let usedInputs: Set<String>
    public let usedTextureIds: Set<Int>
    public let usedTextIds: Set<Int>
    public let crossDomainSlotCount: Int
    public let crossDomainSlotMap: [String: Int]

    /// Intermediate pipeline states for heavy remap textures
    public let intermediatePipelines: [MTLComputePipelineState]

    /// Number of intermediate textures needed
    public let intermediateCount: Int

    /// Number of scope textures for layout previews
    public let scopeTextureCount: Int

    /// Bundle names corresponding to each scope texture
    public let scopedBundleNames: [String]

    /// Probe buffer: maps "bundle.strand" to index in probe float buffer
    public let probeSlotMap: [String: Int]

    /// Total number of probe float slots
    public let probeSlotCount: Int

    /// Metal buffer index for cross-domain data (computed dynamically from cache count)
    public let crossDomainBufferIndex: Int

    public init(swatchId: UUID, pipelineState: MTLComputePipelineState, shaderSource: String, usedInputs: Set<String> = [], usedTextureIds: Set<Int> = [], usedTextIds: Set<Int> = [], crossDomainSlotCount: Int = 0, crossDomainSlotMap: [String: Int] = [:], intermediatePipelines: [MTLComputePipelineState] = [], intermediateCount: Int = 0, scopeTextureCount: Int = 0, scopedBundleNames: [String] = [], probeSlotMap: [String: Int] = [:], probeSlotCount: Int = 0, crossDomainBufferIndex: Int = 3) {
        self.swatchId = swatchId
        self.pipelineState = pipelineState
        self.shaderSource = shaderSource
        self.usedInputs = usedInputs
        self.usedTextureIds = usedTextureIds
        self.usedTextIds = usedTextIds
        self.crossDomainSlotCount = crossDomainSlotCount
        self.crossDomainSlotMap = crossDomainSlotMap
        self.intermediatePipelines = intermediatePipelines
        self.intermediateCount = intermediateCount
        self.scopeTextureCount = scopeTextureCount
        self.scopedBundleNames = scopedBundleNames
        self.probeSlotMap = probeSlotMap
        self.probeSlotCount = probeSlotCount
        self.crossDomainBufferIndex = crossDomainBufferIndex
    }
}

// MARK: - Metal Uniforms

public struct MetalUniforms {
    var time: Float
    var width: Float
    var height: Float
    var mouseX: Float
    var mouseY: Float
    var mouseDown: Float
    var probeX: Float = 0
    var probeY: Float = 0
}

// MARK: - Metal Backend

public class MetalBackend: Backend {
    public static let identifier = "visual"
    public static let hardwareOwned: Set<IRHardware> = [.camera, .gpu]
    public static let ownedBuiltins: Set<String> = ["camera", "texture", "load", "text"]
    public static let externalBuiltins: Set<String> = ["camera", "texture"]
    public static let statefulBuiltins: Set<String> = ["cache", "camera", "mouse"]
    public static let coordinateFields = ["x", "y", "t", "w", "h"]

    // MARK: - Domain Annotation Specs

    /// Coordinate dimensions for visual domain
    public static let coordinateSpecs: [String: IRDimension] = [
        "x": IRDimension(name: "x", access: .free),
        "y": IRDimension(name: "y", access: .free),
        "t": IRDimension(name: "t", access: .bound),
        "w": IRDimension(name: "w", access: .bound),
        "h": IRDimension(name: "h", access: .bound),
    ]

    /// Primitive specifications for visual domain builtins
    public static let primitiveSpecs: [String: PrimitiveSpec] = [
        "camera": PrimitiveSpec(
            name: "camera",
            outputDomain: [
                IRDimension(name: "x", access: .free),
                IRDimension(name: "y", access: .free),
                IRDimension(name: "t", access: .bound)
            ],
            hardwareRequired: [.camera],
            addsState: false
        ),
        "mouse": PrimitiveSpec(
            name: "mouse",
            outputDomain: [IRDimension(name: "t", access: .bound)],
            hardwareRequired: [],
            addsState: false
        ),
        "texture": PrimitiveSpec(
            name: "texture",
            outputDomain: [
                IRDimension(name: "x", access: .free),
                IRDimension(name: "y", access: .free)
            ],
            hardwareRequired: [.gpu],
            addsState: false
        ),
        "cache": PrimitiveSpec(
            name: "cache",
            outputDomain: [],
            hardwareRequired: [],
            addsState: true
        ),
        "text": PrimitiveSpec(
            name: "text",
            outputDomain: [
                IRDimension(name: "x", access: .free),
                IRDimension(name: "y", access: .free)
            ],
            hardwareRequired: [.gpu],
            addsState: false
        ),
    ]

    public static let bindings: [BackendBinding] = [
        // Inputs
        .input(InputBinding(
            builtinName: "camera",
            shaderParam: "texture2d<float, access::sample> cameraTexture [[texture(1)]]",
            textureIndex: 1
        )),
        .input(InputBinding(
            builtinName: "microphone",
            shaderParam: "texture2d<float, access::sample> audioBuffer [[texture(2)]]",
            textureIndex: 2
        )),
        .input(InputBinding(
            builtinName: "texture",
            shaderParam: nil,  // Dynamic: texture{N} [[texture(3+N)]]
            textureIndex: 3    // Base index
        )),
        .input(InputBinding(
            builtinName: "cache",
            shaderParam: nil,  // Dynamic: cache buffers added by codegen
            textureIndex: nil  // Uses buffer bindings, not textures
        )),
        // Output
        .output(OutputBinding(
            bundleName: "display",
            kernelName: "displayKernel"
        ))
    ]

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private var outputTexture: MTLTexture?
    private var uniformBuffer: MTLBuffer?
    private var keyStateBuffer: MTLBuffer?
    private var samplerState: MTLSamplerState?
    public var width: Int = 512
    public var height: Int = 512

    /// Input providers set via setInputProviders
    private var inputProviders: [String: any InputProvider] = [:]

    /// Camera texture - deprecated, now accessed via provider
    /// Still used by CameraCaptureDelegate callback for backward compatibility
    public var cameraTexture: MTLTexture?

    /// Audio buffer texture - for microphone/audio reactive visuals
    public var audioBufferTexture: MTLTexture?

    /// Loaded textures by resource ID - set by TextureManager via Coordinator
    public var loadedTextures: [Int: MTLTexture] = [:]

    /// Text textures by resource ID - set by TextManager via Coordinator
    public var textTextures: [Int: MTLTexture] = [:]

    /// Cross-domain data buffer for passing audio values to shader
    private var crossDomainMTLBuffer: MTLBuffer?

    /// Cross-domain data to copy into the Metal buffer before each render
    public var crossDomainData: [Float] = []

    /// Intermediate textures for heavy remap expressions (r32Float)
    private var intermediateTextures: [MTLTexture] = []

    /// Scope textures for layout preview (rgba8Unorm, shared storage for CPU readback)
    private var scopeTextures: [MTLTexture] = []

    /// Probe buffer for signal tinting (storageModeShared for CPU readback)
    private var probeBuffer: MTLBuffer?

    /// Current probe slot map from compiled unit
    private var probeSlotMap: [String: Int] = [:]

    /// Current probe slot count
    private var probeSlotCount: Int = 0

    /// Last command buffer -- used to sync before CPU readback of scope textures
    private var lastCommandBuffer: MTLCommandBuffer?

    /// Shader source cache -- skip Metal compilation when shader hasn't changed
    private var cachedShaderSource: String?
    private var cachedLibrary: MTLLibrary?
    private var cachedPipelineState: MTLComputePipelineState?
    private var cachedIntermediatePipelines: [MTLComputePipelineState] = []

    /// Current time (set at top of render, read by scalar cache evaluator closures)
    private var currentTime: Double = 0

    /// Compiled CPU evaluators for scalar visual caches (built once per compile, called each frame)
    private var scalarCacheTickers: [(
        descriptor: CacheNodeDescriptor,
        value: () -> Float,
        signal: () -> Float
    )] = []

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BackendError.deviceNotAvailable("Metal device not available")
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw BackendError.deviceNotAvailable("Could not create command queue")
        }
        self.commandQueue = queue

        // Create uniform buffer
        self.uniformBuffer = device.makeBuffer(length: MemoryLayout<MetalUniforms>.stride, options: .storageModeShared)

        // Create key state buffer (256 floats for key states)
        self.keyStateBuffer = device.makeBuffer(length: 256 * MemoryLayout<Float>.stride, options: .storageModeShared)

        // Create sampler state for texture sampling
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        self.samplerState = device.makeSamplerState(descriptor: samplerDescriptor)
    }

    // MARK: - Input Provider Management

    public func setInputProviders(_ providers: [String: any InputProvider]) {
        self.inputProviders = providers
    }

    /// Get camera texture from provider or legacy property
    private func getCameraTexture() -> MTLTexture? {
        // Try to get from provider first
        if let camProvider = inputProviders["camera"] as? VisualInputProvider {
            return camProvider.texture
        }
        // Fallback to legacy direct property for backward compatibility
        return cameraTexture
    }

    /// Set output dimensions
    public func setOutputSize(width: Int, height: Int) {
        self.width = width
        self.height = height
        createOutputTexture()
    }

    /// Create output texture
    private func createOutputTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared

        outputTexture = device.makeTexture(descriptor: descriptor)
    }

    /// Compile swatch to Metal pipeline (without cache support)
    public func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit {
        return try compile(swatch: swatch, ir: ir, cacheDescriptors: [])
    }

    /// Compile swatch to Metal pipeline with cache descriptors, cross-domain inputs, and scope bundles
    public func compile(swatch: Swatch, ir: IRProgram, cacheDescriptors: [CacheNodeDescriptor], crossDomainInputs: [String: [String]] = [:], scopedBundles: [String] = []) throws -> CompiledUnit {
        let codegen = MetalCodeGen(program: ir, swatch: swatch, cacheDescriptors: cacheDescriptors, crossDomainInputs: crossDomainInputs, scopedBundles: scopedBundles)
        let shaderSource = try codegen.generate()
        var usedInputs = codegen.usedInputs()
        let usedTextureIds = codegen.usedTextureIds()
        let usedTextIds = codegen.usedTextIds()

        // Add "cache" to usedInputs if there are cache descriptors
        if codegen.usesCache() {
            usedInputs.insert("cache")
        }

        // Add "texture" to usedInputs if textures are used
        if !usedTextureIds.isEmpty {
            usedInputs.insert("texture")
        }

        // Add "text" to usedInputs if text is used
        if !usedTextIds.isEmpty {
            usedInputs.insert("text")
        }

        // Check shader cache -- skip Metal compilation if shader source hasn't changed
        let cacheHit = shaderSource == cachedShaderSource
            && cachedLibrary != nil
            && cachedPipelineState != nil

        let library: MTLLibrary
        let pipelineState: MTLComputePipelineState
        var intermediatePipelines: [MTLComputePipelineState]

        if cacheHit {
            library = cachedLibrary!
            pipelineState = cachedPipelineState!
            intermediatePipelines = cachedIntermediatePipelines
        } else {
            // Compile shader
            do {
                library = try device.makeLibrary(source: shaderSource, options: nil)
            } catch {
                throw BackendError.compilationFailed("Metal compilation error: \(error.localizedDescription)")
            }

            guard let kernelFunction = library.makeFunction(name: "displayKernel") else {
                throw BackendError.compilationFailed("Could not find displayKernel function")
            }

            do {
                pipelineState = try device.makeComputePipelineState(function: kernelFunction)
            } catch {
                throw BackendError.compilationFailed("Could not create pipeline state: \(error.localizedDescription)")
            }

            // Build intermediate pipelines for heavy remap textures
            intermediatePipelines = []
            for i in 0..<codegen.intermediateTextureCount {
                guard let fn = library.makeFunction(name: "intermediateKernel\(i)") else {
                    throw BackendError.compilationFailed("Could not find intermediateKernel\(i)")
                }
                intermediatePipelines.append(try device.makeComputePipelineState(function: fn))
            }

            // Update cache
            cachedShaderSource = shaderSource
            cachedLibrary = library
            cachedPipelineState = pipelineState
            cachedIntermediatePipelines = intermediatePipelines
        }

        return MetalCompiledUnit(
            swatchId: swatch.id,
            pipelineState: pipelineState,
            shaderSource: shaderSource,
            usedInputs: usedInputs,
            usedTextureIds: usedTextureIds,
            usedTextIds: usedTextIds,
            crossDomainSlotCount: codegen.crossDomainSlotCount,
            crossDomainSlotMap: codegen.crossDomainSlotMap,
            intermediatePipelines: intermediatePipelines,
            intermediateCount: codegen.intermediateTextureCount,
            scopeTextureCount: codegen.scopeTextureCount,
            scopedBundleNames: codegen.scopedBundleNames,
            probeSlotMap: codegen.probeSlotMap,
            probeSlotCount: codegen.probeSlotCount,
            crossDomainBufferIndex: codegen.crossDomainBufferIndex
        )
    }

    /// Execute compiled unit
    public func execute(
        unit: CompiledUnit,
        inputs: [String: any Buffer],
        outputs: [String: any Buffer],
        time: Double
    ) {
        guard let metalUnit = unit as? MetalCompiledUnit else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Ensure output texture exists
        if outputTexture == nil {
            createOutputTexture()
        }
        guard let texture = outputTexture else { return }

        // Get current input state
        let mouseState = InputState.shared.getMouseState()

        // Update uniforms including input state
        var uniforms = MetalUniforms(
            time: Float(time),
            width: Float(width),
            height: Float(height),
            mouseX: mouseState.x,
            mouseY: mouseState.y,
            mouseDown: mouseState.down
        )
        uniformBuffer?.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<MetalUniforms>.stride)

        // Update key state buffer
        if let keyBuffer = keyStateBuffer {
            InputState.shared.copyKeyStates(to: keyBuffer.contents().assumingMemoryBound(to: Float.self))
        }

        // Prepare cross-domain data buffer if needed
        if metalUnit.crossDomainSlotCount > 0 {
            let byteCount = max(metalUnit.crossDomainSlotCount, 1) * MemoryLayout<Float>.stride
            if crossDomainMTLBuffer == nil || crossDomainMTLBuffer!.length < byteCount {
                crossDomainMTLBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
            }
            if let buf = crossDomainMTLBuffer, !crossDomainData.isEmpty {
                let copyCount = min(crossDomainData.count, metalUnit.crossDomainSlotCount)
                crossDomainData.withUnsafeBufferPointer { ptr in
                    buf.contents().copyMemory(from: ptr.baseAddress!, byteCount: copyCount * MemoryLayout<Float>.stride)
                }
            }
        }

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        // Intermediate kernel passes
        if metalUnit.intermediateCount > 0 {
            ensureIntermediateTextures(count: metalUnit.intermediateCount, width: width, height: height)

            for (i, pipeline) in metalUnit.intermediatePipelines.enumerated() {
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(intermediateTextures[i], index: 0)
                encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
                bindSharedResources(encoder: encoder, metalUnit: metalUnit, cacheManager: nil)
                // Bind prior intermediate textures for chained heavy remaps
                for priorIdx in 0..<i {
                    encoder.setTexture(intermediateTextures[priorIdx], index: MetalCodeGen.intermediateTextureBaseIndex + priorIdx)
                }
                encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
            }
        }

        // Display kernel pass
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        computeEncoder.setComputePipelineState(metalUnit.pipelineState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
        bindSharedResources(encoder: computeEncoder, metalUnit: metalUnit, cacheManager: nil)

        // Bind intermediate textures
        for (i, tex) in intermediateTextures.prefix(metalUnit.intermediateCount).enumerated() {
            computeEncoder.setTexture(tex, index: MetalCodeGen.intermediateTextureBaseIndex + i)
        }

        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Get current output texture
    public func getOutputTexture() -> MTLTexture? {
        return outputTexture
    }

    /// Render to a drawable (for MTKView) - without cache support
    public func render(
        unit: CompiledUnit,
        to drawable: CAMetalDrawable,
        time: Double
    ) {
        render(unit: unit, to: drawable, time: time, cacheManager: nil)
    }

    /// Render to a drawable (for MTKView) with cache buffer binding
    public func render(
        unit: CompiledUnit,
        to drawable: CAMetalDrawable,
        time: Double,
        cacheManager: CacheManager?
    ) {
        guard let metalUnit = unit as? MetalCompiledUnit else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        self.currentTime = time

        let texture = drawable.texture

        // Tick scalar visual caches on CPU before GPU dispatch
        if let cacheManager = cacheManager {
            tickScalarCaches(cacheManager: cacheManager)
        }

        // Get current input state
        let mouseState = InputState.shared.getMouseState()

        // Use mouse position as probe coordinate when mouse is over the canvas
        let probeActive = InputState.shared.mouseOverCanvas
        let probeX: Float = probeActive ? mouseState.x : -1.0
        let probeY: Float = probeActive ? (1.0 - mouseState.y) : -1.0

        // Update uniforms including input state and probe coordinates
        var uniforms = MetalUniforms(
            time: Float(time),
            width: Float(texture.width),
            height: Float(texture.height),
            mouseX: mouseState.x,
            mouseY: mouseState.y,
            mouseDown: mouseState.down,
            probeX: probeX,
            probeY: probeY
        )
        uniformBuffer?.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<MetalUniforms>.stride)

        // Ensure probe buffer exists with correct size
        if metalUnit.probeSlotCount > 0 {
            let neededSize = metalUnit.probeSlotCount * MemoryLayout<Float>.stride
            if probeBuffer == nil || probeBuffer!.length < neededSize {
                probeBuffer = device.makeBuffer(length: neededSize, options: .storageModeShared)
            }
            probeSlotMap = metalUnit.probeSlotMap
            probeSlotCount = metalUnit.probeSlotCount
        }

        // Update key state buffer
        if let keyBuffer = keyStateBuffer {
            InputState.shared.copyKeyStates(to: keyBuffer.contents().assumingMemoryBound(to: Float.self))
        }

        // Prepare cross-domain data buffer if needed
        if metalUnit.crossDomainSlotCount > 0 {
            let byteCount = max(metalUnit.crossDomainSlotCount, 1) * MemoryLayout<Float>.stride
            if crossDomainMTLBuffer == nil || crossDomainMTLBuffer!.length < byteCount {
                crossDomainMTLBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
            }
            if let buf = crossDomainMTLBuffer, !crossDomainData.isEmpty {
                let copyCount = min(crossDomainData.count, metalUnit.crossDomainSlotCount)
                crossDomainData.withUnsafeBufferPointer { ptr in
                    buf.contents().copyMemory(from: ptr.baseAddress!, byteCount: copyCount * MemoryLayout<Float>.stride)
                }
            }
        }

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (texture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (texture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        // --- Intermediate kernel passes (heavy remap expressions) ---
        if metalUnit.intermediateCount > 0 {
            ensureIntermediateTextures(count: metalUnit.intermediateCount, width: texture.width, height: texture.height)

            for (i, pipeline) in metalUnit.intermediatePipelines.enumerated() {
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(intermediateTextures[i], index: 0)
                encoder.setBuffer(uniformBuffer, offset: 0, index: 0)
                bindSharedResources(encoder: encoder, metalUnit: metalUnit, cacheManager: cacheManager)
                // Bind prior intermediate textures for chained heavy remaps
                for priorIdx in 0..<i {
                    encoder.setTexture(intermediateTextures[priorIdx], index: MetalCodeGen.intermediateTextureBaseIndex + priorIdx)
                }
                encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
            }
        }

        // --- Display kernel pass ---
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        computeEncoder.setComputePipelineState(metalUnit.pipelineState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
        bindSharedResources(encoder: computeEncoder, metalUnit: metalUnit, cacheManager: cacheManager)

        // Bind intermediate textures for display kernel to sample from
        for (i, tex) in intermediateTextures.prefix(metalUnit.intermediateCount).enumerated() {
            computeEncoder.setTexture(tex, index: MetalCodeGen.intermediateTextureBaseIndex + i)
        }

        // Bind scope textures for layout preview writes
        if metalUnit.scopeTextureCount > 0 {
            ensureScopeTextures(count: metalUnit.scopeTextureCount, width: texture.width, height: texture.height)
            for (i, tex) in scopeTextures.prefix(metalUnit.scopeTextureCount).enumerated() {
                computeEncoder.setTexture(tex, index: MetalCodeGen.scopeTextureBaseIndex + i)
            }
        }

        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
    }

    /// Wait for the most recent render to complete (call before CPU readback of scope textures)
    public func waitForLastRender() {
        lastCommandBuffer?.waitUntilCompleted()
        lastCommandBuffer = nil
    }

    // MARK: - Scalar Cache CPU Ticking

    /// Build CPU evaluator closures for scalar visual caches.
    /// Called once per compile. The closures capture `self` weakly for time/dimensions
    /// and read mouse/key state from InputState.shared.
    public func buildScalarCacheEvaluators(
        descriptors: [CacheNodeDescriptor],
        program: IRProgram,
        cacheManager: CacheManager
    ) {
        scalarCacheTickers = descriptors
            .filter { $0.backendId == MetalBackend.identifier && $0.storage == .scalar }
            .map { descriptor in
                let valueEval = buildUniformEvaluator(
                    expr: descriptor.valueExpr,
                    program: program,
                    cacheManager: cacheManager,
                    descriptors: descriptors
                )
                let signalEval = buildUniformEvaluator(
                    expr: descriptor.signalExpr,
                    program: program,
                    cacheManager: cacheManager,
                    descriptors: descriptors
                )
                return (descriptor: descriptor, value: valueEval, signal: signalEval)
            }
    }

    /// Tick all scalar visual caches on the CPU. Called before each GPU dispatch.
    public func tickScalarCaches(cacheManager: CacheManager) {
        for ticker in scalarCacheTickers {
            _ = cacheManager.tickScalarCache(
                descriptor: ticker.descriptor,
                value: ticker.value(),
                signal: ticker.signal()
            )
        }
    }

    /// Build a CPU evaluator closure for a uniform-only IRExpr (no spatial coordinates).
    /// Handles the subset of IRExpr that can appear in scalar cache expressions:
    /// time/dimensions from self, mouse/key from InputState, math builtins, bundle refs.
    private func buildUniformEvaluator(
        expr: IRExpr,
        program: IRProgram,
        cacheManager: CacheManager,
        descriptors: [CacheNodeDescriptor],
        depth: Int = 0
    ) -> () -> Float {
        guard depth < 256 else { return { 0 } }
        let nextDepth = depth + 1

        switch expr {
        case .num(let v):
            let fv = Float(v)
            return { fv }

        case .param(let name):
            switch name {
            case "t": return { [weak self] in Float(self?.currentTime ?? 0) }
            case "w": return { [weak self] in Float(self?.width ?? 0) }
            case "h": return { [weak self] in Float(self?.height ?? 0) }
            default: return { 0 }
            }

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                if case .param(let field) = indexExpr {
                    return buildUniformEvaluator(
                        expr: .param(field), program: program,
                        cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth
                    )
                }
                return { 0 }
            }

            // Resolve bundle strand reference by inlining the strand expression
            if let targetBundle = program.bundles[bundle] {
                let strandExpr: IRExpr?
                if case .num(let idx) = indexExpr {
                    let i = Int(idx)
                    strandExpr = i < targetBundle.strands.count ? targetBundle.strands[i].expr : nil
                } else if case .param(let field) = indexExpr {
                    strandExpr = targetBundle.strands.first(where: { $0.name == field })?.expr
                } else {
                    strandExpr = nil
                }
                if let expr = strandExpr {
                    return buildUniformEvaluator(
                        expr: expr, program: program,
                        cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth
                    )
                }
            }
            return { 0 }

        case .binaryOp(let op, let left, let right):
            let l = buildUniformEvaluator(expr: left, program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)
            let r = buildUniformEvaluator(expr: right, program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)
            switch op {
            case "+": return { l() + r() }
            case "-": return { l() - r() }
            case "*": return { l() * r() }
            case "/": return { l() / r() }
            case "%": return { fmodf(l(), r()) }
            case "^": return { powf(l(), r()) }
            case "<": return { l() < r() ? 1 : 0 }
            case ">": return { l() > r() ? 1 : 0 }
            case "<=": return { l() <= r() ? 1 : 0 }
            case ">=": return { l() >= r() ? 1 : 0 }
            case "==": return { l() == r() ? 1 : 0 }
            case "!=": return { l() != r() ? 1 : 0 }
            case "&&": return { (l() != 0 && r() != 0) ? 1 : 0 }
            case "||": return { (l() != 0 || r() != 0) ? 1 : 0 }
            default: return { 0 }
            }

        case .unaryOp(let op, let operand):
            let e = buildUniformEvaluator(expr: operand, program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)
            switch op {
            case "-": return { -e() }
            case "!": return { e() == 0 ? 1 : 0 }
            default: return { 0 }
            }

        case .builtin(let name, let args):
            if name == "cache" {
                // Scalar cache inside another scalar cache expression — tick it
                if args.count >= 4,
                   let desc = descriptors.first(where: { $0.valueExpr == args[0] && $0.signalExpr == args[3] }) {
                    let valEval = buildUniformEvaluator(expr: args[0], program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)
                    let sigEval = buildUniformEvaluator(expr: args[3], program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)
                    return { cacheManager.tickScalarCache(descriptor: desc, value: valEval(), signal: sigEval()) }
                }
                // Fallback: evaluate the value expression
                if !args.isEmpty {
                    return buildUniformEvaluator(expr: args[0], program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)
                }
                return { 0 }
            }

            if name == "mouse" {
                guard args.count >= 1, case .num(let ch) = args[0] else { return { 0 } }
                let channel = Int(ch)
                return {
                    let state = InputState.shared.getMouseState()
                    switch channel {
                    case 0: return state.x
                    case 1: return state.y
                    case 2: return state.down
                    default: return state.x
                    }
                }
            }

            if name == "key" {
                guard args.count >= 1, case .num(let code) = args[0] else { return { 0 } }
                let keyCode = Int(code)
                return { InputState.shared.getKeyState(keyCode: keyCode) }
            }

            // Math builtins
            let evals = args.map { buildUniformEvaluator(expr: $0, program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth) }
            switch name {
            case "sin": return { sinf(evals[0]()) }
            case "cos": return { cosf(evals[0]()) }
            case "tan": return { tanf(evals[0]()) }
            case "asin": return { asinf(evals[0]()) }
            case "acos": return { acosf(evals[0]()) }
            case "atan": return { atanf(evals[0]()) }
            case "atan2" where evals.count >= 2: return { atan2f(evals[0](), evals[1]()) }
            case "abs": return { abs(evals[0]()) }
            case "floor": return { floorf(evals[0]()) }
            case "ceil": return { ceilf(evals[0]()) }
            case "round": return { roundf(evals[0]()) }
            case "sqrt": return { sqrtf(evals[0]()) }
            case "pow" where evals.count >= 2: return { powf(evals[0](), evals[1]()) }
            case "exp": return { expf(evals[0]()) }
            case "log": return { logf(evals[0]()) }
            case "log2": return { log2f(evals[0]()) }
            case "min" where evals.count >= 2: return { min(evals[0](), evals[1]()) }
            case "max" where evals.count >= 2: return { max(evals[0](), evals[1]()) }
            case "clamp" where evals.count >= 3: return { min(max(evals[0](), evals[1]()), evals[2]()) }
            case "lerp" where evals.count >= 3, "mix" where evals.count >= 3:
                return { let a = evals[0](); let b = evals[1](); return a + (b - a) * evals[2]() }
            case "step" where evals.count >= 2: return { evals[1]() < evals[0]() ? 0 : 1 }
            case "smoothstep" where evals.count >= 3:
                return {
                    let edge0 = evals[0](); let edge1 = evals[1](); let x = evals[2]()
                    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
                    return t * t * (3 - 2 * t)
                }
            case "fract": return { let v = evals[0](); return v - floorf(v) }
            case "mod" where evals.count >= 2: return { fmodf(evals[0](), evals[1]()) }
            case "sign":
                return { let v = evals[0](); return v > 0 ? 1 : (v < 0 ? -1 : 0) }
            case "select" where evals.count >= 2:
                let branches = Array(evals.dropFirst())
                let indexEval = evals[0]
                return {
                    let idx = Int(indexEval())
                    let clamped = max(0, min(idx, branches.count - 1))
                    return branches[clamped]()
                }
            case "noise":
                let xEval = evals[0]
                let yEval = evals.count > 1 ? evals[1] : { Float(0) }
                return {
                    let dot = xEval() * 12.9898 + yEval() * 78.233
                    let s = sinf(dot) * 43758.5453
                    return s - floorf(s)
                }
            default: return { 0 }
            }

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle], !spindleDef.returns.isEmpty else { return { 0 } }
            let substitutions = IRTransformations.buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(in: spindleDef.returns[0], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(in: inlined, substitutions: substitutions)
            return buildUniformEvaluator(expr: inlined, program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)

        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr,
                  let spindleDef = program.spindles[spindle],
                  index < spindleDef.returns.count else { return { 0 } }
            let substitutions = IRTransformations.buildSpindleSubstitutions(spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(in: spindleDef.returns[index], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(in: inlined, substitutions: substitutions)
            return buildUniformEvaluator(expr: inlined, program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)

        case .remap(let base, let substitutions):
            let directExpr = IRTransformations.getDirectExpression(base, program: program)
            let remapped = IRTransformations.applyRemap(to: directExpr, substitutions: substitutions)
            return buildUniformEvaluator(expr: remapped, program: program, cacheManager: cacheManager, descriptors: descriptors, depth: nextDepth)

        case .cacheRead(let cacheId, let tapIndex, _):
            guard let descriptor = descriptors.first(where: { $0.id == cacheId }) else { return { 0 } }
            let clampedTap = min(tapIndex, descriptor.historySize - 1)
            return { cacheManager.readScalarCache(descriptor: descriptor, tapIndex: clampedTap) }
        }
    }

    // MARK: - Shared Resource Binding

    /// Bind shared resources (textures, samplers, buffers) to a compute encoder.
    /// Used by both intermediate and display kernel passes.
    private func bindSharedResources(
        encoder: MTLComputeCommandEncoder,
        metalUnit: MetalCompiledUnit,
        cacheManager: CacheManager?
    ) {
        // Bind key state buffer if needed
        if metalUnit.usedInputs.contains("key") {
            encoder.setBuffer(keyStateBuffer, offset: 0, index: 1)
        }

        // Bind textures for used inputs (derived from bindings)
        for binding in MetalBackend.bindings {
            if case .input(let input) = binding, metalUnit.usedInputs.contains(input.builtinName) {
                if let textureIndex = input.textureIndex {
                    switch input.builtinName {
                    case "camera":
                        if let camTex = getCameraTexture() {
                            encoder.setTexture(camTex, index: textureIndex)
                        }
                    case "microphone":
                        if let audioTex = audioBufferTexture {
                            encoder.setTexture(audioTex, index: 2)
                        }
                    default:
                        break
                    }
                }
            }
        }

        // Bind loaded textures for texture() builtin
        for textureId in metalUnit.usedTextureIds {
            if let tex = loadedTextures[textureId] {
                let textureIndex = MetalCodeGen.textureBaseIndex + textureId
                encoder.setTexture(tex, index: textureIndex)
            }
        }

        // Bind text textures for text() builtin
        for textId in metalUnit.usedTextIds {
            if let tex = textTextures[textId] {
                let textureIndex = MetalCodeGen.textTextureBaseIndex + textId
                encoder.setTexture(tex, index: textureIndex)
            }
        }

        // Bind sampler if any texture input is used
        let textureInputs = metalUnit.usedInputs.subtracting(["cache"])
        let needsSampler = !textureInputs.isEmpty || metalUnit.intermediateCount > 0
        if needsSampler {
            if let sampler = samplerState {
                encoder.setSamplerState(sampler, index: 0)
            }
        }

        // Bind cache buffers if needed
        if metalUnit.usedInputs.contains("cache"), let manager = cacheManager {
            let cacheDescriptors = manager.getDescriptors(forBackend: MetalBackend.identifier)
            for (i, descriptor) in cacheDescriptors.enumerated() {
                let historyIdx = CacheNodeDescriptor.shaderHistoryBufferIndex(cachePosition: i)
                let signalIdx = CacheNodeDescriptor.shaderSignalBufferIndex(cachePosition: i)

                if let historyBuffer = manager.getBuffer(index: descriptor.historyBufferIndex) {
                    encoder.setBuffer(historyBuffer.mtlBuffer, offset: 0, index: historyIdx)
                }
                if let signalBuffer = manager.getBuffer(index: descriptor.signalBufferIndex) {
                    encoder.setBuffer(signalBuffer.mtlBuffer, offset: 0, index: signalIdx)
                }
            }
        }

        // Bind cross-domain data buffer if needed
        if metalUnit.crossDomainSlotCount > 0 {
            if let buf = crossDomainMTLBuffer {
                encoder.setBuffer(buf, offset: 0, index: metalUnit.crossDomainBufferIndex)
            }
        }

        // Bind probe buffer if needed
        if metalUnit.probeSlotCount > 0, let buf = probeBuffer {
            encoder.setBuffer(buf, offset: 0, index: MetalCodeGen.probeBufferIndex)
        }
    }

    // MARK: - Intermediate Texture Management

    /// Ensure intermediate textures exist with the correct count and dimensions
    private func ensureIntermediateTextures(count: Int, width: Int, height: Int) {
        let needsRealloc = intermediateTextures.count != count
            || (count > 0 && (intermediateTextures[0].width != width || intermediateTextures[0].height != height))

        guard needsRealloc else { return }

        var textures: [MTLTexture] = []
        for _ in 0..<count {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else {
                intermediateTextures = []
                return
            }
            textures.append(tex)
        }
        intermediateTextures = textures
    }

    // MARK: - Scope Texture Management

    /// Ensure scope textures exist with the correct count and dimensions.
    /// Uses .shared storage mode for CPU readback.
    private func ensureScopeTextures(count: Int, width: Int, height: Int) {
        let needsRealloc = scopeTextures.count != count
            || (count > 0 && (scopeTextures[0].width != width || scopeTextures[0].height != height))

        guard needsRealloc else { return }

        var textures: [MTLTexture] = []
        for _ in 0..<count {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else {
                scopeTextures = []
                return
            }
            textures.append(tex)
        }
        scopeTextures = textures
    }

    /// Get current scope textures (for CPU readback by Coordinator)
    public func getScopeTextures() -> [MTLTexture] {
        return scopeTextures
    }

    // MARK: - Probe Buffer Readback

    /// Read probe values from the shared probe buffer.
    /// Returns strand values as [String: Float] using the probeSlotMap, or nil if no probe data.
    public func readProbeValues() -> [String: Float]? {
        guard probeSlotCount > 0, let buffer = probeBuffer else { return nil }
        let ptr = buffer.contents().assumingMemoryBound(to: Float.self)
        var result: [String: Float] = [:]
        for (name, slot) in probeSlotMap {
            result[name] = ptr[slot]
        }
        return result
    }
}
