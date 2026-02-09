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

    public init(swatchId: UUID, pipelineState: MTLComputePipelineState, shaderSource: String, usedInputs: Set<String> = [], usedTextureIds: Set<Int> = [], usedTextIds: Set<Int> = [], crossDomainSlotCount: Int = 0, crossDomainSlotMap: [String: Int] = [:], intermediatePipelines: [MTLComputePipelineState] = [], intermediateCount: Int = 0, scopeTextureCount: Int = 0, scopedBundleNames: [String] = []) {
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
    var _padding: Float = 0  // Padding for alignment
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

    /// Last command buffer — used to sync before CPU readback of scope textures
    private var lastCommandBuffer: MTLCommandBuffer?

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

        // Debug: print generated shader
        print("Generated Metal shader:")
        print(shaderSource)

        // Compile shader
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw BackendError.compilationFailed("Metal compilation error: \(error.localizedDescription)")
        }

        guard let kernelFunction = library.makeFunction(name: "displayKernel") else {
            throw BackendError.compilationFailed("Could not find displayKernel function")
        }

        let pipelineState: MTLComputePipelineState
        do {
            pipelineState = try device.makeComputePipelineState(function: kernelFunction)
        } catch {
            throw BackendError.compilationFailed("Could not create pipeline state: \(error.localizedDescription)")
        }

        // Build intermediate pipelines for heavy remap textures
        var intermediatePipelines: [MTLComputePipelineState] = []
        for i in 0..<codegen.intermediateTextureCount {
            guard let fn = library.makeFunction(name: "intermediateKernel\(i)") else {
                throw BackendError.compilationFailed("Could not find intermediateKernel\(i)")
            }
            intermediatePipelines.append(try device.makeComputePipelineState(function: fn))
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
            scopedBundleNames: codegen.scopedBundleNames
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

        let texture = drawable.texture

        // Get current input state
        let mouseState = InputState.shared.getMouseState()

        // Update uniforms including input state
        var uniforms = MetalUniforms(
            time: Float(time),
            width: Float(texture.width),
            height: Float(texture.height),
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
            let cacheDescriptors = manager.getDescriptors(for: .visual)
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
                encoder.setBuffer(buf, offset: 0, index: 30)
            }
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
                print("Warning: Failed to allocate intermediate texture")
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
                print("Warning: Failed to allocate scope texture")
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
}
