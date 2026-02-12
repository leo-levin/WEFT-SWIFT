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

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        if status == kCVReturnSuccess {
            self.textureCache = cache
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
            captureSession.commitConfiguration()
            return
        }

        // Add input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                captureSession.commitConfiguration()
                return
            }
        } catch {
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
            captureSession.commitConfiguration()
            return
        }

        captureSession.commitConfiguration()
        captureSession.startRunning()
        isRunning = true
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.cameraCapture(self, didUpdateTexture: texture)
        }
    }
}

// MARK: - Errors

public enum CameraCaptureError: Error {
    case noDevice
    case textureCreationFailed
}
