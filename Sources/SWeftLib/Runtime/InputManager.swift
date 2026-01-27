// InputManager.swift - Centralized input provider management for WEFT

import Foundation
import Metal

// MARK: - Input Manager Delegate

/// Protocol for InputManager to communicate with its owner
public protocol InputManagerDelegate: AnyObject {
    /// Get the Metal device for creating input providers that need it
    func inputManagerNeedsMetalDevice(_ manager: InputManager) -> MTLDevice?

    /// Called when camera texture is updated
    func inputManager(_ manager: InputManager, didUpdateCameraTexture texture: MTLTexture)

    /// Called when audio buffer texture is updated
    func inputManager(_ manager: InputManager, didUpdateAudioTexture texture: MTLTexture)
}

// MARK: - Input Manager

/// Manages the lifecycle and registration of input providers (camera, microphone, etc.)
/// Extracted from Coordinator to follow Single Responsibility Principle.
public class InputManager {
    /// Delegate for hardware access and texture updates
    public weak var delegate: InputManagerDelegate?

    /// Registered input providers by builtin name
    private var providers: [String: any InputProvider] = [:]

    /// Camera capture instance (cached for backward compatibility)
    public private(set) var cameraCapture: CameraCapture?

    /// Audio capture instance (cached for backward compatibility)
    public private(set) var audioCapture: AudioCapture?

    /// Whether camera is needed by current program
    public private(set) var needsCamera = false

    /// Whether microphone is needed by current program
    public private(set) var needsMicrophone = false

    public init() {}

    // MARK: - Provider Registration

    /// Register an input provider manually
    public func register(_ provider: any InputProvider) {
        providers[type(of: provider).builtinName] = provider
    }

    /// Get a typed input provider by builtin name
    public func provider<T: InputProvider>(for builtinName: String) -> T? {
        providers[builtinName] as? T
    }

    /// Get any input provider by builtin name
    public func provider(for builtinName: String) -> (any InputProvider)? {
        providers[builtinName]
    }

    // MARK: - Provider Creation

    /// Create an input provider for the given builtin name
    /// - Returns: Newly created provider, or nil if the builtin is not an input
    public func createProvider(for builtinName: String) -> (any InputProvider)? {
        guard let device = delegate?.inputManagerNeedsMetalDevice(self) else {
            log.warning("Cannot create provider '\(builtinName)' - no Metal device", subsystem: LogSubsystem.coordinator)
            return nil
        }

        switch builtinName {
        case "microphone":
            let capture = AudioCapture()
            do {
                try capture.setup(device: device)
                audioCapture = capture
                return capture
            } catch {
                log.error("Failed to setup microphone: \(error)", subsystem: LogSubsystem.microphone)
                return nil
            }

        case "camera":
            let capture = CameraCapture(device: device)
            cameraCapture = capture
            return capture

        // Future: "midi", "osc", "gamepad", etc.
        default:
            return nil
        }
    }

    /// Lazily get or create a provider for the given builtin
    public func getOrCreateProvider(for builtinName: String) -> (any InputProvider)? {
        if let existing = providers[builtinName] {
            return existing
        }

        if let newProvider = createProvider(for: builtinName) {
            providers[builtinName] = newProvider
            return newProvider
        }

        return nil
    }

    // MARK: - Provider Collection for Backend

    /// Collect providers needed by a backend based on external builtins used
    /// - Parameters:
    ///   - backendId: The backend identifier
    ///   - swatch: The swatch being compiled
    ///   - program: The IR program
    /// - Returns: Dictionary of needed providers by builtin name
    public func collectProvidersForBackend(
        backendId: String,
        swatch: Swatch,
        program: IRProgram
    ) -> [String: any InputProvider] {
        let externalBuiltins = BackendRegistry.shared.externalBuiltins(for: backendId)
        var neededProviders: [String: any InputProvider] = [:]

        for builtinName in externalBuiltins {
            // Check if this swatch actually uses this builtin
            let usesBuiltin = swatch.bundles.contains { bundleName in
                guard let bundle = program.bundles[bundleName] else { return false }
                return bundle.strands.contains { strand in
                    strand.expr.usesBuiltin(builtinName)
                }
            }

            guard usesBuiltin else { continue }

            // Lazily create provider if needed
            if let provider = getOrCreateProvider(for: builtinName) {
                neededProviders[builtinName] = provider

                // Track hardware needs
                switch builtinName {
                case "camera":
                    needsCamera = true
                case "microphone":
                    needsMicrophone = true
                default:
                    break
                }
            }
        }

        return neededProviders
    }

    // MARK: - Hardware Control

    /// Reset hardware needs tracking (call before recompilation)
    public func resetHardwareNeeds() {
        needsCamera = false
        needsMicrophone = false
    }

    /// Start camera capture if needed
    public func startCameraIfNeeded() throws {
        guard needsCamera else { return }
        guard let camera = cameraCapture else {
            log.warning("Camera needed but not available", subsystem: LogSubsystem.camera)
            return
        }
        try camera.start()
        log.info("Camera started", subsystem: LogSubsystem.camera)
    }

    /// Stop camera capture
    public func stopCamera() {
        cameraCapture?.stop()
    }

    /// Start microphone capture if needed
    public func startMicrophoneIfNeeded() throws {
        guard needsMicrophone else { return }
        guard let mic = audioCapture else {
            log.warning("Microphone needed but not available", subsystem: LogSubsystem.microphone)
            return
        }
        try mic.startCapture()
        log.info("Microphone started", subsystem: LogSubsystem.microphone)
    }

    /// Stop microphone capture
    public func stopMicrophone() {
        audioCapture?.stopCapture()
    }

    /// Update audio texture (call each frame when microphone is active)
    public func updateAudioTextureIfNeeded() {
        guard needsMicrophone, let mic = audioCapture else { return }
        mic.updateTexture()
        if let texture = mic.getTexture() {
            delegate?.inputManager(self, didUpdateAudioTexture: texture)
        }
    }

    /// Stop all capture
    public func stopAll() {
        stopCamera()
        stopMicrophone()
    }

    /// Clean up all providers
    public func cleanup() {
        stopAll()
        providers.removeAll()
        cameraCapture = nil
        audioCapture = nil
    }
}
