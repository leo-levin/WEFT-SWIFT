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

## Interim Solution: Signal Parameters (Compile-Time)

Add a marker on spindle parameters that tells the compiler "substitute the expression, don't evaluate it." This is purely compile-time — no runtime closures needed.

### Syntax Options

```weft
// Option A: sigil on parameter name
spindle edge(input~, delta) { ... }

// Option B: keyword
spindle edge(signal input, delta) { ... }

// Option C: type annotation
spindle edge(input: signal, delta) { ... }
```

### How It Works

1. At the call site `edges[mag] = edge(gray.v, 0.005)`, the compiler sees `input~` is a signal parameter
2. Instead of evaluating `gray.v` and passing the value, it records the expression `gray.v`
3. When inlining the spindle body, `input` is replaced with the expression `gray.v`
4. Now `gray.v ~ me.x - delta` is valid — remap sees a bundle.strand

### What This Enables

```weft
spindle edge(input~, delta) {
    l[v] = input ~ me.x - delta
    r[v] = input ~ me.x + delta
    return.mag = abs(l.v - r.v)
}

spindle blur3x3(input~) {
    sum.v = 0
    // sample 3x3 neighborhood
    for dx in [-1, 0, 1] {
        for dy in [-1, 0, 1] {
            sum.v = sum.v + (input ~ me.x + dx/me.w, me.y + dy/me.h)
        }
    }
    return.0 = sum.v / 9
}

edges[mag] = edge(gray.v, 0.005)
blurred[r,g,b] = blur3x3(img.r), blur3x3(img.g), blur3x3(img.b)
```

### Limitations

- Signal params must be bundle.strand expressions (or chains of them) — you can't pass `sin(me.x)` as a signal unless it's first assigned to a bundle
- No dynamic dispatch — the compiler must know the expression at compile time
- No passing signals between spindles at runtime

### Implementation (Compiler Changes)

**Parser/AST**: New parameter modifier. In `WeftParser.swift`, signal params get a flag.

**Desugaring**: No change — signal params are carried through as expression references.

**Lowering** (`WeftLowering.swift`): When inlining a spindle call:
- For normal params: evaluate to value, substitute
- For signal params: substitute the raw expression (don't evaluate)
- This is similar to the cache-inlining substitution (see `spindle-cache-inlining.md`)

**Codegen**: No change — by the time IR reaches codegen, signal params have been inlined away.

### Files to Modify

| File | Change |
|------|--------|
| `Sources/WEFTLib/Parser/WeftAST.swift` | Add `isSignal` flag to parameter definition |
| `Sources/WEFTLib/Parser/WeftParser.swift` | Parse signal parameter syntax |
| `Sources/WEFTLib/Lowering/WeftLowering.swift` | Expression substitution for signal params during inlining |

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

### Implementation Phases

**Phase 1**: Signal parameters (compile-time, described above) — solves 80% of use cases
**Phase 2**: Signal return values (still compile-time via monomorphization)
**Phase 3**: Runtime signal dispatch (requires expression interpreter in shader or texture indirection)

### Relationship to Other Features

- **Spindle cache inlining** (`spindle-cache-inlining.md`): Both features need expression substitution during inlining. Should share infrastructure.
- **Remap operator**: Already exists, just needs to work on signal-typed parameters
- **Cross-domain buffers**: Signals that cross domains (audio signal used in visual) already go through buffers — first-class signals shouldn't change this path

## Recommendation

Implement Phase 1 (signal parameters) first. It's a small, well-scoped compiler change that solves the immediate expressiveness gap — blur, edge detection, convolution, displacement all become writable as spindles. Phase 2+ only matters if users need dynamic signal dispatch, which is a rarer pattern.
