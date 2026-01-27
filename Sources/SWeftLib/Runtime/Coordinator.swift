// Coordinator.swift - Thin orchestrator for multi-backend execution

import Foundation
import Metal
import MetalKit

// MARK: - Coordinator

/// Orchestrates WEFT program execution across multiple backends.
/// Delegates to specialized managers for input handling, compilation, and resources.
public class Coordinator: CameraCaptureDelegate, InputManagerDelegate, CompilationManagerDelegate {
    // MARK: - IR and Analysis

    public private(set) var program: IRProgram?
    public private(set) var dependencyGraph: DependencyGraph?
    public private(set) var annotatedProgram: IRAnnotatedProgram?
    public private(set) var swatchGraph: SwatchGraph?

    // MARK: - Managers

    /// Input provider management (camera, microphone, etc.)
    public let inputManager = InputManager()

    /// Compilation and backend management
    public let compilationManager = CompilationManager()

    /// Documentation manager
    public let docManager = SpindleDocManager.shared

    /// Backend registry
    public let registry: BackendRegistry

    // MARK: - Resource Managers (lazily initialized)

    private var _textureManager: TextureManager?
    private var _sampleManager: SampleManager?
    private var _textManager: TextManager?

    // MARK: - State

    /// Compiled units by swatch ID
    private var compiledUnits: [UUID: CompiledUnit] = [:]

    /// Source file URL for relative resource resolution
    public var sourceFileURL: URL? {
        didSet {
            compilationManager.sourceFileURL = sourceFileURL
        }
    }

    /// Current time
    public private(set) var time: Double = 0

    /// Whether the coordinator is running
    public private(set) var isRunning = false

    // MARK: - Initialization

    public init(registry: BackendRegistry = .shared) {
        self.registry = registry
        inputManager.delegate = self
        compilationManager.delegate = self
    }

    // MARK: - Public Accessors (Backward Compatibility)

    /// Metal backend instance
    public var metalBackend: MetalBackend? {
        compilationManager.metalBackend
    }

    /// Audio backend instance
    public var audioBackend: AudioBackend? {
        compilationManager.audioBackend
    }

    /// Buffer manager
    public var bufferManager: BufferManager {
        compilationManager.bufferManager
    }

    /// Cache manager
    public var cacheManager: CacheManager {
        compilationManager.cacheManager
    }

    /// Texture manager (lazily initialized)
    public var textureManager: TextureManager? {
        _textureManager
    }

    /// Sample manager (lazily initialized)
    public var sampleManager: SampleManager? {
        _sampleManager
    }

    /// Text manager (lazily initialized)
    public var textManager: TextManager? {
        _textManager
    }

    /// Camera capture instance
    public var cameraCapture: CameraCapture? {
        inputManager.cameraCapture
    }

    /// Audio capture instance
    public var audioCapture: AudioCapture? {
        inputManager.audioCapture
    }

    /// Whether camera is needed
    public var needsCamera: Bool {
        inputManager.needsCamera
    }

    /// Whether microphone is needed
    public var needsMicrophone: Bool {
        inputManager.needsMicrophone
    }

    // MARK: - Loading

    /// Load and compile an IR program
    public func load(program: IRProgram) throws {
        self.program = program

        // Build dependency graph
        let graph = DependencyGraph()
        graph.build(from: program)
        self.dependencyGraph = graph

        // Run annotation pass (merges both visual and audio specs)
        let allCoordinateSpecs = MetalBackend.coordinateSpecs
            .merging(AudioBackend.coordinateSpecs) { visual, _ in visual }
        let allPrimitiveSpecs = MetalBackend.primitiveSpecs
            .merging(AudioBackend.primitiveSpecs) { visual, _ in visual }

        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: allCoordinateSpecs,
            primitiveSpecs: allPrimitiveSpecs
        )
        let annotations = annotationPass.annotate()
        self.annotatedProgram = annotations

        // Partition into swatches
        let partitioner = Partitioner(
            program: program,
            graph: graph,
            annotations: annotations,
            registry: registry
        )
        let swatches = partitioner.partition()
        self.swatchGraph = swatches

        // Inline spindle calls with cache target substitution before cache analysis
        var mutableProgramForInlining = program
        IRTransformations.inlineSpindleCacheCalls(program: &mutableProgramForInlining)
        self.program = mutableProgramForInlining

        // Analyze cache nodes (now sees correct target references after spindle inlining)
        cacheManager.analyze(program: mutableProgramForInlining, annotations: annotations)

        // Transform program to break cache cycles (replace back-references with cacheRead)
        if var mutableProgram = self.program {
            cacheManager.transformProgramForCaches(program: &mutableProgram)
            self.program = mutableProgram
        }

        // Log analysis
        log.info("IR Loaded - Bundles: \(program.bundles.keys.sorted().joined(separator: ", "))", subsystem: LogSubsystem.coordinator)
        log.info("Swatches: \(swatches.swatches.count)", subsystem: LogSubsystem.coordinator)
        for swatch in swatches.swatches {
            log.debug("  \(swatch)", subsystem: LogSubsystem.coordinator)
        }

        // Compile
        try compile()
    }

    /// Load IR from JSON file
    public func load(url: URL) throws {
        sourceFileURL = url
        let parser = IRParser()
        let program = try parser.parse(url: url)
        try load(program: program)
    }

    /// Load IR from JSON string
    public func load(json: String) throws {
        let parser = IRParser()
        let program = try parser.parse(json: json)
        try load(program: program)
    }

    // MARK: - Compilation

    private func compile() throws {
        guard let program = program,
              let swatchGraph = swatchGraph else { return }

        // Reset state
        inputManager.resetHardwareNeeds()
        compiledUnits = [:]

        // Compile all swatches
        let result = try compilationManager.compile(program: program, swatchGraph: swatchGraph)
        compiledUnits = result.units

        // Start hardware capture as needed
        if result.needsCamera {
            try startCamera()
        } else {
            stopCamera()
        }

        if result.needsMicrophone {
            try startMicrophone()
        } else {
            stopMicrophone()
        }
    }

    // MARK: - Hardware Control

    /// Start camera capture
    public func startCamera() throws {
        try inputManager.startCameraIfNeeded()
        cameraCapture?.delegate = self
    }

    /// Stop camera capture
    public func stopCamera() {
        inputManager.stopCamera()
    }

    /// Start microphone capture
    public func startMicrophone() throws {
        try inputManager.startMicrophoneIfNeeded()
    }

    /// Stop microphone capture
    public func stopMicrophone() {
        inputManager.stopMicrophone()
    }

    /// Update audio buffer texture (call each frame)
    public func updateAudioTexture() {
        inputManager.updateAudioTextureIfNeeded()
    }

    // MARK: - CameraCaptureDelegate

    public func cameraCapture(_ capture: CameraCapture, didUpdateTexture texture: MTLTexture) {
        metalBackend?.cameraTexture = texture
    }

    // MARK: - InputManagerDelegate

    public func inputManagerNeedsMetalDevice(_ manager: InputManager) -> MTLDevice? {
        compilationManager.getMetalDevice()
    }

    public func inputManager(_ manager: InputManager, didUpdateCameraTexture texture: MTLTexture) {
        metalBackend?.cameraTexture = texture
    }

    public func inputManager(_ manager: InputManager, didUpdateAudioTexture texture: MTLTexture) {
        metalBackend?.audioBufferTexture = texture
    }

    // MARK: - CompilationManagerDelegate

    public func compilationManagerNeedsMetalDevice(_ manager: CompilationManager) -> MTLDevice? {
        manager.metalBackend?.device
    }

    public func compilationManager(
        _ manager: CompilationManager,
        needsTextureManagerWithDevice device: MTLDevice
    ) -> TextureManager {
        if _textureManager == nil {
            _textureManager = TextureManager(device: device)
        }
        return _textureManager!
    }

    public func compilationManager(
        _ manager: CompilationManager,
        needsTextManagerWithDevice device: MTLDevice
    ) -> TextManager {
        if _textManager == nil {
            _textManager = TextManager(device: device)
        }
        return _textManager!
    }

    public func compilationManagerNeedsSampleManager(_ manager: CompilationManager) -> SampleManager {
        if _sampleManager == nil {
            _sampleManager = SampleManager()
        }
        return _sampleManager!
    }

    public func compilationManager(
        _ manager: CompilationManager,
        needsProvidersForBackend backendId: String,
        swatch: Swatch,
        program: IRProgram
    ) -> [String: any InputProvider] {
        inputManager.collectProvidersForBackend(
            backendId: backendId,
            swatch: swatch,
            program: program
        )
    }

    // MARK: - Execution

    /// Execute one frame
    public func executeFrame(time: Double) {
        guard let swatches = swatchGraph?.topologicalSort() else { return }

        self.time = time

        for swatch in swatches {
            guard let unit = compiledUnits[swatch.id] else { continue }

            let inputs = bufferManager.getBuffers(names: swatch.inputBuffers)
            let outputs = bufferManager.getBuffers(names: swatch.outputBuffers)

            if swatch.backend == MetalBackend.identifier {
                metalBackend?.execute(unit: unit, inputs: inputs, outputs: outputs, time: time)
            } else if swatch.backend == AudioBackend.identifier {
                audioBackend?.execute(unit: unit, inputs: inputs, outputs: outputs, time: time)
            }
        }
    }

    /// Render visual output to drawable
    public func renderVisual(to drawable: CAMetalDrawable, time: Double) {
        guard let swatches = swatchGraph?.swatches else { return }

        // Update audio texture each frame
        updateAudioTexture()

        // Update dimensions
        compilationManager.setOutputDimensions(
            width: drawable.texture.width,
            height: drawable.texture.height
        )

        // Find visual sink swatch and render
        for swatch in swatches where swatch.backend == MetalBackend.identifier && swatch.isSink {
            if let unit = compiledUnits[swatch.id] {
                metalBackend?.render(unit: unit, to: drawable, time: time, cacheManager: cacheManager)
                return
            }
        }
    }

    /// Get the Metal backend for MTKView integration
    public func getMetalBackend() -> MetalBackend? {
        metalBackend
    }

    // MARK: - Audio Playback

    /// Start audio playback
    public func startAudio() throws {
        guard let swatches = swatchGraph?.swatches else { return }

        for swatch in swatches where swatch.backend == AudioBackend.identifier && swatch.isSink {
            if let unit = compiledUnits[swatch.id] {
                try audioBackend?.start(unit: unit, time: time)
                return
            }
        }
    }

    /// Stop audio playback
    public func stopAudio() {
        audioBackend?.stop()
    }

    // MARK: - Lifecycle

    /// Start the coordinator (visual + audio)
    public func start() throws {
        isRunning = true
        try startAudio()
    }

    /// Stop the coordinator
    public func stop() {
        isRunning = false
        stopAudio()
        inputManager.stopAll()
    }

    // MARK: - Dev Mode Accessors

    /// Get compiled shader source for a swatch (for dev mode)
    public func getCompiledShaderSource(for swatchId: UUID) -> String? {
        (compiledUnits[swatchId] as? MetalCompiledUnit)?.shaderSource
    }

    /// Get all compiled shader sources (for dev mode)
    public func getAllCompiledShaderSources() -> [UUID: String] {
        var sources: [UUID: String] = [:]
        for (id, unit) in compiledUnits {
            if let metalUnit = unit as? MetalCompiledUnit {
                sources[id] = metalUnit.shaderSource
            }
        }
        return sources
    }

    /// Get cache descriptors (for dev mode)
    public func getCacheDescriptors() -> [CacheNodeDescriptor]? {
        cacheManager.getDescriptors()
    }

    /// Get compiled units info (for dev mode)
    public func getCompiledUnitsInfo() -> [(swatchId: UUID, backend: String, usedInputs: Set<String>)] {
        compiledUnits.map { id, unit in
            if let metalUnit = unit as? MetalCompiledUnit {
                return (id, MetalBackend.identifier, metalUnit.usedInputs)
            } else {
                return (id, AudioBackend.identifier, [])
            }
        }
    }

    // MARK: - Resource Loading Status

    /// Get any texture loading errors
    public func getTextureLoadErrors() -> [Int: (path: String, error: TextureError)]? {
        textureManager?.loadErrors
    }

    /// Get any sample loading errors
    public func getSampleLoadErrors() -> [Int: (path: String, error: SampleError)]? {
        sampleManager?.loadErrors
    }

    /// Get a formatted string describing all resource loading errors
    public func getResourceErrorMessage() -> String? {
        var errors: [String] = []

        if let texErrors = textureManager?.loadErrors, !texErrors.isEmpty {
            for (_, info) in texErrors.sorted(by: { $0.key < $1.key }) {
                errors.append("Image '\(info.path)': \(info.error.localizedDescription)")
            }
        }

        if let smpErrors = sampleManager?.loadErrors, !smpErrors.isEmpty {
            for (_, info) in smpErrors.sorted(by: { $0.key < $1.key }) {
                errors.append("Audio '\(info.path)': \(info.error.localizedDescription)")
            }
        }

        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    // MARK: - Documentation

    /// Get documentation for a spindle or builtin by name
    public func documentation(for name: String) -> SpindleDoc? {
        docManager.documentation(for: name)
    }

    // MARK: - Input Provider Registration (Backward Compatibility)

    /// Register an input provider
    public func registerInputProvider(_ provider: any InputProvider) {
        inputManager.register(provider)
    }

    /// Get typed input provider by builtin name
    public func inputProvider<T: InputProvider>(for builtinName: String) -> T? {
        inputManager.provider(for: builtinName)
    }
}
