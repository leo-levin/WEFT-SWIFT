// CameraCapture.swift - AVFoundation camera capture with Metal texture output

import Foundation
import AVFoundation
import Metal
import CoreVideo

public protocol CameraCaptureDelegate: AnyObject {
    func cameraCapture(_ capture: CameraCapture, didUpdateTexture texture: MTLTexture)
}

public class CameraCapture: NSObject {
    public weak var delegate: CameraCaptureDelegate?

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let outputQueue = DispatchQueue(label: "camera.output")

    private(set) public var isRunning = false
    private(set) public var latestTexture: MTLTexture?

    public init(device: MTLDevice) {
        self.device = device
        super.init()

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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.cameraCapture(self, didUpdateTexture: texture)
        }
    }
}
