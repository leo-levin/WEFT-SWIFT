⏺ WEFT Swift Compiler (SWeft) - Ralph Loop Implementation

Objective

Build a complete Swift compiler/runtime for the WEFT creative coding language. The system takes IR (intermediate representation) as JSON from an existing JavaScript frontend and executes it across multiple backends: Metal for visual output, CoreAudio for audio output.

Philosophy

WEFT is domain-agnostic. The language doesn't know about "visual" or "audio" - it only knows about coordinates, values, and computation. A node is just a function from coordinates to values. What those coordinates mean (pixels, samples, MIDI channels) is determined by the backend, not the language.

Backends should be minimal. The goal is to easily add new backends: MIDI, OSC, 3D, data export, video encoding, network streaming, etc. All analysis, graph building, partitioning, and orchestration lives in the coordinator. Backends are dumb executors that:

- Declare what builtins they own
- Declare what coordinates they provide
- Compile a Swatch to native code
- Execute when told

If you're adding logic to a backend that isn't about native code generation or execution, it probably belongs in the coordinator.

Repository

Location: /Users/leo/Documents/01 PROJECTS/weft/SWeft

This is a sister repo to the JS frontend at /Users/leo/Documents/01 PROJECTS/weft/proto copy

Create a new Swift Package at this location.

Success Criteria

1. Parse WEFT IR from JSON into Swift data structures
2. Analyze IR to build dependency graph, detect backend ownership, classify purity
3. Partition graph into Swatches (compilation units per backend)
4. Compile Swatches to Metal shaders (visual) and audio render callbacks (audio)
5. Execute frame loop: run Swatches in topological order, manage cross-domain buffers
6. Implement cache builtin with signal-driven ticking for feedback effects
7. Render visual output to screen via Metal
8. Play audio output via CoreAudio
9. Handle cross-domain references (e.g., audio amplitude driving visual brightness)
10. Backend implementations should be under 500 lines each - if larger, logic probably belongs in coordinator

Architecture Reference

Read and internalize: /Users/leo/Documents/01 PROJECTS/weft/proto copy/SWIFT-PLAN.md

This document defines:

- Core mental model (nodes as functions from coordinates to values)
- Pure vs stateful vs external classification
- Backend ownership (determined by builtins only)
- Swatch partitioning (connected same-backend subgraphs)
- Cache semantics (tick when signal CHANGES, not level-triggered)
- Coordinator responsibilities
- Cross-domain buffer passing

Constraints

- Language: Swift 5.9+
- Platform: macOS 14+ (Sonoma), Apple Silicon preferred
- Graphics: Metal (not OpenGL)
- Audio: CoreAudio with AVAudioEngine or raw AudioUnit
- No external dependencies except Apple frameworks
- Project type: Swift Package with executable target + library
- Backend size: Keep backends minimal. Coordinator does the thinking, backends just execute.

Project Structure

/Users/leo/Documents/01 PROJECTS/weft/SWeft/
├── Package.swift
├── Sources/
│ └── SWeft/
│ ├── IR/
│ │ ├── IR.swift
│ │ └── IRParser.swift
│ ├── Analysis/
│ │ ├── DependencyGraph.swift
│ │ ├── OwnershipAnalysis.swift
│ │ └── PurityAnalysis.swift
│ ├── Partition/
│ │ ├── Swatch.swift
│ │ └── Partitioner.swift
│ ├── Backends/
│ │ ├── Backend.swift
│ │ ├── MetalBackend/
│ │ │ ├── MetalBackend.swift
│ │ │ └── MetalCodeGen.swift
│ │ └── AudioBackend/
│ │ ├── AudioBackend.swift
│ │ └── AudioCodeGen.swift
│ ├── Runtime/
│ │ ├── Coordinator.swift
│ │ ├── BufferManager.swift
│ │ └── CacheManager.swift
│ └── App/
│ └── main.swift
├── Tests/
│ └── SWeftTests/
│ ├── IRParserTests.swift
│ ├── AnalysisTests.swift
│ ├── PartitionerTests.swift
│ ├── MetalCodeGenTests.swift
│ └── IntegrationTests.swift
└── Resources/
└── TestPrograms/
├── gradient.json
├── sine.json
├── feedback.json
├── delay.json
└── crossdomain.json

Implementation Phases

Phase 1: Foundation

Goal: Create Swift package, parse IR from JSON

Tasks:

- Initialize Swift package at /Users/leo/Documents/01 PROJECTS/weft/SWeft
- Define IR types matching JS IR structure:
  - IRProgram (bundles, spindles, resources)
  - IRBundle (name, strands)
  - IRStrand (name, index, expr)
  - IRSpindle (name, params, locals, returns)
  - Expression types: IRNum, IRParam, IRIndex, IRBinaryOp, IRUnaryOp, IRBuiltin, IRCall, IRExtract, IRRemap
- Implement JSON parsing via Codable
- Handle cache as IRBuiltin with 4 args: value, history_size, tap_index, signal

Checkpoint: Parse this JSON and print the structure:
{
"bundles": {
"display": {
"strands": [
{"name": "r", "index": 0, "expr": {"type": "index", "bundle": "me", "field": "x"}},
{"name": "g", "index": 1, "expr": {"type": "index", "bundle": "me", "field": "y"}},
{"name": "b", "index": 2, "expr": {"type": "num", "value": 0.5}}
]
}
},
"spindles": {},
"order": ["display"]
}

Phase 2: Analysis

Goal: Build dependency graph, classify nodes

Tasks:

- Walk IR expressions, collect bundle/spindle references
- Build directed graph: nodes = bundles, edges = dependencies
- Implement backend ownership detection:
  - camera, load → visual
  - microphone → audio
  - display → visual (output sink)
  - play → audio (output sink)
  - cache → inherits from context
- Implement purity classification:
  - Pure: no cache, no self-reference, no external builtins
  - Stateful: uses cache OR self-reference with coordinate offset
  - External: uses camera, microphone, etc.

Checkpoint: Given IR, print each bundle with its dependencies, backend ownership, and purity classification.

Phase 3: Partitioning

Goal: Partition graph into Swatches

Tasks:

- Implement Swatch type:
  - Backend identifier
  - Set of bundle names in this Swatch
  - Input buffers needed (cross-domain dependencies)
  - Output buffers produced
- Partition algorithm:
  - Group connected same-backend nodes
  - Cross-domain edges break connectivity
  - Pure nodes can duplicate (each backend gets its own copy)
- Topologically sort Swatch graph

Checkpoint: Given multi-domain IR, print Swatches with their contents and execution order.

Phase 4: Backend Protocol

Goal: Define clean, minimal backend interface

Tasks:

- Define Backend protocol - keep it minimal:
  protocol Backend {
  static var identifier: String { get }
  static var ownedBuiltins: Set<String> { get }
  static var coordinateFields: [String] { get } // e.g., ["x", "y", "t"] for visual, ["i", "t"] for audio

      func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit
      func execute(unit: CompiledUnit, inputs: [String: Buffer], outputs: [String: Buffer], time: Double)

  }

- Define Buffer protocol (abstraction over Metal textures, audio buffers, etc.)
- Define CompiledUnit protocol (abstraction over Metal pipeline, audio callback, etc.)
- Important: Backends should NOT do analysis, graph walking, or dependency resolution. They receive a Swatch and execute it.

Checkpoint: Protocol compiles, can be implemented by stubs.

Phase 5: Metal Backend

Goal: Full visual rendering pipeline

Tasks:

- Metal code generator:
  - IR expressions → Metal Shading Language
  - Binary ops: +, -, \*, /, %, ^ (pow)
  - Unary ops: -, !
  - Builtins: sin, cos, tan, abs, floor, ceil, sqrt, pow, min, max, lerp, clamp, step, smoothstep, fract, mod
  - me.x, me.y → normalized coordinates (0-1)
  - me.t → time uniform
  - me.w, me.h → resolution
  - Bundle references → function calls or inlined expressions
  - cache → texture sample from history buffer
- Metal backend implementation:
  - Create MTLDevice, command queue
  - Compile shader source to MTLLibrary
  - Create compute or render pipeline
  - Bind buffers/textures
  - Dispatch compute or draw call
- Handle display output:
  - Render to drawable texture
  - Present to screen via MTKView
- Keep it minimal: Code generation + Metal API calls only. No graph analysis.

Checkpoint: Render display [me.x, me.y, sin(me.t * 3.0)] - animated RGB gradient.

Phase 6: Audio Backend

Goal: Full audio synthesis/processing pipeline

Tasks:

- Audio code generator:
  - IR expressions → Swift closures or compiled expressions
  - Same builtins as Metal (Swift equivalents)
  - me.i → sample index within buffer
  - me.t → time (sample index / sample rate, or buffer count)
  - me.sampleRate → audio sample rate
  - Bundle references → inline or function calls
  - cache with me.i signal → delay line (circular buffer)
- Audio backend implementation:
  - AVAudioEngine with source node (manual render)
  - Or raw AudioUnit for lower latency
  - Fill buffer in render callback
  - Handle stereo (left/right or .0/.1 strands)
- Handle play output:
  - play bundle strands are audio output channels
  - Typically: play.0 = left, play.1 = right (or mono)
- Handle microphone input:
  - AVAudioEngine input node
  - Provide as external buffer to coordinator
- Keep it minimal: Code generation + CoreAudio API calls only. No graph analysis.

Checkpoint: Play play [sin(me.i / me.sampleRate * 440 * 6.28) * 0.3] - 440Hz sine tone.

Phase 7: Cache Implementation

Goal: Signal-driven history buffers for both backends

Tasks:

- Cache manager (in coordinator, not backends):
  - Track all cache nodes in IR
  - Allocate per-coordinate history buffers
  - For Metal: texture array (one texture per history slot)
  - For Audio: circular buffer per channel
- Signal change detection:
  - Store previous signal value per cache node
  - Compare current vs previous each frame/buffer
  - If changed: shift history, store new value
- Integrate with backends:
  - Metal: bind history textures, generate sample code
  - Audio: index into circular buffer

Checkpoint (visual):
brightness = cache(brightness _ 0.99 + camera.r _ 0.01, 1, 0, me.t)
display [brightness, brightness, brightness]
Camera input with temporal feedback/trails.

Checkpoint (audio):
delayed = cache(input, 22050, 11025, me.i)
play [input * 0.7 + delayed * 0.3]
Audio delay effect (0.25 sec delay at 44.1kHz).

Phase 8: Coordinator & Cross-Domain

Goal: Orchestrate multi-backend execution

Tasks:

- Coordinator implementation:
  - Own all backends (registry)
  - Own buffer manager
  - Own cache manager
  - Frame loop:
    i. Update time uniforms
    ii. Process cache ticks
    iii. Execute Swatches in topological order
    iv. Pass buffers between Swatches
- Cross-domain buffers:
  - When audio Swatch output is input to visual Swatch:
    - Audio writes to shared buffer
    - Visual reads from same buffer
  - Metal can sample from buffer as texture
  - Use shared memory (Apple Silicon unified memory)
- Implement proper frame timing:
  - Visual: vsync via MTKView delegate
  - Audio: runs on audio thread, coordinator syncs

Checkpoint:
amplitude = audio.play.0
brightness = amplitude \* amplitude
display [brightness, me.y, me.x]
Audio-reactive visual - brightness responds to audio amplitude.

Phase 9: App Shell

Goal: Minimal runnable application

Tasks:

- SwiftUI app with:
  - MTKView for Metal output
  - Audio session setup
  - Load IR from JSON file or bundled resource
  - Start/stop button
  - Maybe: hot reload IR on file change
- Error handling:
  - Parse errors
  - Compilation errors (shader, etc.)
  - Runtime errors
- Debug output:
  - Print Swatch graph
  - Print generated shader code
  - FPS counter

Checkpoint: App launches, loads IR, renders visual, plays audio.

Test Programs

Create these IR JSON files in Resources/TestPrograms/:

gradient.json - Visual only
display [me.x, me.y, fract(me.t)]

sine.json - Audio only
play [sin(me.i / me.sampleRate * 440 * 6.28) * 0.3]

feedback.json - Visual with cache
b = cache(b _ 0.98 + me.x _ 0.02, 1, 0, me.t)
display [b, b, b]

delay.json - Audio with cache
d = cache(input, 44100, 22050, me.i)
play [input * 0.6 + d * 0.4]

crossdomain.json - Audio-reactive visual
amp = abs(sin(me.t _ 3.0))
play [sin(me.i / me.sampleRate _ 440 _ 6.28) _ amp]
display [amp, me.y, me.x]

Design Principles

1. Domain-agnostic language: WEFT doesn't know about pixels or samples. It knows coordinates and values.
2. Minimal backends: Backends are thin wrappers around native APIs. All intelligence lives in the coordinator. A new backend (MIDI, OSC, 3D, etc.) should be addable in ~300 lines.
3. Coordinator does the thinking: Graph analysis, partitioning, dependency resolution, buffer management, cache tick logic - all in coordinator.
4. Backends just execute: Receive Swatch + buffers, compile to native code, run when told.
5. No premature optimization: Correctness first. Profile later.
6. Type safety: Use Swift's type system to prevent errors at compile time.

Notes

- Metal shaders should be generated as strings, compiled at runtime
- Audio callback must be real-time safe (no allocations, no locks)
- Test each phase before moving to next
- Reference /Users/leo/Documents/01 PROJECTS/weft/proto copy/SWIFT-PLAN.md for architectural decisions
- Reference /Users/leo/Documents/01 PROJECTS/weft/proto copy/src/ir.js for JS IR structure to match
- If a backend is getting complicated, ask: "Should this logic be in coordinator instead?"
