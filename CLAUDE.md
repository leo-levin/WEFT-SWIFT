# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SWeft is a Swift-based compiler and runtime for WEFT, a domain-agnostic creative coding language for visual graphics and audio synthesis. It bridges a JavaScript parser/compiler frontend with a native Swift backend using Metal for GPU graphics and CoreAudio for audio synthesis.

- Platform: macOS 14+ (Sonoma)
- Language: Swift 5.9+
- Graphics: Metal
- Audio: CoreAudio/AVAudioEngine
- No external dependencies beyond Apple frameworks

## Build Commands

```bash
swift build                    # Debug build
swift build -c release         # Release build
swift test                     # Run all tests
swift run                      # Run the app
./build-app.sh                 # Build macOS app bundle (WEFT.app)
```

## Architecture

### Compilation Pipeline

```
WEFT Source Code
    ↓ (JSCompiler - JavaScriptCore)
IR JSON (Bundles, Spindles, Strands, Expressions)
    ↓ (Analysis)
Dependency Graph → Ownership → Purity
    ↓ (Partitioner)
Swatches (grouped by backend)
    ↓ (Code Generation)
Metal Shaders & Audio Render Callbacks
    ↓
Visual Output & Audio Playback
```

### Key Concepts

- **Bundles**: Named computational units with multiple output strands
- **Strands**: Individual output channels of a bundle (RGB for display, stereo for audio)
- **Spindles**: Reusable function definitions with parameters
- **IRExpr**: Expression AST (numbers, params, binary/unary ops, builtins, cache, calls)
- **Swatches**: Compilation units partitioned by backend domain

### Core Modules

| Directory | Purpose |
|-----------|---------|
| `Sources/SWeftLib/IR/` | Codable IR structures, JSON parsing |
| `Sources/SWeftLib/Analysis/` | Dependency graph, ownership (visual/audio), purity analysis |
| `Sources/SWeftLib/Partition/` | Groups bundles into same-backend Swatches |
| `Sources/SWeftLib/Backends/MetalBackend/` | IR → Metal Shading Language, GPU execution |
| `Sources/SWeftLib/Backends/AudioBackend/` | IR → Swift closures, CoreAudio playback |
| `Sources/SWeftLib/Runtime/` | Coordinator, buffer management, camera/mic capture |
| `Sources/SWeftLib/JSCompiler/` | JavaScriptCore bridge to JS parser |
| `Sources/SWeftApp/` | SwiftUI application, MetalKit view |

### Backend Protocol

Backends implement a minimal protocol (~300 lines each):
- `identifier`: "visual" or "audio"
- `ownedBuiltins`: e.g., ["camera", "load"] for visual
- `coordinateFields`: e.g., ["x", "y", "t"] for visual, ["i", "t", "sampleRate"] for audio
- `compile(swatch:ir:)` → CompiledUnit
- `execute(unit:inputs:outputs:time:)`

### Coordinate Systems

- **Visual**: `me.x`, `me.y` (normalized 0-1), `me.t` (time), `me.w`, `me.h` (resolution)
- **Audio**: `me.i` (sample index), `me.t` (time), `me.sampleRate`

## Key Design Patterns

1. **Signal-Driven Cache**: Cache ticks when signal *changes*, not on level—enables feedback effects without loops

2. **Partitioning**: Same-backend subgraphs compiled together; pure nodes duplicated per backend as needed

3. **Domain-Agnostic IR**: WEFT doesn't know "pixels" or "samples"—backends define coordinate semantics

4. **Topological Execution**: Swatches execute in dependency order; buffers flow between domains

## Testing

Test programs in `Sources/SWeftApp/Resources/`:
- `gradient.json`: Visual-only (animated RGB)
- `sine.json`: Audio-only (440Hz tone)
- `crossdomain.json`: Audio-reactive visual

## Adding New Functionality

### New Builtin Function
1. Add to `MetalCodeGen.swift` (Metal implementation)
2. Add to `AudioCodeGen.swift` (Swift implementation)
3. Ensure same semantics in both backends

### New Backend
1. Implement `Backend` protocol in new directory under `Backends/`
2. Register in `Coordinator.swift`
3. Add ownership classification in `OwnershipAnalysis.swift`
