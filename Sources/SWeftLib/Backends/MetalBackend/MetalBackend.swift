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

    public init(swatchId: UUID, pipelineState: MTLComputePipelineState, shaderSource: String, usedInputs: Set<String> = []) {
        self.swatchId = swatchId
        self.pipelineState = pipelineState
        self.shaderSource = shaderSource
        self.usedInputs = usedInputs
    }
}

// MARK: - Metal Uniforms

public struct MetalUniforms {
    var time: Float
    var width: Float
    var height: Float
}

// MARK: - Metal Backend

public class MetalBackend: Backend {
    public static let identifier = "visual"
    public static let ownedBuiltins: Set<String> = ["camera", "texture", "load"]
    public static let externalBuiltins: Set<String> = ["camera", "texture"]
    public static let statefulBuiltins: Set<String> = ["cache"]
    public static let coordinateFields = ["x", "y", "t", "w", "h"]

    public static let bindings: [BackendBinding] = [
        // Inputs
        .input(InputBinding(
            builtinName: "camera",
            shaderParam: "texture2d<float, access::sample> cameraTexture [[texture(1)]]",
            textureIndex: 1
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
    private var samplerState: MTLSamplerState?
    public var width: Int = 512
    public var height: Int = 512

    /// Camera texture - set externally by CameraCapture
    public var cameraTexture: MTLTexture?

    /// Audio buffer texture - for microphone/audio reactive visuals
    public var audioBufferTexture: MTLTexture?

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

        // Create sampler state for texture sampling
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        self.samplerState = device.makeSamplerState(descriptor: samplerDescriptor)
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

    /// Compile swatch to Metal pipeline with cache descriptors
    public func compile(swatch: Swatch, ir: IRProgram, cacheDescriptors: [CacheNodeDescriptor]) throws -> CompiledUnit {
        let codegen = MetalCodeGen(program: ir, swatch: swatch, cacheDescriptors: cacheDescriptors)
        let shaderSource = try codegen.generate()
        var usedInputs = codegen.usedInputs()

        // Add "cache" to usedInputs if there are cache descriptors
        if codegen.usesCache() {
            usedInputs.insert("cache")
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

        return MetalCompiledUnit(
            swatchId: swatch.id,
            pipelineState: pipelineState,
            shaderSource: shaderSource,
            usedInputs: usedInputs
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
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }

        // Ensure output texture exists
        if outputTexture == nil {
            createOutputTexture()
        }
        guard let texture = outputTexture else { return }

        // Update uniforms
        var uniforms = MetalUniforms(
            time: Float(time),
            width: Float(width),
            height: Float(height)
        )
        uniformBuffer?.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<MetalUniforms>.stride)

        // Configure compute encoder
        computeEncoder.setComputePipelineState(metalUnit.pipelineState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        // Dispatch
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
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
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }

        let texture = drawable.texture

        // Update uniforms
        var uniforms = MetalUniforms(
            time: Float(time),
            width: Float(texture.width),
            height: Float(texture.height)
        )
        uniformBuffer?.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<MetalUniforms>.stride)

        // Configure compute encoder
        computeEncoder.setComputePipelineState(metalUnit.pipelineState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)

        // Bind textures for used inputs (derived from bindings)
        for binding in MetalBackend.bindings {
            if case .input(let input) = binding, metalUnit.usedInputs.contains(input.builtinName) {
                if let textureIndex = input.textureIndex {
                    switch input.builtinName {
                    case "camera":
                        if let camTex = cameraTexture {
                            computeEncoder.setTexture(camTex, index: textureIndex)
                        }
                    case "microphone":
                        if let audioTex = audioBufferTexture {
                            computeEncoder.setTexture(audioTex, index: 2) // microphone uses index 2
                        }
                    default:
                        break
                    }
                }
            }
        }

        // Bind sampler if any input texture is used
        let textureInputs = metalUnit.usedInputs.subtracting(["cache"])
        if !textureInputs.isEmpty {
            if let sampler = samplerState {
                computeEncoder.setSamplerState(sampler, index: 0)
            }
        }

        // Bind cache buffers if needed
        if metalUnit.usedInputs.contains("cache"), let manager = cacheManager {
            let cacheDescriptors = manager.getDescriptors(for: .visual)
            for (i, descriptor) in cacheDescriptors.enumerated() {
                // Buffer indices: 0 = uniforms, 1+ = cache buffers
                // Each cache has: history buffer, signal buffer
                let historyBufferIndex = 1 + i * 2
                let signalBufferIndex = 1 + i * 2 + 1

                if let historyBuffer = manager.getBuffer(index: descriptor.historyBufferIndex) {
                    computeEncoder.setBuffer(historyBuffer.mtlBuffer, offset: 0, index: historyBufferIndex)
                }
                if let signalBuffer = manager.getBuffer(index: descriptor.signalBufferIndex) {
                    computeEncoder.setBuffer(signalBuffer.mtlBuffer, offset: 0, index: signalBufferIndex)
                }
            }
        }

        // Dispatch
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (texture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (texture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
