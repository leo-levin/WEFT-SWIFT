// Coordinator.swift - Orchestrate multi-backend execution

import Foundation
import Metal
import MetalKit

// MARK: - Coordinator

public class Coordinator: CameraCaptureDelegate {
    // IR and analysis
    public private(set) var program: IRProgram?
    public private(set) var dependencyGraph: DependencyGraph?
    public private(set) var annotatedProgram: IRAnnotatedProgram?
    public private(set) var swatchGraph: SwatchGraph?

    // Backend registry
    public let registry: BackendRegistry

    // Backend instances (lazily initialized)
    public private(set) var metalBackend: MetalBackend?
    public private(set) var audioBackend: AudioBackend?

    // Camera
    public private(set) var cameraCapture: CameraCapture?
    public private(set) var needsCamera = false

    // Audio capture (microphone)
    public private(set) var audioCapture: AudioCapture?
    public private(set) var needsMicrophone = false

    // Compiled units
    private var compiledUnits: [UUID: CompiledUnit] = [:]

    // Managers
    public private(set) var bufferManager: BufferManager
    public private(set) var cacheManager: CacheManager
    public private(set) var textureManager: TextureManager?
    public private(set) var sampleManager: SampleManager?

    // Source file URL for relative resource resolution
    public var sourceFileURL: URL?

    // State
    public private(set) var time: Double = 0
    public private(set) var isRunning = false

    // Default output dimensions
    private var outputWidth: Int = 512
    private var outputHeight: Int = 512

    public init(registry: BackendRegistry = .shared) {
        self.registry = registry
        self.bufferManager = BufferManager()
        self.cacheManager = CacheManager()
    }

    // MARK: - CameraCaptureDelegate

    public func cameraCapture(_ capture: CameraCapture, didUpdateTexture texture: MTLTexture) {
        metalBackend?.cameraTexture = texture
    }

    /// Load and compile an IR program
    public func load(program: IRProgram) throws {
        self.program = program

        // Build dependency graph
        let graph = DependencyGraph()
        graph.build(from: program)
        self.dependencyGraph = graph

        // Run annotation pass (merges both visual and audio specs)
        let allCoordinateSpecs = MetalBackend.coordinateSpecs
            .merging(AudioBackend.coordinateSpecs) { (visual, _) in visual }
        let allPrimitiveSpecs = MetalBackend.primitiveSpecs
            .merging(AudioBackend.primitiveSpecs) { (visual, _) in visual }

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

        // Analyze cache nodes
        cacheManager.analyze(program: program, annotations: annotations)

        // Transform program to break cache cycles (replace back-references with cacheRead)
        if var mutableProgram = self.program {
            cacheManager.transformProgramForCaches(program: &mutableProgram)
            self.program = mutableProgram
        }

        // Print analysis
        print("=== WEFT IR Loaded ===")
        print("Bundles: \(program.bundles.keys.sorted().joined(separator: ", "))")
        print("Swatches: \(swatches.swatches.count)")
        for swatch in swatches.swatches {
            print("  \(swatch)")
        }

        // Compile swatches
        try compile()
    }

    /// Load IR from JSON file
    public func load(url: URL) throws {
        // Store the source file URL for relative resource resolution
        self.sourceFileURL = url
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

    /// Compile all swatches
    private func compile() throws {
        guard let program = program,
              let swatches = swatchGraph?.swatches else { return }

        compiledUnits = [:]
        needsCamera = false
        needsMicrophone = false

        for swatch in swatches {
            switch swatch.backend {
            case .visual:
                // Initialize Metal backend if needed
                if metalBackend == nil {
                    metalBackend = try MetalBackend()
                    bufferManager = BufferManager(metalDevice: metalBackend?.device)

                    // Initialize texture manager
                    if let device = metalBackend?.device {
                        textureManager = TextureManager(device: device)
                    }
                }

                // Load textures from program resources if any
                if !program.resources.isEmpty, let texMgr = textureManager {
                    do {
                        let loadedTextures = try texMgr.loadTextures(
                            resources: program.resources,
                            sourceFileURL: sourceFileURL
                        )
                        metalBackend?.loadedTextures = loadedTextures
                        print("Coordinator: Loaded \(loadedTextures.count) textures")
                    } catch {
                        print("Coordinator: Warning - texture loading failed: \(error)")
                    }
                }

                // Always (re)allocate cache buffers when we have cache descriptors
                // This handles both initial load and recompiles with new cache nodes
                if let device = metalBackend?.device, !cacheManager.getDescriptors().isEmpty {
                    cacheManager.allocateBuffers(
                        device: device,
                        width: outputWidth,
                        height: outputHeight
                    )
                }

                // Pass cache descriptors to codegen via backend
                let unit = try metalBackend!.compile(
                    swatch: swatch,
                    ir: program,
                    cacheDescriptors: cacheManager.getDescriptors()
                )
                compiledUnits[swatch.id] = unit

                // Check if this unit needs camera or microphone (from usedInputs)
                if let metalUnit = unit as? MetalCompiledUnit {
                    if metalUnit.usedInputs.contains("camera") {
                        needsCamera = true
                    }
                    if metalUnit.usedInputs.contains("microphone") {
                        needsMicrophone = true
                    }
                }

            case .audio:
                // Initialize Audio backend if needed
                if audioBackend == nil {
                    audioBackend = AudioBackend()

                    // Initialize sample manager
                    sampleManager = SampleManager()
                }

                // Load audio samples from program resources if any
                if !program.resources.isEmpty, let smpMgr = sampleManager {
                    do {
                        let loadedSamples = try smpMgr.loadSamples(
                            resources: program.resources,
                            sourceFileURL: sourceFileURL
                        )
                        audioBackend?.loadedSamples = loadedSamples
                        if !loadedSamples.isEmpty {
                            print("Coordinator: Loaded \(loadedSamples.count) audio samples")
                        }
                    } catch {
                        print("Coordinator: Warning - sample loading failed: \(error)")
                    }
                }

                // Pass cache manager to audio backend for shared buffer access
                let unit = try audioBackend!.compile(
                    swatch: swatch,
                    ir: program,
                    cacheManager: cacheManager
                )
                compiledUnits[swatch.id] = unit

            case .none:
                // Pure swatch - skip
                break
            }
        }

        // Start camera if needed
        if needsCamera {
            try startCamera()
        } else {
            stopCamera()
        }

        // Start microphone if needed
        if needsMicrophone {
            try startMicrophone()
        } else {
            stopMicrophone()
        }
    }

    /// Start camera capture
    public func startCamera() throws {
        guard let device = metalBackend?.device else {
            print("Coordinator: Cannot start camera - no Metal device")
            return
        }

        if cameraCapture == nil {
            cameraCapture = CameraCapture(device: device)
            cameraCapture?.delegate = self
        }

        try cameraCapture?.start()
        print("Coordinator: Camera started")
    }

    /// Stop camera capture
    public func stopCamera() {
        cameraCapture?.stop()
    }

    /// Start microphone capture
    public func startMicrophone() throws {
        guard let device = metalBackend?.device else {
            print("Coordinator: Cannot start microphone - no Metal device")
            return
        }

        if audioCapture == nil {
            audioCapture = AudioCapture()
            try audioCapture?.setup(device: device)
        }

        try audioCapture?.startCapture()
        print("Coordinator: Microphone started")
    }

    /// Stop microphone capture
    public func stopMicrophone() {
        audioCapture?.stopCapture()
    }

    /// Update audio buffer texture (call each frame)
    public func updateAudioTexture() {
        guard needsMicrophone, let audioCapture = audioCapture else { return }
        audioCapture.updateTexture()
        metalBackend?.audioBufferTexture = audioCapture.getTexture()
    }

    /// Execute one frame
    public func executeFrame(time: Double) {
        guard let swatches = swatchGraph?.topologicalSort() else { return }

        self.time = time

        for swatch in swatches {
            guard let unit = compiledUnits[swatch.id] else { continue }

            // Get input/output buffers
            let inputs = bufferManager.getBuffers(names: swatch.inputBuffers)
            let outputs = bufferManager.getBuffers(names: swatch.outputBuffers)

            switch swatch.backend {
            case .visual:
                metalBackend?.execute(unit: unit, inputs: inputs, outputs: outputs, time: time)
            case .audio:
                audioBackend?.execute(unit: unit, inputs: inputs, outputs: outputs, time: time)
            case .none:
                break
            }
        }
    }

    /// Render visual output to drawable
    public func renderVisual(to drawable: CAMetalDrawable, time: Double) {
        guard let swatches = swatchGraph?.swatches else { return }

        // Update audio texture each frame
        updateAudioTexture()

        // Resize cache buffers if needed (drawable size might differ from default)
        let newWidth = drawable.texture.width
        let newHeight = drawable.texture.height
        if newWidth != outputWidth || newHeight != outputHeight {
            outputWidth = newWidth
            outputHeight = newHeight
            cacheManager.resizeBuffers(width: newWidth, height: newHeight)
        }

        // Find visual sink swatch
        for swatch in swatches where swatch.backend == .visual && swatch.isSink {
            if let unit = compiledUnits[swatch.id] {
                metalBackend?.render(unit: unit, to: drawable, time: time, cacheManager: cacheManager)
                return
            }
        }
    }

    /// Get the Metal backend for MTKView integration
    public func getMetalBackend() -> MetalBackend? {
        return metalBackend
    }

    /// Start audio playback
    public func startAudio() throws {
        guard let swatches = swatchGraph?.swatches else { return }

        // Find audio sink swatch
        for swatch in swatches where swatch.backend == .audio && swatch.isSink {
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

    /// Start the coordinator (visual + audio)
    public func start() throws {
        isRunning = true
        try startAudio()
    }

    /// Stop the coordinator
    public func stop() {
        isRunning = false
        stopAudio()
        stopCamera()
        stopMicrophone()
    }

    // MARK: - Dev Mode Accessors

    /// Get compiled shader source for a swatch (for dev mode)
    public func getCompiledShaderSource(for swatchId: UUID) -> String? {
        guard let unit = compiledUnits[swatchId] as? MetalCompiledUnit else {
            return nil
        }
        return unit.shaderSource
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
        return cacheManager.getDescriptors()
    }

    /// Get compiled units info (for dev mode)
    public func getCompiledUnitsInfo() -> [(swatchId: UUID, backend: BackendDomain, usedInputs: Set<String>)] {
        var info: [(UUID, BackendDomain, Set<String>)] = []
        for (id, unit) in compiledUnits {
            if let metalUnit = unit as? MetalCompiledUnit {
                info.append((id, .visual, metalUnit.usedInputs))
            } else {
                info.append((id, .audio, []))
            }
        }
        return info
    }

    // MARK: - Resource Loading Status

    /// Get any texture loading errors
    public func getTextureLoadErrors() -> [Int: (path: String, error: TextureError)]? {
        return textureManager?.loadErrors
    }

    /// Get any sample loading errors
    public func getSampleLoadErrors() -> [Int: (path: String, error: SampleError)]? {
        return sampleManager?.loadErrors
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
}
