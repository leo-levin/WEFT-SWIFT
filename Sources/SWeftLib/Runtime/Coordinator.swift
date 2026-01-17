// Coordinator.swift - Orchestrate multi-backend execution

import Foundation
import Metal
import MetalKit

// MARK: - Coordinator

public class Coordinator: CameraCaptureDelegate {
    // IR and analysis
    public private(set) var program: IRProgram?
    public private(set) var dependencyGraph: DependencyGraph?
    public private(set) var ownershipAnalysis: OwnershipAnalysis?
    public private(set) var purityAnalysis: PurityAnalysis?
    public private(set) var swatchGraph: SwatchGraph?

    // Backends
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

    // State
    public private(set) var time: Double = 0
    public private(set) var isRunning = false

    public init() {
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

        // Analyze ownership
        let ownership = OwnershipAnalysis()
        ownership.analyze(program: program)
        self.ownershipAnalysis = ownership

        // Analyze purity
        let purity = PurityAnalysis()
        purity.analyze(program: program)
        self.purityAnalysis = purity

        // Partition into swatches
        let partitioner = Partitioner(
            program: program,
            ownership: ownership,
            purity: purity,
            graph: graph
        )
        let swatches = partitioner.partition()
        self.swatchGraph = swatches

        // Analyze cache nodes
        cacheManager.analyze(program: program)

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
                }

                let unit = try metalBackend!.compile(swatch: swatch, ir: program)
                compiledUnits[swatch.id] = unit

                // Check if this unit needs camera or microphone
                if let metalUnit = unit as? MetalCompiledUnit {
                    if metalUnit.needsCamera {
                        needsCamera = true
                    }
                    if metalUnit.needsMicrophone {
                        needsMicrophone = true
                    }
                }

            case .audio:
                // Initialize Audio backend if needed
                if audioBackend == nil {
                    audioBackend = AudioBackend()
                }

                let unit = try audioBackend!.compile(swatch: swatch, ir: program)
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

        // Find visual sink swatch
        for swatch in swatches where swatch.backend == .visual && swatch.isSink {
            if let unit = compiledUnits[swatch.id] {
                metalBackend?.render(unit: unit, to: drawable, time: time)
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
}
