// AudioBackend.swift - CoreAudio backend for audio synthesis

import Foundation
import AVFoundation

// MARK: - Audio Compiled Unit

public class AudioCompiledUnit: CompiledUnit {
    public let swatchId: UUID
    public let renderFunction: AudioRenderFunction
    public let scopeFunction: ScopeRenderFunction?
    public let scopeStrandNames: [String]

    /// Cross-domain output evaluators: [(bundleName, [(strandName, evaluator)])]
    public let outputEvaluators: [(String, [(String, (AudioContext) -> Float)])]

    /// Layout scope functions: [(bundleName, renderFunction, strandNames)]
    public let layoutScopeFunctions: [(String, ScopeRenderFunction, [String])]

    /// Layout scope info for creating ScopeBuffers: [(bundleName, strandNames)]
    public var layoutScopeInfo: [(String, [String])] {
        layoutScopeFunctions.map { ($0.0, $0.2) }
    }

    public init(
        swatchId: UUID,
        renderFunction: @escaping AudioRenderFunction,
        scopeFunction: ScopeRenderFunction? = nil,
        scopeStrandNames: [String] = [],
        outputEvaluators: [(String, [(String, (AudioContext) -> Float)])] = [],
        layoutScopeFunctions: [(String, ScopeRenderFunction, [String])] = []
    ) {
        self.swatchId = swatchId
        self.renderFunction = renderFunction
        self.scopeFunction = scopeFunction
        self.scopeStrandNames = scopeStrandNames
        self.outputEvaluators = outputEvaluators
        self.layoutScopeFunctions = layoutScopeFunctions
    }
}

// MARK: - Audio Backend

public class AudioBackend: Backend {
    public static let identifier = "audio"
    public static let hardwareOwned: Set<IRHardware> = [.microphone, .speaker]
    public static let ownedBuiltins: Set<String> = ["microphone", "sample"]
    public static let externalBuiltins: Set<String> = ["microphone", "sample"]
    public static let statefulBuiltins: Set<String> = ["cache", "microphone"]
    public static let coordinateFields = ["i", "t", "sampleRate"]

    // MARK: - Domain Annotation Specs

    /// Coordinate dimensions for audio domain
    public static let coordinateSpecs: [String: IRDimension] = [
        "i": IRDimension(name: "i", access: .free),
        "t": IRDimension(name: "t", access: .free),  // derived from i, so seekable
        "sampleRate": IRDimension(name: "sampleRate", access: .bound),
    ]

    /// Primitive specifications for audio domain builtins
    public static let primitiveSpecs: [String: PrimitiveSpec] = [
        "microphone": PrimitiveSpec(
            name: "microphone",
            outputDomain: [IRDimension(name: "t", access: .bound)],
            hardwareRequired: [.microphone],
            addsState: false
        ),
        "sample": PrimitiveSpec(
            name: "sample",
            outputDomain: [IRDimension(name: "t", access: .free)],
            hardwareRequired: [.speaker],
            addsState: false
        ),
        "cache": PrimitiveSpec(
            name: "cache",
            outputDomain: [],
            hardwareRequired: [],
            addsState: true
        ),
    ]

    public static let bindings: [BackendBinding] = [
        // Input
        .input(InputBinding(
            builtinName: "microphone",
            shaderParam: nil,
            textureIndex: nil  // CPU callback, no GPU texture
        )),
        // Output
        .output(OutputBinding(
            bundleName: "play",
            kernelName: "audioCallback"
        )),
        .output(OutputBinding(
            bundleName: "scope",
            kernelName: "scopeCallback"
        ))
    ]

    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var currentUnit: AudioCompiledUnit?
    private var sampleRate: Double = 44100
    private var sampleIndex: Int = 0
    private var startTime: Double = 0

    /// Loaded audio samples by resource ID - set by SampleManager via Coordinator
    public var loadedSamples: [Int: AudioSampleBuffer] = [:]

    /// Scope buffer for oscilloscope data -- set by Coordinator
    public var scopeBuffer: ScopeBuffer?

    /// Per-bundle scope buffers for audio layout previews -- set by Coordinator
    public var layoutScopeBuffers: [String: ScopeBuffer] = [:]

    /// Cross-domain output buffers -- set by Coordinator
    public var crossDomainOutputBuffers: [String: CrossDomainBuffer] = [:]

    /// Input providers set via setInputProviders
    private var inputProviders: [String: any InputProvider] = [:]

    /// Audio input source (microphone) - deprecated, use setInputProviders instead
    @available(*, deprecated, message: "Use setInputProviders instead")
    public weak var audioInput: AudioInputSource?

    public init() {}

    // MARK: - Input Provider Management

    public func setInputProviders(_ providers: [String: any InputProvider]) {
        self.inputProviders = providers
    }

    /// Compile swatch to audio render function (without cache support)
    public func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit {
        return try compile(swatch: swatch, ir: ir, cacheManager: nil)
    }

    /// Compile swatch to audio render function with cache manager
    public func compile(swatch: Swatch, ir: IRProgram, cacheManager: CacheManager?, layoutBundles: [String] = []) throws -> CompiledUnit {
        let codegen = AudioCodeGen(program: ir, swatch: swatch, cacheManager: cacheManager)

        // Pass loaded samples to codegen
        codegen.loadedSamples = loadedSamples

        // Pass audio input (microphone) to codegen from providers
        if let micProvider = inputProviders["microphone"] as? AudioInputProvider {
            codegen.audioInput = micProvider
        } else if let legacyInput = audioInput {
            // Fallback to legacy audioInput for backward compatibility
            codegen.audioInput = legacyInput
        }

        let renderFunction = try codegen.generateRenderFunction()
        let scopeResult = try codegen.generateScopeFunction()
        let layoutScopeResults = try codegen.generateLayoutScopeFunctions(bundles: layoutBundles)

        // Generate cross-domain output evaluators if this swatch has output buffers
        let outputEvaluators = try codegen.generateOutputEvaluators(outputBundles: swatch.outputBuffers)

        print("Audio backend compiled successfully")

        return AudioCompiledUnit(
            swatchId: swatch.id,
            renderFunction: renderFunction,
            scopeFunction: scopeResult?.0,
            scopeStrandNames: scopeResult?.1 ?? [],
            outputEvaluators: outputEvaluators,
            layoutScopeFunctions: layoutScopeResults
        )
    }

    /// Execute compiled unit (fill buffer)
    public func execute(
        unit: CompiledUnit,
        inputs: [String: any Buffer],
        outputs: [String: any Buffer],
        time: Double
    ) {
        guard let audioUnit = unit as? AudioCompiledUnit else { return }

        // If there's an audio output buffer, fill it
        for (_, buffer) in outputs {
            if let audioBuffer = buffer as? AudioBuffer {
                fillBuffer(audioBuffer, with: audioUnit.renderFunction, time: time)
            }
        }
    }

    /// Fill audio buffer with samples
    private func fillBuffer(_ buffer: AudioBuffer, with render: AudioRenderFunction, time: Double) {
        for i in 0..<buffer.samples.count {
            let sampleTime = time + Double(i) / buffer.sampleRate
            let (left, _) = render(i, sampleTime, buffer.sampleRate)
            buffer.samples[i] = left
        }
    }

    /// Start audio playback
    public func start(unit: CompiledUnit, time: Double = 0) throws {
        guard let audioUnit = unit as? AudioCompiledUnit else {
            throw BackendError.executionFailed("Invalid audio unit")
        }

        // Stop existing playback
        stop()

        currentUnit = audioUnit
        startTime = time
        sampleIndex = 0

        // Create audio engine
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw BackendError.executionFailed("Could not create audio engine")
        }

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = outputFormat.sampleRate

        // Create source node
        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self, let unit = self.currentUnit else {
                return noErr
            }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let scopeBuffer = self.scopeBuffer
            let scopeFn = unit.scopeFunction
            let layoutBuffers = self.layoutScopeBuffers
            let layoutFns = unit.layoutScopeFunctions

            var scopeFrames: [[Float]] = []
            var layoutFrames: [String: [[Float]]] = [:]

            for frame in 0..<Int(frameCount) {
                let currentSampleIndex = self.sampleIndex + frame
                let currentTime = self.startTime + Double(currentSampleIndex) / self.sampleRate

                let (left, right) = unit.renderFunction(currentSampleIndex, currentTime, self.sampleRate)

                // Write to audio output buffers
                for bufferIndex in 0..<ablPointer.count {
                    let buffer = ablPointer[bufferIndex]
                    let samples = buffer.mData?.assumingMemoryBound(to: Float.self)
                    samples?[frame] = bufferIndex == 0 ? left : right
                }

                // Evaluate scope strands
                if let scopeFn = scopeFn {
                    let scopeValues = scopeFn(currentSampleIndex, currentTime, self.sampleRate)
                    scopeFrames.append(scopeValues)
                }

                // Evaluate layout scope strands
                for (bundleName, fn, _) in layoutFns {
                    let values = fn(currentSampleIndex, currentTime, self.sampleRate)
                    layoutFrames[bundleName, default: []].append(values)
                }
            }

            // Batch write scope data outside the per-frame loop
            if !scopeFrames.isEmpty {
                scopeBuffer?.write(values: scopeFrames)
            }

            // Batch write layout scope data
            for (bundleName, frames) in layoutFrames {
                layoutBuffers[bundleName]?.write(values: frames)
            }

            // Write cross-domain output values (once per callback, using last sample's time)
            if !unit.outputEvaluators.isEmpty {
                let lastSampleIndex = self.sampleIndex + Int(frameCount) - 1
                let lastTime = self.startTime + Double(lastSampleIndex) / self.sampleRate
                let ctx = AudioContext(sampleIndex: lastSampleIndex, time: lastTime, sampleRate: self.sampleRate)
                let outputBuffers = self.crossDomainOutputBuffers
                for (bundleName, strandEvals) in unit.outputEvaluators {
                    if let buffer = outputBuffers[bundleName] {
                        for (i, (_, eval)) in strandEvals.enumerated() where i < buffer.data.count {
                            buffer.data[i] = eval(ctx)
                        }
                    }
                }
            }

            self.sampleIndex += Int(frameCount)
            return noErr
        }

        guard let sourceNode = sourceNode else {
            throw BackendError.executionFailed("Could not create source node")
        }

        // Connect nodes
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: outputFormat)

        // Start engine
        do {
            try engine.start()
            print("Audio engine started at sample rate: \(sampleRate)")
        } catch {
            throw BackendError.executionFailed("Could not start audio engine: \(error.localizedDescription)")
        }
    }

    /// Stop audio playback
    public func stop() {
        audioEngine?.stop()
        if let sourceNode = sourceNode {
            audioEngine?.detach(sourceNode)
        }
        sourceNode = nil
        audioEngine = nil
        currentUnit = nil
    }

    /// Check if audio is playing
    public var isPlaying: Bool {
        audioEngine?.isRunning ?? false
    }

    /// Get current playback time
    public var currentTime: Double {
        startTime + Double(sampleIndex) / sampleRate
    }
}
