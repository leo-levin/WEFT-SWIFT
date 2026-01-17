// BufferManager.swift - Manage buffers for cross-domain data transfer

import Foundation
import Metal

// MARK: - Buffer Manager

public class BufferManager {
    private var buffers: [String: any Buffer] = [:]
    private var metalDevice: MTLDevice?

    public init(metalDevice: MTLDevice? = nil) {
        self.metalDevice = metalDevice
    }

    /// Create or get a cross-domain buffer
    public func getBuffer(name: String, width: Int, height: Int = 1) -> any Buffer {
        if let existing = buffers[name] {
            return existing
        }

        let buffer = CrossDomainBuffer(name: name, width: width, height: height)
        buffers[name] = buffer
        return buffer
    }

    /// Create or get an audio buffer
    public func getAudioBuffer(name: String, sampleCount: Int, sampleRate: Double = 44100) -> AudioBuffer {
        if let existing = buffers[name] as? AudioBuffer {
            return existing
        }

        let buffer = AudioBuffer(name: name, sampleCount: sampleCount, sampleRate: sampleRate)
        buffers[name] = buffer
        return buffer
    }

    /// Create a Metal texture buffer
    public func createMetalBuffer(name: String, width: Int, height: Int) -> MetalBuffer? {
        guard let device = metalDevice else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let buffer = MetalBuffer(name: name, texture: texture)
        buffers[name] = buffer
        return buffer
    }

    /// Get all buffers
    public func getAllBuffers() -> [String: any Buffer] {
        return buffers
    }

    /// Get buffers matching names
    public func getBuffers(names: Set<String>) -> [String: any Buffer] {
        var result: [String: any Buffer] = [:]
        for name in names {
            if let buffer = buffers[name] {
                result[name] = buffer
            }
        }
        return result
    }

    /// Clear all buffers
    public func clear() {
        buffers = [:]
    }
}
