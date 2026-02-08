# Feature: First-Class Signals

## Problem

Spindle parameters receive **values** (the result of evaluating an expression at the current coordinate). The remap operator (`~`) needs access to the original **signal** (the expression itself) so it can re-evaluate at different coordinates.

This means you can't abstract coordinate transforms inside spindles:

```weft
// This fails — input is a number, not a signal
spindle edge(input, delta) {
    l[v] = input ~ me.x - delta    // ERROR: can't remap a value
    r[v] = input ~ me.x + delta
    return.mag = abs(l.v - r.v)
}
```

Patterns that require neighbor sampling (blur, edge detection, convolution, displacement mapping) can't be packaged as reusable spindles.

## Phase 1: Signal Parameters (Compile-Time) — IMPLEMENTED

All spindle parameters are signal-capable. No annotation needed. The parser disambiguates `ident(domain ~ expr)` as remap (not a call) by looking ahead for `~` inside the parens.

### How It Works

1. At the call site `edges[mag] = edge(gray.v, 0.005)`, the compiler preserves `gray.v` as an expression (it always did — IR stores expressions, not values)
2. Inside the spindle, `input(me.x ~ me.x - delta)` parses as a remap with `input` as the base
3. In the IR: `.remap(base: .param("input"), substitutions: {"me.x": ...})`
4. During codegen inlining, `.param("input")` is substituted with the actual expression for `gray.v`
5. `getDirectExpression` resolves the bundle reference, `applyRemap` substitutes coordinates

### What This Enables

```weft
spindle edge(input, delta) {
    l[v] = input(me.x ~ me.x - delta)
    r[v] = input(me.x ~ me.x + delta)
    u[v] = input(me.y ~ me.y - delta)
    d[v] = input(me.y ~ me.y + delta)
    return.0 = abs(l.v - r.v) + abs(u.v - d.v)
}

// Works: thin white ring on black
circle[v] = step(0.3, sqrt((me.x - 0.5)^2 + (me.y - 0.5)^2))
e[v] = step(0.1, edge(circle.v, 0.003))
display[r,g,b] = [e.v, e.v, e.v]
```

### Implementation

One parser change in `WeftParser.swift`: in `parsePrimaryExpr()`, the `ident(` path checks `isRemapArgs()` before treating it as a call. If the parens contain `~`, the identifier is returned as-is and postfix remap parsing handles it.

No AST, IR, lowering, or codegen changes were needed.

### Known Limitation: Expression Explosion

Each remap creates a **full copy** of the signal's expression tree. The edge spindle above creates 4 copies (l, r, u, d). For simple expressions this is fine, but for deep spindle chains (e.g., `perlin3` → `_grad_dot` x8 → `_hash3x/y/z` x24) the expression tree explodes exponentially and crashes with stack overflow during Metal codegen.

This is the motivation for Phase 2.

## Phase 2: Texture Indirection for Remap

### Problem

Signal parameter remap inlines the full expression N times. For an edge detector sampling 4 neighbors of `perlin3`, that's 4 full perlin evaluations inlined into one shader. `perlin3` alone expands to ~100+ lines of Metal code after full inlining. Four copies = ~400+ lines, plus the recursive codegen to produce them overflows the stack.

### Solution: Evaluate-Once, Sample-Many

When a signal parameter is remapped, the compiler should detect that the base expression is "heavy" (contains spindle calls, or exceeds a depth/size threshold) and automatically:

1. **Evaluate the signal to an intermediate texture** at full resolution
2. **Sample from the texture** at remapped coordinates using Metal's texture sampling

This turns N full expression evaluations into 1 evaluation + N texture reads.

### How It Would Work

```
// User writes:
n[v] = perlin3(me.x * 5, me.y * 5, 0)
e[v] = step(0.1, edge(n.v, 0.003))

// Compiler sees: edge remaps n.v at 4 coordinates
// n.v contains a spindle call chain (heavy)

// Compiler emits TWO dispatches instead of one:
// Pass 1: Evaluate n.v to texture_n (standard display kernel for n)
// Pass 2: Edge detection kernel reads from texture_n at offset UVs
```

### Metal Code for Pass 2

```metal
kernel void display_kernel(
    texture2d<float, access::write> output [[texture(0)]],
    texture2d<float, access::read> texture_n [[texture(N)]],  // intermediate
    ...
) {
    // Instead of inlining perlin3 4 times:
    float l = texture_n.read(uint2(gid.x - 1, gid.y)).r;
    float r = texture_n.read(uint2(gid.x + 1, gid.y)).r;
    float u = texture_n.read(uint2(gid.x, gid.y - 1)).r;
    float d = texture_n.read(uint2(gid.x, gid.y + 1)).r;
    float edge = abs(l - r) + abs(u - d);
    ...
}
```

### Detection Heuristic

The compiler needs to decide when to use texture indirection vs direct inlining:

```swift
func shouldUseTextureIndirection(expr: IRExpr) -> Bool {
    // Option A: Expression contains any spindle call
    return expr.containsCall()

    // Option B: Expression exceeds size threshold
    return expr.nodeCount() > MAX_INLINE_NODES  // e.g., 50

    // Option C: Expression depth exceeds threshold
    return expr.depth() > MAX_INLINE_DEPTH  // e.g., 10
}
```

Option A (any spindle call) is simplest and most conservative. Spindle calls are the main source of expression explosion. Pure math expressions (sin, floor, etc.) are cheap to duplicate.

### Implementation

| Component | Change |
|-----------|--------|
| **MetalCodeGen** | Detect heavy remap bases, emit texture read instead of inlining |
| **MetalBackend** | Allocate intermediate textures, dispatch multi-pass rendering |
| **Coordinator** | Manage intermediate texture lifecycle |
| **Partitioner** | May need to split a swatch into multiple passes |

The key architectural question: should this be a **codegen concern** (MetalCodeGen detects heaviness and emits texture reads) or a **partitioner concern** (partitioner splits heavy remaps into separate swatches with texture dependencies)?

Partitioner approach is cleaner — it reuses the existing multi-swatch execution pipeline. The "intermediate texture" is just another swatch's output texture that the downstream swatch reads from. This is similar to how cross-domain buffers work, but within the same domain.

### Relationship to Existing Infrastructure

- **Cross-domain buffers**: Already handle audio→visual data flow via buffers. This is the same pattern but visual→visual.
- **Multi-swatch rendering**: The coordinator already renders swatches in dependency order. An intermediate texture swatch would just be another swatch.
- **Texture inputs**: MetalCodeGen already handles `camera` and `texture` builtins that read from textures. The infrastructure for texture reads in shaders exists.

### Remap Coordinate Mapping

The remap substitution `me.x ~ me.x - delta` needs to map to texture UV coordinates:

- `me.x - delta` in normalized [0,1] space → `uint2((me.x - delta) * width, me.y * height)` for texture read
- Or use Metal's sampler with normalized coordinates for proper filtering
- Edge clamping: what happens when remapped coords go outside [0,1]? Clamp, wrap, or zero?

Using a sampler with bilinear filtering would give smooth results for sub-pixel offsets. Using nearest-neighbor would preserve hard edges. The choice could be a parameter or default to nearest for consistency with the inline approach.

---

## Full Solution: First-Class Signals (Runtime)

The interim solution is compile-time sugar. The full solution makes signals a first-class value type in the language — they can be passed, returned, stored, and composed at runtime.

### What This Enables Beyond Signal Parameters

```weft
// Conditional signal selection
spindle choose(cond, a~, b~) {
    // Not possible with compile-time substitution alone —
    // both branches would need to be evaluated
    return.0 = if(cond > 0, a, b)  // runtime signal dispatch
}

// Signal composition / higher-order
spindle apply_filter(input~, filter~) {
    return.0 = filter(input)
}

// Signal as return value
spindle make_gradient(color1, color2) {
    return.signal = lerp(color1, color2, me.x)  // returns a signal, not a value
}
```

### Architecture Implications

This is a fundamental change to the evaluation model:

**Audio backend**: Closures already work this way — `(AudioContext) -> Float` is already a signal. The change is making this user-visible and composable.

**Metal backend**: Metal has no function pointers. Options:
1. **Texture indirection**: Evaluate the signal to a texture, sample from it (loses resolution, adds latency)
2. **Shader permutations**: Generate specialized shaders for each signal combination (combinatorial explosion)
3. **Expression buffer**: Encode the signal's expression tree as data, interpret in shader (complex, slow)
4. **Compile-time monomorphization**: Like Rust generics — generate specialized code for each concrete signal type used. No runtime dispatch, but code size grows.

Option 4 (monomorphization) is the most promising for Metal. It's essentially the compile-time signal parameter approach generalized — the compiler sees all concrete signal types at compile time and generates specialized versions.

### Evaluation Model

A signal would be a new IR type:

```swift
// New IRExpr case
case signal(IRExpr)  // wraps an expression that can be re-evaluated at different coordinates

// New evaluation: applying a signal at coordinates
case apply(IRExpr, coordinates: [(String, IRExpr)])  // evaluate signal at given coords
```

### Open Questions

1. **Syntax for signal literals vs signal references** — Is `gray.v` a value or a signal? Context-dependent? Explicit `&gray.v`?
2. **Partial application** — Can you remap some coordinates and leave others free? `signal ~ me.x + 1` remaps x but keeps y.
3. **Signal equality** — Can you compare signals? Probably not needed.
4. **Memoization** — If a signal is evaluated at the same coordinates multiple times, cache the result?
5. **Type system** — Should the type system distinguish `Float` from `Signal<Float>`? This would be a major addition.

### Status

- **Remap on params** — DONE. All params are signal-capable, no annotation needed.
- **Tighten RemapExpr.base type** — TODO. `RemapExpr.base` is currently `Expr` (any expression). Could be narrowed to `StrandAccess` for tighter type safety, but requires propagating the change through WeftDesugar, WeftLowering, and anywhere else that constructs/destructures `RemapExpr`. Low priority, purely internal cleanup.
- **Texture indirection** — needed so heavy expressions (perlin3, fbm3) don't explode when remapped. Described above.
- **First-class signals** — long-term. Signals as return values, dynamic dispatch, runtime composition. Described below.

### Relationship to Other Features

- **Spindle cache inlining** (`spindle-cache-inlining.md`): Both features need expression substitution during inlining. Should share infrastructure.
- **Remap operator**: Already exists, just needs to work on signal-typed parameters
- **Cross-domain buffers**: Signals that cross domains (audio signal used in visual) already go through buffers — first-class signals shouldn't change this path

## Recommendation

Implement Phase 1 (signal parameters) first. It's a small, well-scoped compiler change that solves the immediate expressiveness gap — blur, edge detection, convolution, displacement all become writable as spindles. Phase 2+ only matters if users need dynamic signal dispatch, which is a rarer pattern.
