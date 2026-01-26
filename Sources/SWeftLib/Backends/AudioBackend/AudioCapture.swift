// AudioCapture.swift - Microphone capture for audio-reactive visuals

import Foundation
import AVFoundation
import Metal

// MARK: - Audio Capture

public class AudioCapture: NSObject, AudioInputProvider {
    // MARK: - InputProvider Static Properties

    public static var builtinName: String { "microphone" }
    public static var hardware: IRHardware { .microphone }
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var isCapturing = false

    // Ring buffer for audio history
    private let bufferSize: Int
    private var leftBuffer: [Float]
    private var rightBuffer: [Float]
    private var writeIndex: Int = 0
    private var sampleCount: Int = 0
    private let bufferLock = NSLock()

    // Metal texture for GPU access
    private var device: MTLDevice?
    private var audioTexture: MTLTexture?

    public init(bufferSize: Int = 4096) {
        self.bufferSize = bufferSize
        self.leftBuffer = [Float](repeating: 0, count: bufferSize)
        self.rightBuffer = [Float](repeating: 0, count: bufferSize)
        super.init()
    }

    // MARK: - Setup (InputProvider Protocol)

    public func setup(device: MTLDevice?) throws {
        self.device = device
        if device != nil {
            try createTexture()
        }
    }

    // MARK: - InputProvider Protocol Methods

    public func start() throws {
        try startCapture()
    }

    public func stop() {
        stopCapture()
    }

    private func createTexture() throws {
        guard let device = device else {
            throw AudioCaptureError.noDevice
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .rg32Float  // R = left, G = right
        descriptor.width = bufferSize
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw AudioCaptureError.textureCreationFailed
        }

        audioTexture = texture
    }

    // MARK: - Capture Control

    public func startCapture() throws {
        guard !isCapturing else { return }

        let inputNode = audioEngine.inputNode
        self.inputNode = inputNode

        let format = inputNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let channelCount = format.channelCount

        print("Audio capture: \(sampleRate) Hz, \(channelCount) channels")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }

        try audioEngine.start()
        isCapturing = true
    }

    public func stopCapture() {
        guard isCapturing else { return }

        inputNode?.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        bufferLock.lock()
        defer { bufferLock.unlock() }

        for frame in 0..<frameCount {
            // Left channel
            leftBuffer[writeIndex] = floatData[0][frame]

            // Right channel (or duplicate left if mono)
            if channelCount > 1 {
                rightBuffer[writeIndex] = floatData[1][frame]
            } else {
                rightBuffer[writeIndex] = floatData[0][frame]
            }

            writeIndex = (writeIndex + 1) % bufferSize
            sampleCount += 1
        }
    }

    // MARK: - AudioInputProvider Protocol

    public func getSample(at sampleIndex: Int, channel: Int) -> Float {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        // Convert absolute sample index to ring buffer position
        // Negative offset means past samples
        let offset = sampleIndex - sampleCount
        var index = (writeIndex + offset) % bufferSize
        if index < 0 { index += bufferSize }

        return channel == 0 ? leftBuffer[index] : rightBuffer[index]
    }

    // MARK: - Metal Texture Access

    /// Update the Metal texture with current audio buffer
    public func updateTexture() {
        guard let texture = audioTexture else { return }

        bufferLock.lock()

        // Create interleaved buffer for texture (RG format)
        var interleavedData = [Float](repeating: 0, count: bufferSize * 2)

        // Copy from ring buffer, starting from oldest sample
        for i in 0..<bufferSize {
            let bufferIndex = (writeIndex + i) % bufferSize
            interleavedData[i * 2] = leftBuffer[bufferIndex]
            interleavedData[i * 2 + 1] = rightBuffer[bufferIndex]
        }

        bufferLock.unlock()

        // Upload to texture
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: bufferSize, height: 1, depth: 1))

        interleavedData.withUnsafeBytes { ptr in
            texture.replace(region: region,
                           mipmapLevel: 0,
                           withBytes: ptr.baseAddress!,
                           bytesPerRow: bufferSize * 2 * MemoryLayout<Float>.stride)
        }
    }

    /// Get the Metal texture for binding to shader
    public func getTexture() -> MTLTexture? {
        return audioTexture
    }

    // MARK: - Audio Analysis

    /// Get current audio level (RMS)
    public func getLevel(channel: Int = 0) -> Float {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let buffer = channel == 0 ? leftBuffer : rightBuffer
        let windowSize = min(1024, bufferSize)

        var sum: Float = 0
        for i in 0..<windowSize {
            let index = (writeIndex - windowSize + i + bufferSize) % bufferSize
            sum += buffer[index] * buffer[index]
        }

        return sqrt(sum / Float(windowSize))
    }

    /// Get current peak level
    public func getPeak(channel: Int = 0) -> Float {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let buffer = channel == 0 ? leftBuffer : rightBuffer
        let windowSize = min(1024, bufferSize)

        var peak: Float = 0
        for i in 0..<windowSize {
            let index = (writeIndex - windowSize + i + bufferSize) % bufferSize
            peak = max(peak, abs(buffer[index]))
        }

        return peak
    }
}

// MARK: - Errors

public enum AudioCaptureError: Error {
    case noDevice
    case textureCreationFailed
    case captureStartFailed
}
