# First-Class Signals & Remap Caching

## Status

- **Phase 1: Signal Parameters** — DONE (PR #26). All spindle params are signal-capable. `input(me.x ~ me.x - delta)` works.
- **Phase 2: Evaluate-Once, Sample-Many** — TODO. Heavy expressions explode when remapped N times.
- **Phase 3: Signal Returns & Signal Storage** — TODO. Spindles return signals, bundles store signals.
- **Phase 4: Conditional Signals & Composition** — Future. Dynamic dispatch, higher-order signals.

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

## Phase 3: Signal Returns & Signal Storage

Everything in WEFT is a signal — an expression evaluated per-coordinate. But currently spindles collapse signals to scalar return values, and bundles store evaluated results rather than preservable expression trees. This phase makes the compiler lazier: defer evaluation until a coordinate context demands it.

### 3a: Signal Return Values

Currently a spindle return is a scalar — the expression is evaluated and the result is a number. The call site can't remap the result at different coordinates.

```weft
// Today: works, but the return value is a number, not a signal
spindle gradient(a, b) {
    return.0 = lerp(a, b, me.x)
}

// Want: the caller can remap the returned signal
g.v = gradient(0, 1)
shifted.v = g.v(me.x ~ me.x + 0.1)  // today this fails — g.v is a scalar
```

**Implementation approach:** The compiler already stores expression trees in the IR. The fix is to defer inlining — when a bundle references a spindle return, keep the expression tree intact rather than evaluating it. When that bundle is later remapped, the full expression is available for coordinate substitution.

This is an extension of how signal parameters already work. Parameters preserve expressions through spindle boundaries; returns need to do the same thing in the opposite direction.

**What changes:**
- `buildSpindleSubstitutions` / `inlineExpression` — preserve return expressions as remappable trees
- `getDirectExpression` — follow through spindle returns without collapsing
- Bundles that store spindle return values remain "signal-typed" until a sink (`display`, `play`) forces evaluation

### 3b: Signal Storage

A bundle like `g.v = some_expression` should remain a signal that downstream bundles can remap, not a collapsed value.

```weft
noise.v = perlin(me.x * 5, me.y * 5)

// Today: this works because inlining substitutes noise.v's full expression
shifted.v = noise.v(me.x ~ me.x + 0.1)

// But this chain breaks if noise.v went through a spindle return
```

**This mostly already works** because the IR stores expressions and inlining substitutes them. The gap is when a spindle return sits between the signal source and the remap — the return collapses the expression. Fixing 3a fixes this too.

### Scope

Both 3a and 3b are primarily changes to the inlining/substitution pipeline. No new IR node types needed. No backend changes — Metal and Audio both receive fully-inlined expressions after the transformation passes, same as today.

| Component | Change |
|-----------|--------|
| **IRTransformations** | Defer spindle return inlining, keep expression trees through returns |
| **Lowering** | Potentially mark bundles as "signal-storing" vs "value-storing" |
| **Codegen** | None — backends see fully-inlined expressions as before |

### Risk

Expression trees get larger before final inlining. For deep spindle chains this could worsen the expression explosion problem (Phase 2). Ideally Phase 2 (evaluate-once) ships first or alongside to provide the safety valve.

## Phase 4: Conditional Signals & Composition (Future)

Dynamic signal dispatch and higher-order signal patterns. This is the hard part.

```weft
// Conditional signal selection — only evaluate the chosen branch
spindle choose(cond, a, b) {
    return.0 = if(cond > 0, a, b)
}

// Higher-order: apply a filter spindle to a signal
spindle apply(input, filter) {
    return.0 = filter(input)
}
```

### Why This Is Hard

Metal has no function pointers. Every signal path must be resolved at compile time:
1. **Compile-time monomorphization** — generate specialized code for each concrete signal combination. Most promising, but code size grows combinatorially.
2. **Texture indirection** — evaluate all candidate signals to textures, select at runtime. Loses resolution, adds latency.
3. **Shader permutations** — generate a shader variant per branch combination. Combinatorial explosion.

### Open Questions

1. Syntax for signal literals vs signal references — is `gray.v` a value or a signal? Context-dependent?
2. Partial application — remap some coordinates, leave others free
3. Should the type system distinguish `Float` from `Signal<Float>`?
4. Memoization of repeated evaluations at same coordinates
