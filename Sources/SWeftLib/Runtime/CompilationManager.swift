// CompilationManager.swift - Manages swatch compilation and backend initialization

import Foundation
import Metal

// MARK: - Compilation Manager Delegate

/// Protocol for CompilationManager to request resources from its owner
public protocol CompilationManagerDelegate: AnyObject {
    /// Get the Metal device
    func compilationManagerNeedsMetalDevice(_ manager: CompilationManager) -> MTLDevice?

    /// Get texture manager for loading textures
    func compilationManager(_ manager: CompilationManager, needsTextureManagerWithDevice device: MTLDevice) -> TextureManager

    /// Get text manager for rendering text
    func compilationManager(_ manager: CompilationManager, needsTextManagerWithDevice device: MTLDevice) -> TextManager

    /// Get sample manager for loading audio
    func compilationManagerNeedsSampleManager(_ manager: CompilationManager) -> SampleManager

    /// Get input providers for a backend
    func compilationManager(
        _ manager: CompilationManager,
        needsProvidersForBackend backendId: String,
        swatch: Swatch,
        program: IRProgram
    ) -> [String: any InputProvider]
}

// MARK: - Compilation Result

/// Result of compiling a program
public struct CompilationResult {
    /// Compiled units by swatch ID
    public let units: [UUID: CompiledUnit]

    /// Whether camera is needed
    public let needsCamera: Bool

    /// Whether microphone is needed
    public let needsMicrophone: Bool
}

// MARK: - Compilation Manager

/// Handles compilation of swatches to backend-specific code.
/// Extracted from Coordinator to follow Single Responsibility Principle.
public class CompilationManager {
    /// Delegate for resource access
    public weak var delegate: CompilationManagerDelegate?

    /// Metal backend (lazily initialized)
    public private(set) var metalBackend: MetalBackend?

    /// Audio backend (lazily initialized)
    public private(set) var audioBackend: AudioBackend?

    /// Buffer manager for inter-swatch data flow
    public private(set) var bufferManager: BufferManager

    /// Cache manager for feedback effects
    public let cacheManager: CacheManager

    /// Source file URL for resource resolution
    public var sourceFileURL: URL?

    /// Output dimensions for cache buffers
    private var outputWidth: Int = 512
    private var outputHeight: Int = 512

    public init() {
        self.bufferManager = BufferManager()
        self.cacheManager = CacheManager()
    }

    // MARK: - Compilation

    /// Compile all swatches in the swatch graph
    /// - Parameters:
    ///   - program: The IR program
    ///   - swatchGraph: The swatch graph from partitioning
    /// - Returns: Compilation result with compiled units and hardware requirements
    public func compile(
        program: IRProgram,
        swatchGraph: SwatchGraph
    ) throws -> CompilationResult {
        var compiledUnits: [UUID: CompiledUnit] = [:]
        var needsCamera = false
        var needsMicrophone = false

        for swatch in swatchGraph.swatches {
            if swatch.backend == MetalBackend.identifier {
                let (unit, usedInputs) = try compileMetalSwatch(swatch, program: program)
                compiledUnits[swatch.id] = unit

                if usedInputs.contains("camera") {
                    needsCamera = true
                }
                if usedInputs.contains("microphone") {
                    needsMicrophone = true
                }

            } else if swatch.backend == AudioBackend.identifier {
                let (unit, usedMic) = try compileAudioSwatch(swatch, program: program)
                compiledUnits[swatch.id] = unit

                if usedMic {
                    needsMicrophone = true
                }
            }
            // Unknown backend - skip (pure swatches or future backends)
        }

        return CompilationResult(
            units: compiledUnits,
            needsCamera: needsCamera,
            needsMicrophone: needsMicrophone
        )
    }

    // MARK: - Metal Compilation

    private func compileMetalSwatch(
        _ swatch: Swatch,
        program: IRProgram
    ) throws -> (CompiledUnit, Set<String>) {
        // Initialize Metal backend if needed
        if metalBackend == nil {
            metalBackend = try MetalBackend()
            bufferManager = BufferManager(metalDevice: metalBackend?.device)
        }

        guard let device = metalBackend?.device else {
            throw BackendError.initializationFailed("Metal device not available")
        }

        // Load textures
        if !program.resources.isEmpty {
            if let texMgr = delegate?.compilationManager(self, needsTextureManagerWithDevice: device) {
                do {
                    let resolver = ResourcePathResolver(sourceFileURL: sourceFileURL)
                    let loadedTextures = try texMgr.loadTextures(
                        resources: program.resources,
                        sourceFileURL: sourceFileURL
                    )
                    metalBackend?.loadedTextures = loadedTextures
                    log.info("Loaded \(loadedTextures.count) textures", subsystem: LogSubsystem.texture)
                } catch {
                    log.warning("Texture loading failed: \(error)", subsystem: LogSubsystem.texture)
                }
            }
        }

        // Render text textures
        if !program.textResources.isEmpty {
            if let txtMgr = delegate?.compilationManager(self, needsTextManagerWithDevice: device) {
                do {
                    let renderedTexts = try txtMgr.renderTexts(program.textResources)
                    metalBackend?.textTextures = renderedTexts
                    log.info("Rendered \(renderedTexts.count) text textures", subsystem: LogSubsystem.text)
                } catch {
                    log.warning("Text rendering failed: \(error)", subsystem: LogSubsystem.text)
                }
            }
        }

        // Allocate cache buffers
        if !cacheManager.getDescriptors().isEmpty {
            cacheManager.allocateBuffers(
                device: device,
                width: outputWidth,
                height: outputHeight
            )
        }

        // Collect input providers
        let providers = delegate?.compilationManager(
            self,
            needsProvidersForBackend: MetalBackend.identifier,
            swatch: swatch,
            program: program
        ) ?? [:]
        metalBackend!.setInputProviders(providers)

        // Compile
        let unit = try metalBackend!.compile(
            swatch: swatch,
            ir: program,
            cacheDescriptors: cacheManager.getDescriptors()
        )

        // Extract used inputs
        var usedInputs: Set<String> = []
        if let metalUnit = unit as? MetalCompiledUnit {
            usedInputs = metalUnit.usedInputs
        }

        return (unit, usedInputs)
    }

    // MARK: - Audio Compilation

    private func compileAudioSwatch(
        _ swatch: Swatch,
        program: IRProgram
    ) throws -> (CompiledUnit, Bool) {
        // Initialize Audio backend if needed
        if audioBackend == nil {
            audioBackend = AudioBackend()
        }

        // Load audio samples
        if !program.resources.isEmpty {
            if let smpMgr = delegate?.compilationManagerNeedsSampleManager(self) {
                do {
                    let loadedSamples = try smpMgr.loadSamples(
                        resources: program.resources,
                        sourceFileURL: sourceFileURL
                    )
                    audioBackend?.loadedSamples = loadedSamples
                    if !loadedSamples.isEmpty {
                        log.info("Loaded \(loadedSamples.count) audio samples", subsystem: LogSubsystem.sample)
                    }
                } catch {
                    log.warning("Sample loading failed: \(error)", subsystem: LogSubsystem.sample)
                }
            }
        }

        // Collect input providers
        let providers = delegate?.compilationManager(
            self,
            needsProvidersForBackend: AudioBackend.identifier,
            swatch: swatch,
            program: program
        ) ?? [:]
        audioBackend!.setInputProviders(providers)

        let usesMicrophone = providers["microphone"] != nil

        // Compile with cache manager
        let unit = try audioBackend!.compile(
            swatch: swatch,
            ir: program,
            cacheManager: cacheManager
        )

        return (unit, usesMicrophone)
    }

    // MARK: - Output Dimensions

    /// Update output dimensions (affects cache buffer allocation)
    public func setOutputDimensions(width: Int, height: Int) {
        if width != outputWidth || height != outputHeight {
            outputWidth = width
            outputHeight = height
            cacheManager.resizeBuffers(width: width, height: height)
        }
    }

    /// Get the Metal device if available
    public func getMetalDevice() -> MTLDevice? {
        metalBackend?.device
    }
}
