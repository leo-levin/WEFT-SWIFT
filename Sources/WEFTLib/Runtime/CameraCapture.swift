// CameraCapture.swift - AVFoundation camera capture with Metal texture output

import Foundation
import AVFoundation
import Metal
import CoreVideo

public protocol CameraCaptureDelegate: AnyObject {
    func cameraCapture(_ capture: CameraCapture, didUpdateTexture texture: MTLTexture)
}

public class CameraCapture: NSObject, VisualInputProvider {
    // MARK: - InputProvider Static Properties

    public static var builtinName: String { "camera" }
    public static var hardware: IRHardware { .camera }

    public weak var delegate: CameraCaptureDelegate?

    private var device: MTLDevice?
    private var textureCache: CVMetalTextureCache?
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let outputQueue = DispatchQueue(label: "camera.output")

    private(set) public var isRunning = false
    private(set) public var latestTexture: MTLTexture?

    /// Retained pixel data for CPU-side sampling (BGRA, 8-bit per channel)
    private var pixelData: [UInt8] = []
    private var pixelWidth: Int = 0
    private var pixelHeight: Int = 0

    /// VisualInputProvider conformance - alias for latestTexture
    public var texture: MTLTexture? { latestTexture }

    /// Initialize with Metal device (convenience for backward compatibility)
    public init(device: MTLDevice) {
        self.device = device
        super.init()
        createTextureCache()
    }

    /// Default initializer - call setup(device:) before start()
    public override init() {
        super.init()
    }

    // MARK: - InputProvider Protocol

    public func setup(device: MTLDevice?) throws {
        guard let device = device else {
            throw CameraCaptureError.noDevice
        }
        self.device = device
        createTextureCache()
    }

    private func createTextureCache() {
        guard let device = device else { return }

        // Create texture cache for efficient CVPixelBuffer -> MTLTexture conversion
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        if status == kCVReturnSuccess {
            self.textureCache = cache
        } else {
            print("CameraCapture: Failed to create texture cache: \(status)")
        }
    }

    public func start() throws {
        guard !isRunning else { return }

        sessionQueue.async { [weak self] in
            self?.setupSession()
        }
    }

    public func stop() {
        guard isRunning else { return }

        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            self?.isRunning = false
        }
    }

    private func setupSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        // Find camera
        guard let camera = AVCaptureDevice.default(for: .video) else {
            print("CameraCapture: No camera available")
            captureSession.commitConfiguration()
            return
        }

        // Add input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                print("CameraCapture: Cannot add camera input")
                captureSession.commitConfiguration()
                return
            }
        } catch {
            print("CameraCapture: Failed to create input: \(error)")
            captureSession.commitConfiguration()
            return
        }

        // Configure output for Metal-compatible pixel format
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        } else {
            print("CameraCapture: Cannot add video output")
            captureSession.commitConfiguration()
            return
        }

        captureSession.commitConfiguration()
        captureSession.startRunning()
        isRunning = true

        print("CameraCapture: Started")
    }

    private func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture else {
            print("CameraCapture: Failed to create texture: \(status)")
            return nil
        }

        return CVMetalTextureGetTexture(cvTex)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let texture = createTexture(from: pixelBuffer) else { return }

        latestTexture = texture

        // Retain CPU-side pixel data for Loom sampling
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let totalBytes = height * bytesPerRow
            let newData = [UInt8](UnsafeBufferPointer(
                start: baseAddress.assumingMemoryBound(to: UInt8.self),
                count: totalBytes
            ))
            self.pixelData = newData
            self.pixelWidth = width
            self.pixelHeight = height
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.cameraCapture(self, didUpdateTexture: texture)
        }
    }
}

// MARK: - CPU Pixel Sampling

extension CameraCapture {
    /// Sample a pixel from the latest camera frame at normalized (u, v) coordinates.
    /// Format is BGRA, so we remap channel indices: 0=R→[2], 1=G→[1], 2=B→[0], 3=A→[3]
    public func samplePixel(u: Double, v: Double, channel: Int) -> Double {
        guard !pixelData.isEmpty, pixelWidth > 0, pixelHeight > 0 else { return 0.0 }

        let px = Int(max(0, min(Double(pixelWidth - 1), u * Double(pixelWidth - 1))))
        let py = Int(max(0, min(Double(pixelHeight - 1), v * Double(pixelHeight - 1))))
        let bytesPerRow = pixelData.count / pixelHeight
        let offset = py * bytesPerRow + px * 4

        guard offset + 3 < pixelData.count else { return 0.0 }

        // BGRA layout → remap channel
        let bgraIndex: Int
        switch channel {
        case 0: bgraIndex = 2  // R
        case 1: bgraIndex = 1  // G
        case 2: bgraIndex = 0  // B
        case 3: bgraIndex = 3  // A
        default: return 0.0
        }

        return Double(pixelData[offset + bgraIndex]) / 255.0
    }
}

// MARK: - Errors

public enum CameraCaptureError: Error {
    case noDevice
    case textureCreationFailed
}
