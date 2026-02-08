# First-Class Signals & Remap Caching

## Status

- **Phase 1: Signal Parameters** — DONE (PR #26). All spindle params are signal-capable. `input(me.x ~ me.x - delta)` works.
- **Phase 2: Evaluate-Once, Sample-Many** — TODO. Heavy expressions explode when remapped N times.
- **Phase 3: Runtime Signals** — Future. Signals as first-class values with dynamic dispatch.

## Phase 2: Evaluate-Once, Sample-Many

### Problem

Signal parameter remap inlines the full expression N times. An edge detector sampling 4 neighbors of `perlin3` produces 4 full perlin evaluations in one shader. `perlin3` expands to ~100+ lines of Metal after inlining. Four copies = ~400+ lines and stack overflow during codegen.

### Current State

- **Metal**: `scanForHeavyRemaps` detects heavy remap bases (node count >= 30) and renders them to intermediate `r32Float` textures. Display kernel samples at remapped UV coords. Works but is hardcoded in MetalCodeGen.
- **Audio**: Remaps are inlined directly via `applyRemap()`. No caching.
- **IR level**: No common subexpression elimination. `inlineSpindleCacheCalls` expands all spindle calls before backends see the IR.

### Solution

When a heavy expression is remapped multiple times, evaluate it once and sample from the result:

```
// User writes:
n[v] = perlin3(me.x * 5, me.y * 5, 0)
e[v] = step(0.1, edge(n.v, 0.003))

// Compiler sees: edge remaps n.v at 4 coordinates, n.v is heavy

// Compiler emits TWO dispatches:
// Pass 1: Evaluate n.v to texture_n
// Pass 2: Edge detection kernel reads from texture_n at offset UVs
```

### Architecture Options

**Option A: IR-Level CSE Pass** — Add a pre-codegen pass that detects shared remap bases and rewrites the IR:

```
Before:  left.v = .remap(n.v, {me.x: me.x - 0.003})
         right.v = .remap(n.v, {me.x: me.x + 0.003})

After:   _intermediate_0 = n.v  (marked as "pre-compute")
         left.v = .remap(_intermediate_0, {me.x: me.x - 0.003})
         right.v = .remap(_intermediate_0, {me.x: me.x + 0.003})
```

Each backend decides how to handle `_intermediate` bundles:
- Metal: intermediate texture
- Audio: memoized closure (evaluate once per tick)

**Option B: Backend Protocol Hook** — Backends opt into remap caching via protocol methods.

**Option C: Hybrid** — IR pass identifies candidates and adds annotations. Backends use annotations to decide strategy.

### Detection Heuristic

```swift
func shouldUseTextureIndirection(expr: IRExpr) -> Bool {
    return expr.containsCall() || expr.nodeCount() > 50
}
```

Spindle calls are the main source of expression explosion. Pure math (sin, floor) is cheap to duplicate.

### Remap Coordinate Mapping

- `me.x - delta` in normalized [0,1] → texture UV coordinates
- Metal sampler with bilinear filtering for smooth sub-pixel offsets, or nearest-neighbor for hard edges
- Edge behavior: clamp, wrap, or zero for out-of-bounds coords

### Implementation Scope

| Component | Change |
|-----------|--------|
| **MetalCodeGen** | Generalize existing `scanForHeavyRemaps` |
| **MetalBackend** | Already handles intermediate textures |
| **AudioBackend** | Add memoized closure for remap bases |
| **Partitioner** | May need to split swatches into multi-pass |
| **IR** | CSE pass to extract shared remap bases |

Also benefits non-remap cases: FBM has 8 inlined `perlin3` calls that could use loop unrolling or Metal function calls instead of full inlining.

## Phase 3: Runtime Signals (Future)

Signals as a first-class value type — passed, returned, stored, composed at runtime.

```weft
// Conditional signal selection
spindle choose(cond, a, b) {
    return.0 = if(cond > 0, a, b)  // runtime signal dispatch
}

// Signal as return value
spindle make_gradient(color1, color2) {
    return.signal = lerp(color1, color2, me.x)
}
```

### Metal Implications

Metal has no function pointers. Options:
1. **Texture indirection**: Evaluate to texture, sample (loses resolution)
2. **Shader permutations**: Specialized shaders per signal combination (combinatorial)
3. **Compile-time monomorphization**: Like Rust generics — generate specialized code for each concrete signal type. Most promising.

### Open Questions

1. Syntax for signal literals vs signal references
2. Partial application — remap some coordinates, leave others free
3. Should the type system distinguish `Float` from `Signal<Float>`?
4. Memoization of repeated evaluations at same coordinates
