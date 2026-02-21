// VideoRecorder.swift - AVAssetWriter-based video capture from Metal textures

import Foundation
import AVFoundation
import Metal
import CoreVideo

class VideoRecorder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: Double = 0
    private var frameCount: Int64 = 0
    private let fps: Int32 = 30

    private var stagingTexture: MTLTexture?
    private let device: MTLDevice
    private(set) var outputURL: URL
    private var isWriting = false
    private var writerConfigured = false

    init(device: MTLDevice) {
        self.device = device

        // Generate output URL
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "WEFT-\(timestamp).mp4"
        let desktopURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        self.outputURL = desktopURL.appendingPathComponent(filename)
    }

    /// Appends a frame from the current drawable texture. Call from the render loop.
    /// Lazily configures the writer on the first frame using the texture dimensions.
    func appendFrame(commandBuffer: MTLCommandBuffer, sourceTexture: MTLTexture, time: Double) {
        // Lazy setup on first frame
        if !writerConfigured {
            configureWriter(width: sourceTexture.width, height: sourceTexture.height)
            guard writerConfigured else { return }
        }

        guard isWriting,
              let input = videoInput, input.isReadyForMoreMediaData,
              let adaptor = adaptor,
              let staging = stagingTexture else { return }

        // Initialize start time on first frame
        if startTime == 0 {
            startTime = time
        }

        // Throttle to target fps
        let elapsed = time - startTime
        let frameDuration = 1.0 / Double(fps)
        let expectedFrame = Int64(elapsed / frameDuration)
        if expectedFrame <= frameCount { return }
        frameCount = expectedFrame

        // Blit drawable -> staging texture
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: sourceTexture.width, height: sourceTexture.height, depth: 1),
            to: staging,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read staging texture bytes into a CVPixelBuffer
        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            print("VideoRecorder: No pixel buffer pool available")
            return
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            print("VideoRecorder: Failed to create pixel buffer: \(status)")
            return
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        staging.getBytes(
            baseAddress,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                           size: MTLSize(width: staging.width, height: staging.height, depth: 1)),
            mipmapLevel: 0
        )

        let presentationTime = CMTime(value: frameCount, timescale: CMTimeScale(fps))
        adaptor.append(pb, withPresentationTime: presentationTime)
    }

    /// Stops recording and finalizes the file.
    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isWriting, let writer = assetWriter else {
            completion(nil)
            return
        }

        isWriting = false
        videoInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            if writer.status == .completed {
                completion(self?.outputURL)
            } else {
                print("VideoRecorder: finishWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
                completion(nil)
            }
        }
    }

    // MARK: - Private

    private func configureWriter(width: Int, height: Int) {
        // Clean up any existing file at this path
        try? FileManager.default.removeItem(at: outputURL)

        frameCount = 0
        startTime = 0

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 5_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                ]
            ]

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true

            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )

            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            self.assetWriter = writer
            self.videoInput = input
            self.adaptor = pixelBufferAdaptor
            self.isWriting = true
            self.writerConfigured = true

            // Create staging texture
            ensureStagingTexture(width: width, height: height)

        } catch {
            print("VideoRecorder: Failed to create AVAssetWriter: \(error)")
        }
    }

    private func ensureStagingTexture(width: Int, height: Int) {
        if let existing = stagingTexture, existing.width == width, existing.height == height {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = [.shaderRead]
        stagingTexture = device.makeTexture(descriptor: desc)
    }
}
