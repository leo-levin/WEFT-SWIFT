# Architecture Cleanup

## Problem

The codebase has accumulated band-aids and inconsistencies:

1. **Hardcoded backend wiring** - Coordinator has specific code for each backend instead of using registry
2. **Inconsistent input handling** - camera vs microphone vs samples all wired differently
3. **Scattered lowering logic** - Resource builtins handled in multiple places
4. **Duplicated code** - Similar patterns in MetalCodeGen and AudioCodeGen
5. **Unclear ownership** - Who owns what (Coordinator vs Backend vs Manager)

## Current Pain Points

### 1. Input Provider Mess

```swift
// Coordinator.swift - all different patterns:
audioBackend?.audioInput = audioCapture           // direct property
metalBackend?.cameraTexture = cameraCapture.texture  // texture property
audioBackend?.loadedSamples = loadedSamples       // dictionary
metalBackend?.loadedTextures = loadedTextures     // another dictionary
```

Should be unified via InputProvider protocol (see backend-input-providers-refactor.md).

### 2. Resource Builtin Handling

Resource builtins (camera, microphone, sample, texture, load, text) are handled:
- In `WeftLowering.swift` - `RESOURCE_BUILTINS` dictionary, `lowerResourceCall`
- In `WeftLowering.swift` again - special cases in `lowerExpr` for `.spindleCall`
- In `WeftLowering.swift` again - special cases in `lowerExpr` for `.callExtract`
- In `MetalCodeGen.swift` - `generateBuiltin` with special resource handling
- In `AudioCodeGen.swift` - `buildBuiltin` with different resource handling

Should be: One place defines resource builtins, backends just implement them.

### 3. Coordinator Does Too Much

Coordinator currently:
- Parses IR
- Manages backends
- Manages textures, samples, text
- Manages camera and microphone capture
- Manages cache buffers
- Coordinates rendering
- Handles cross-domain buffers

Should be split into focused components.

### 4. Code Duplication in CodeGens

MetalCodeGen and AudioCodeGen have similar:
- Builtin handling (sin, cos, etc.)
- Binary/unary op handling
- Spindle inlining
- Cache handling

Should share common infrastructure.

## Proposed Structure

```
SWeftLib/
├── IR/
│   ├── IR.swift              # Core IR types
│   ├── IRTransformations.swift
│   └── IRAnnotations.swift
├── Parser/
│   ├── WeftParser.swift      # Parsing only
│   └── WeftLowering.swift    # AST -> IR only
├── Analysis/
│   ├── DependencyGraph.swift
│   ├── OwnershipAnalysis.swift
│   └── PurityAnalysis.swift
├── Backends/
│   ├── Backend.swift         # Protocol + shared types
│   ├── BackendRegistry.swift
│   ├── SharedCodeGen.swift   # Common codegen utilities
│   ├── InputProvider.swift   # Input provider protocol
│   ├── Metal/
│   │   ├── MetalBackend.swift
│   │   └── MetalCodeGen.swift
│   └── Audio/
│       ├── AudioBackend.swift
│       └── AudioCodeGen.swift
├── Resources/
│   ├── ResourceManager.swift # Unified resource loading
│   ├── TextureLoader.swift
│   ├── SampleLoader.swift
│   └── TextRenderer.swift
├── Capture/
│   ├── CameraCapture.swift
│   └── AudioCapture.swift
└── Runtime/
    ├── Coordinator.swift     # Orchestration only
    ├── BufferManager.swift
    └── CacheManager.swift
```

## Cleanup Tasks

### Phase 1: Consolidate Input Handling
- [ ] Implement InputProvider protocol
- [ ] Make CameraCapture, AudioCapture conform
- [ ] Update Coordinator to use generic provider registry
- [ ] Remove backend-specific wiring code

### Phase 2: Unify Resource Builtins
- [ ] Create ResourceBuiltin protocol/spec in Backend.swift
- [ ] Move resource definitions out of WeftLowering into backends
- [ ] Single code path for resource handling in lowering
- [ ] Backends declare their resources, lowering uses that

### Phase 3: Extract Shared CodeGen
- [ ] Create SharedCodeGen with common operations
- [ ] MetalCodeGen and AudioCodeGen extend/use it
- [ ] Builtin implementations registered once, used by both

### Phase 4: Split Coordinator
- [ ] Extract ResourceCoordinator (textures, samples, text)
- [ ] Extract CaptureCoordinator (camera, microphone)
- [ ] Coordinator becomes thin orchestration layer

### Phase 5: Documentation
- [ ] Update Docs/signal-backend.md with new structure
- [ ] Add architecture diagram
- [ ] Document extension points clearly

## Principles

1. **Backends are self-describing** - All backend-specific info in the backend
2. **Coordinator is generic** - No backend-specific code in Coordinator
3. **Single source of truth** - Each concept defined once
4. **Clear ownership** - Each component has clear responsibility
5. **Easy to add backends** - New backend = new folder, register, done

## Non-Goals

- Don't change the IR format
- Don't change the WEFT language
- Don't change the rendering pipeline semantics
- Keep backward compatibility with existing .weft files

## Testing Strategy

After each phase:
1. All existing tests pass
2. Existing .weft programs work identically
3. No performance regression

## Order of Operations

1. Write comprehensive tests for current behavior
2. Refactor in phases, tests green at each step
3. Update documentation as we go
