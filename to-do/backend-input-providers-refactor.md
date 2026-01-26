# Refactor: Generic Backend Input Providers

## Pre-Implementation Checklist

**Before implementing, read and understand:**

1. **Docs/signal-backend.md** - Core signal model, backend architecture, hardware ownership
   - Documents the vision: "No edits to Partitioner, Coordinator, or IRAnnotations needed" for new backends
   - Defines `hardwareOwned`, `coordinateSpecs`, `primitiveSpecs`
   - Shows MIDIBackend example

2. **Sources/SWeftLib/Backends/Backend.swift** - Backend protocol, bindings, existing abstractions
   - Check if `setInputProviders` or similar already exists
   - Review `BackendBinding`, `InputBinding`, `OutputBinding`

3. **Sources/SWeftLib/Backends/BackendRegistry.swift** - Registry pattern, lookup methods
   - `allInputBindings`, `externalBuiltins`, `backendOwning(hardware:)`
   - May already have infrastructure we can use

4. **Sources/SWeftLib/Backends/SharedBuiltins.swift** - Shared builtin definitions
   - Check for existing input provider patterns

5. **Sources/SWeftLib/Runtime/Coordinator.swift** - Current wiring, what's hardcoded vs generic
   - Understand existing camera/microphone setup flow
   - Identify all hardcoded backend-specific code

6. **Check AudioCapture and CameraCapture** - See if they already conform to common protocols

**Goal: Align implementation with documented architecture vision.**

---

## Problem

Currently, hardware inputs are wired up with backend-specific properties:

```swift
// AudioBackend.swift
public weak var audioInput: AudioInputSource?

// Coordinator.swift
audioBackend?.audioInput = audioCapture  // Hardcoded microphone wiring
```

This violates the extensibility design. If someone adds a new backend with new inputs (MIDI, OSC, game controller), they have to modify Coordinator with specific wiring code.

## Goal

Backends should declare their input requirements via the existing `bindings` mechanism, and the Coordinator should wire them up generically without knowing what specific inputs each backend needs.

## Current Architecture

```swift
// Backend declares bindings
public static let bindings: [BackendBinding] = [
    .input(InputBinding(builtinName: "microphone", ...)),
    .output(OutputBinding(bundleName: "play", ...))
]

// BackendRegistry provides lookups
BackendRegistry.shared.allInputBindings  // "microphone" -> (backendId, InputBinding)
BackendRegistry.shared.externalBuiltins(for: "audio")  // ["microphone", "sample"]
```

## Proposed Changes

### 1. Add InputProvider Protocol

```swift
// New file: Sources/SWeftLib/Backends/InputProvider.swift

/// Protocol for hardware input providers
public protocol InputProvider: AnyObject {
    /// Unique identifier matching the builtin name (e.g., "microphone", "camera")
    static var builtinName: String { get }

    /// Hardware type this provider requires
    static var hardware: IRHardware { get }

    /// Setup the provider (request permissions, initialize hardware)
    func setup(device: MTLDevice?) throws

    /// Start capturing/receiving input
    func start() throws

    /// Stop capturing
    func stop()
}

/// Audio input specifically (microphone)
public protocol AudioInputProvider: InputProvider {
    func getSample(at sampleIndex: Int, channel: Int) -> Float
}

/// Visual input (camera, textures)
public protocol VisualInputProvider: InputProvider {
    var texture: MTLTexture? { get }
}
```

### 2. Modify AudioCapture to Conform

```swift
extension AudioCapture: AudioInputProvider {
    public static var builtinName: String { "microphone" }
    public static var hardware: IRHardware { .microphone }
    // Already has getSample, setup, start, stop
}
```

### 3. Add Generic Input Registry to Coordinator

```swift
// Coordinator.swift
public class Coordinator {
    /// Registered input providers by builtin name
    private var inputProviders: [String: any InputProvider] = [:]

    /// Register an input provider
    public func registerInputProvider(_ provider: any InputProvider) {
        inputProviders[type(of: provider).builtinName] = provider
    }

    /// Get typed input provider
    public func inputProvider<T: InputProvider>(for builtinName: String) -> T? {
        inputProviders[builtinName] as? T
    }
}
```

### 4. Modify Backend Protocol

```swift
public protocol Backend {
    // Existing...

    /// Set input providers before compilation
    /// Called by Coordinator with providers matching this backend's externalBuiltins
    func setInputProviders(_ providers: [String: any InputProvider])
}
```

### 5. Update Coordinator Compile Loop

```swift
private func compile() throws {
    // ... existing setup ...

    for swatch in swatches {
        let backendId = swatch.backend
        let externalBuiltins = BackendRegistry.shared.externalBuiltins(for: backendId)

        // Collect providers needed by this backend
        var neededProviders: [String: any InputProvider] = [:]
        for builtinName in externalBuiltins {
            // Lazily create provider if needed
            if inputProviders[builtinName] == nil {
                inputProviders[builtinName] = createProvider(for: builtinName)
            }
            if let provider = inputProviders[builtinName] {
                neededProviders[builtinName] = provider
            }
        }

        // Pass to backend before compile
        backend.setInputProviders(neededProviders)

        let unit = try backend.compile(swatch: swatch, ir: program)
        // ...
    }
}

private func createProvider(for builtinName: String) -> (any InputProvider)? {
    switch builtinName {
    case "microphone":
        let capture = AudioCapture()
        try? capture.setup(device: metalBackend?.device)
        return capture
    case "camera":
        let capture = CameraCapture(device: metalBackend!.device)
        return capture
    // Future: "midi", "osc", "gamepad", etc.
    default:
        return nil
    }
}
```

### 6. Update AudioBackend

```swift
public class AudioBackend: Backend {
    private var inputProviders: [String: any InputProvider] = [:]

    public func setInputProviders(_ providers: [String: any InputProvider]) {
        self.inputProviders = providers
    }

    public func compile(...) throws -> CompiledUnit {
        let codegen = AudioCodeGen(...)

        // Pass microphone provider to codegen
        if let micProvider = inputProviders["microphone"] as? AudioInputProvider {
            codegen.audioInput = micProvider
        }

        // Pass sample provider if we add one
        // ...
    }
}
```

## Migration Path

1. Add `InputProvider` protocol and make `AudioCapture` conform
2. Add `inputProviders` registry to Coordinator
3. Add `setInputProviders` to Backend protocol with default empty implementation
4. Update AudioBackend to use providers
5. Update MetalBackend similarly (camera, textures)
6. Remove hardcoded `audioInput` property from AudioBackend

## Future Benefits

Adding a MIDI backend becomes:

```swift
public class MIDIBackend: Backend {
    public static let externalBuiltins: Set<String> = ["midiNote", "midiCC"]
    // ...
}

public class MIDIInputProvider: InputProvider {
    public static var builtinName = "midiNote"
    public static var hardware: IRHardware = .midi
    // ...
}

// Coordinator automatically wires it up - no changes needed!
```

## Files to Modify

- `Sources/SWeftLib/Backends/Backend.swift` - Add `setInputProviders` to protocol
- `Sources/SWeftLib/Backends/InputProvider.swift` - New file
- `Sources/SWeftLib/Backends/AudioBackend/AudioCapture.swift` - Conform to protocol
- `Sources/SWeftLib/Backends/AudioBackend/AudioBackend.swift` - Use providers
- `Sources/SWeftLib/Backends/MetalBackend/MetalBackend.swift` - Use providers
- `Sources/SWeftLib/Backends/MetalBackend/CameraCapture.swift` - Conform to protocol
- `Sources/SWeftLib/Runtime/Coordinator.swift` - Generic provider management

## Testing

1. Microphone passthrough: `play[l,r] = microphone(0)` should work
2. Sample playback: `play[l,r] = sample("test.wav")` should work
3. Camera: `display[r,g,b] = camera(me.x, me.y)` should work
4. Cross-domain: Audio-reactive visuals should work
