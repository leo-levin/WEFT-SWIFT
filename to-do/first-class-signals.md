# Everything Is a Signal

## Core Principle

In WEFT, there is no distinction between a value and a signal. Every expression is a signal — a function from coordinates to a value. A "constant" is just a signal that ignores its coordinates. A "value" is just a signal evaluated at the current coordinate.

Evaluation is **pull-based**. Nothing evaluates until a sink (`display`, `play`) asks for it. The sink pulls a value at its coordinates, and that pull propagates back through the expression graph — through bundle references, through spindle returns, through remaps. Coordinate context flows backwards from sink to source.

The compiler's job is to preserve the signal graph intact and only collapse it when a sink demands evaluation.

## Current State

The IR represents everything as expression trees (`IRExpr`) — signals in disguise. The inlining pipeline (`buildSpindleSubstitutions`, `getDirectExpression`, `inlineExpression`) preserves expression trees through all boundaries:

- **Signal parameters** — WORKING (PR #26). Params preserve expression trees through spindle boundaries.
- **Signal returns** — WORKING. `getDirectExpression` inlines spindle returns as expression trees. `inlineExpression` recursively resolves `.call`/`.extract` nodes through `buildSpindleSubstitutions`, preserving the full expression graph for downstream remaps. Regression tests in `SpindleCacheInliningTest.swift` cover basic remap, locals, chained calls, and multi-return.
- **Signal storage** — WORKING. Bundles store expressions; inlining substitutes them transparently. Works through spindle return chains.
- **Heavy signal duplication** — PARTIALLY ADDRESSED. Metal has `scanForHeavyRemaps` + intermediate textures for evaluate-once. Audio has no equivalent. See below.

## What's Left

### 1. Generalize Evaluate-Once (Shared Pulls)

When multiple remap branches pull the same heavy signal at different coordinates, the compiler should evaluate the base once and sample from the result — not inline the full expression per pull.

```weft
spindle perlin(x, y) {
    h.v = fract(sin(x * 127.1 + y * 311.7) * 43758.5453)
    return.0 = h.v
}
spindle edge(input, delta) {
    l.v = input(me.x ~ me.x - delta)
    r.v = input(me.x ~ me.x + delta)
    return.0 = abs(l.v - r.v)
}
n.v = perlin(me.x * 10, me.y * 10)
e.v = edge(n.v, 0.003)
// Should emit: render n.v to intermediate texture, sample twice
// Not: inline perlin twice
display[r,g,b] = [e.v, e.v, e.v]
```

**Metal**: Already implemented. `scanForHeavyRemaps` detects heavy remap bases via `isHeavyExpression()` (threshold: `containsCall() || nodeCount() >= 30`). Emits intermediate texture kernels; the display kernel samples from them. Chained intermediates work (kernel i reads from intermediates 0..i-1).

**Audio**: No equivalent exists. Assess whether it's needed:
- Spatial remaps (`me.x ~`) don't apply to audio (1D domain)
- Temporal remaps (`me.t ~`) are already converted to `cache()` builtins
- Sample-index remaps (`me.i ~`) are the main case — rare in practice
- If needed: memoized closures in AudioCodeGen's `.remap` case

**Potential generalization**: Lift `isHeavyExpression` detection to an IR-level pass that tags remap bases for pre-computation. Each backend would implement its own materialization strategy (texture vs. closure memoization).

### 2. Conditional & Higher-Order Signals (Hard, Future)

Dynamic signal dispatch. Only evaluate the branch that's needed.

```weft
spindle choose(cond, a, b) {
    return.0 = if(cond > 0, a, b)
}
```

Metal has no function pointers, so every signal path must resolve at compile time. Compile-time monomorphization (generate specialized code per concrete signal combination) is the most viable approach. This is essentially the same problem as generics/templates.

## Files

| Component | Role |
|-----------|------|
| **IRTransformations** | `getDirectExpression` / `inlineExpression` — preserves signal graph through spindle returns |
| **MetalCodeGen** | `scanForHeavyRemaps` + intermediate textures — evaluate-once for visual domain |
| **AudioCodeGen** | No evaluate-once yet — assess if needed for `me.i` remaps |
| **IR.swift** | `isHeavyExpression()` heuristic — domain-agnostic |
