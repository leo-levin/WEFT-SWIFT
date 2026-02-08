# Generalized Remap Caching (Cross-Backend CSE)

## Problem

When a heavy expression is remapped multiple times (e.g., edge detection via finite differences), each remap fully inlines the base expression. On Metal, we now have an intermediate texture optimization that pre-renders the base expression and samples at remapped coordinates. But this is Metal-specific — the audio backend and any future backends don't benefit.

## Current State (after feature/texture-indirection)

- **Metal**: `scanForHeavyRemaps` detects heavy remap bases (node count >= 30) and renders them to intermediate `r32Float` textures. Display kernel samples these at remapped UV coordinates. Works but is hardcoded in MetalCodeGen.
- **Audio**: Remaps are inlined directly via `applyRemap()`. No caching.
- **IR level**: No common subexpression elimination. `inlineSpindleCacheCalls` expands all spindle calls before backends see the IR.

## Proposed Architecture

### Option A: IR-Level CSE Pass

Add a pre-codegen pass that detects shared remap bases and rewrites the IR to make sharing explicit:

```
Before:  left.v = .remap(n.v, {me.x: me.x - 0.003})
         right.v = .remap(n.v, {me.x: me.x + 0.003})

After:   _intermediate_0 = n.v  (marked as "pre-compute")
         left.v = .remap(_intermediate_0, {me.x: me.x - 0.003})
         right.v = .remap(_intermediate_0, {me.x: me.x + 0.003})
```

Each backend then decides how to handle `_intermediate` bundles:
- Metal: intermediate texture
- Audio: memoized closure (evaluate once per tick)
- Future backends: whatever "compute once, store, sample" means

### Option B: Backend Protocol Hook

```swift
protocol Backend {
    // ... existing ...
    var supportsRemapCaching: Bool { get }
    func precomputeRemapBase(expr: IRExpr, id: String) throws -> Any
    func sampleCachedRemap(id: String, substitutions: [String: IRExpr]) throws -> String
}
```

Backends opt into the optimization and provide their own implementation.

### Option C: Hybrid

IR pass identifies candidates, adds annotations. Backends use annotations to decide strategy. This keeps the IR clean while allowing backend-specific optimizations.

## Scope

- Would also benefit non-remap cases: any expression referenced multiple times could be extracted
- Related to general "let binding" emission in Metal codegen (currently everything is one giant expression)
- FBM (`fbm3`) has 8 inlined `perlin3` calls that could benefit from loop unrolling or Metal function calls instead of full inlining

## Dependencies

- Current intermediate texture system (feature/texture-indirection) as proof of concept
- Potentially the backend-input-providers refactor (cleaner backend protocol)
