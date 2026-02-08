# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Personality

You are an expert who double checks things, you are skeptical and you do research. I am not always right. Neither are you, but we both strive for accuracy.

## Project Overview

WEFT is a native Swift compiler and runtime for WEFT, a domain-agnostic creative coding language for visual graphics and audio synthesis. The entire pipeline — tokenizer, parser, desugaring, lowering, and code generation — is implemented in Swift, with Metal for GPU graphics and CoreAudio for audio synthesis.

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

# Run a single test
swift test --filter WEFTTests.IntegrationTests/testMetalCodeGeneration
```

## Architecture

### Compilation Pipeline

```
WEFT Source Code
    ↓ (WeftTokenizer)
Tokens
    ↓ (WeftParser)
AST
    ↓ (WeftDesugar)
Desugared AST
    ↓ (WeftLowering)
IR (Bundles, Spindles, Strands, Expressions)
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

| Directory                                | Purpose                                                     |
| ---------------------------------------- | ----------------------------------------------------------- |
| `Sources/WEFTLib/IR/`                    | IR structures used by analysis and code generation          |
| `Sources/WEFTLib/Analysis/`              | Dependency graph, ownership (visual/audio), purity analysis |
| `Sources/WEFTLib/Partition/`             | Groups bundles into same-backend Swatches                   |
| `Sources/WEFTLib/Backends/MetalBackend/` | IR → Metal Shading Language, GPU execution                  |
| `Sources/WEFTLib/Backends/AudioBackend/` | IR → Swift closures, CoreAudio playback                     |
| `Sources/WEFTLib/Parser/`                | Tokenizer, parser, AST, desugaring, lowering                |
| `Sources/WEFTLib/Runtime/`               | Coordinator, buffer management, camera/mic capture          |
| `Sources/WEFTApp/`                       | SwiftUI application, MetalKit view                          |

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

1. **Signal-Driven Cache**: Cache ticks when signal _changes_, not on level—enables feedback effects without loops

2. **Partitioning**: Same-backend subgraphs compiled together; pure nodes duplicated per backend as needed

3. **Domain-Agnostic IR**: WEFT doesn't know "pixels" or "samples"—backends define coordinate semantics

4. **Topological Execution**: Swatches execute in dependency order; buffers flow between domains

## Testing

Test programs in `Sources/WEFTApp/Resources/`:

- `gradient.json`: Visual-only (animated RGB)
- `sine.json`: Audio-only (440Hz tone)
- `crossdomain.json`: Audio-reactive visual

## Adding New Functionality

### New Builtin Function

1. Add Metal implementation in `MetalCodeGen.swift` (in `generateBuiltin` method)
2. Add Swift implementation in `AudioCodeGen.swift` (in `generateBuiltin` method)
3. Ensure same semantics in both backends

Current builtins: `sin`, `cos`, `tan`, `abs`, `floor`, `ceil`, `sqrt`, `pow`, `min`, `max`, `lerp`, `clamp`, `step`, `smoothstep`, `fract`, `mod`, `osc`, `cache`

Resource builtins (multi-strand output): `texture`, `camera`, `microphone`

### New Backend

1. Implement `Backend` protocol in new directory under `Backends/`
2. Register in `Coordinator.swift`
3. Add ownership classification in `OwnershipAnalysis.swift`

## WEFT Language Syntax

```weft
// Bundles with strand outputs
img[r,g,b] = camera(1-me.x, me.y)
brightness.val = img.r * 0.3 + img.g * 0.6 + img.b * 0.1

// Spindle definitions
spindle circle(cx, cy, radius) {
    return.0 = step(radius, sqrt((me.x-cx)^2 + (me.y-cy)^2))
}

// Chain expressions with patterns
display[r,g,b] = img -> {0..3 * brightness.val}

// Cache for feedback effects (value, historySize, tapIndex, signal)
trail.val = cache(max(dot.val, trail.val * 0.95), 2, 1, me.t)

// Range expansion in patterns
prev[r,g,b] = current -> {cache(0..3, 2, 1, me.t)}
```

## Known Issues / Technical Debt

- ~~Microphone input currently requires a `play` bundle even for visual-only programs~~ — Fixed by InputProvider refactor (PR #19)
- ~~Audio backend may not have full feature parity with Metal backend~~ — Cache is now fully implemented in both backends
- Multiple Claude instances have made patches; code organization could be improved
