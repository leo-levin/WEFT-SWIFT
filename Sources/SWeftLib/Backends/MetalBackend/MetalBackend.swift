// MetalBackend.swift - Metal rendering backend

import Foundation
import Metal
import MetalKit

// MARK: - Metal Compiled Unit

public class MetalCompiledUnit: CompiledUnit {
    public let swatchId: UUID
    public let pipelineState: MTLComputePipelineState
    public let shaderSource: String
    public let needsCamera: Bool
    public let needsMicrophone: Bool

    public init(swatchId: UUID, pipelineState: MTLComputePipelineState, shaderSource: String, needsCamera: Bool = false, needsMicrophone: Bool = false) {
        self.swatchId = swatchId
        self.pipelineState = pipelineState
        self.shaderSource = shaderSource
        self.needsCamera = needsCamera
        self.needsMicrophone = needsMicrophone
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
    public static let statefulBuiltins: Set<String> = []
    public static let outputSinkName: String? = "display"
    public static let coordinateFields = ["x", "y", "t", "w", "h"]

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

    /// Compile swatch to Metal pipeline
    public func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit {
        let codegen = MetalCodeGen(program: ir, swatch: swatch)
        let shaderSource = try codegen.generate()
        let needsCamera = codegen.usesCamera()
        let needsMicrophone = codegen.usesMicrophone()

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
            needsCamera: needsCamera,
            needsMicrophone: needsMicrophone
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

    /// Render to a drawable (for MTKView)
    public func render(
        unit: CompiledUnit,
        to drawable: CAMetalDrawable,
        time: Double
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

        // Bind camera texture if needed
        if metalUnit.needsCamera {
            if let camTex = cameraTexture {
                computeEncoder.setTexture(camTex, index: 1)
            }
        }

        // Bind audio buffer texture if needed
        if metalUnit.needsMicrophone {
            if let audioTex = audioBufferTexture {
                computeEncoder.setTexture(audioTex, index: 2)
            }
        }

        // Bind sampler if any texture is used
        if metalUnit.needsCamera || metalUnit.needsMicrophone {
            if let sampler = samplerState {
                computeEncoder.setSamplerState(sampler, index: 0)
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
