# Everything Is a Signal

## Core Principle

In WEFT, there is no distinction between a value and a signal. Every expression is a signal — a function from coordinates to a value. A "constant" is just a signal that ignores its coordinates. A "value" is just a signal evaluated at the current coordinate.

The compiler's job is to preserve this invariant everywhere: through spindle parameters, through returns, through bundle storage, through remaps. The user should never encounter a situation where something "collapsed to a value" and can't be remapped.

## Current State

The IR already represents everything as expression trees (`IRExpr`) evaluated per-coordinate — signals in disguise. But the compiler eagerly collapses them in places:

- **Signal parameters** — FIXED (PR #26). Params preserve expression trees through spindle boundaries.
- **Signal returns** — BROKEN. Spindle returns collapse to scalars. The caller can't remap the result.
- **Signal storage** — PARTIALLY WORKS. Bundles store expressions that inlining can substitute, but this breaks when a spindle return sits in the chain.
- **Heavy signal duplication** — BROKEN. Remapping a signal N times inlines the full expression N times. Crashes on deep spindle chains.

## What Needs to Happen

### 1. Fix Signal Returns

A spindle return is a signal, not a number. When a caller remaps a spindle's return value, the full expression tree must be available for coordinate substitution.

```weft
spindle gradient(a, b) {
    return.0 = lerp(a, b, me.x)
}

g.v = gradient(0, 1)
shifted.v = g.v(me.x ~ me.x + 0.1)  // must work
```

This is an inlining change: defer collapsing return expressions. `buildSpindleSubstitutions` and `getDirectExpression` need to follow through spindle returns without evaluating.

### 2. Evaluate-Once for Heavy Signals

When a signal is remapped N times, the compiler should evaluate it once and sample from the result — not inline it N times.

```weft
n.v = perlin3(me.x * 5, me.y * 5, 0)
e.v = edge(n.v, 0.003)  // remaps n.v at 4 coordinates internally
// Should emit: render n.v to texture, sample 4 times
// Not: inline perlin3 four times
```

Metal already has `scanForHeavyRemaps` for this. Needs to be generalized:
- IR-level pass to detect shared remap bases and extract them as pre-compute bundles
- Metal: intermediate texture (already exists, needs generalization)
- Audio: memoized closure (evaluate once per tick)

Detection heuristic: `expr.containsCall() || expr.nodeCount() > 50`

### 3. Conditional & Higher-Order Signals (Hard)

Dynamic signal dispatch. Only evaluate the branch that's needed.

```weft
spindle choose(cond, a, b) {
    return.0 = if(cond > 0, a, b)
}
```

Metal has no function pointers, so every signal path must resolve at compile time. Compile-time monomorphization (generate specialized code per concrete signal combination) is the most viable approach. This is essentially the same problem as generics/templates.

## Implementation Order

Fix returns first — it's the most visible violation of "everything is a signal." Evaluate-once is a performance safety net that should ship alongside or before, since fixing returns makes expression trees larger. Conditional signals are a longer-term project.

## Files

| Component | Change |
|-----------|--------|
| **IRTransformations** | Defer return inlining, keep expression trees through spindle returns |
| **MetalCodeGen** | Generalize `scanForHeavyRemaps` to IR-level CSE |
| **AudioBackend** | Memoized closures for remap bases |
| **Partitioner** | May split swatches for multi-pass rendering |
