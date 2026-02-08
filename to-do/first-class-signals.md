# Everything Is a Signal

## Core Principle

In WEFT, there is no distinction between a value and a signal. Every expression is a signal — a function from coordinates to a value. A "constant" is just a signal that ignores its coordinates. A "value" is just a signal evaluated at the current coordinate.

Evaluation is **pull-based**. Nothing evaluates until a sink (`display`, `play`) asks for it. The sink pulls a value at its coordinates, and that pull propagates back through the expression graph — through bundle references, through spindle returns, through remaps. Coordinate context flows backwards from sink to source.

The compiler's job is to preserve the signal graph intact and only collapse it when a sink demands evaluation. Anywhere the compiler eagerly evaluates — spindle returns, bundle storage — is a bug, not a design choice.

## Current State

The IR already represents everything as expression trees (`IRExpr`) — signals in disguise. But the compiler eagerly collapses the graph in places instead of letting sinks pull:

- **Signal parameters** — FIXED (PR #26). Params preserve expression trees through spindle boundaries.
- **Signal returns** — BROKEN. Spindle returns collapse to scalars. The caller can't remap the result. The pull stops at the spindle boundary.
- **Signal storage** — PARTIALLY WORKS. Bundles store expressions that inlining can substitute, but this breaks when a spindle return sits in the chain.
- **Heavy signal duplication** — BROKEN. Remapping a signal N times inlines the full expression N times. The pull duplicates the entire upstream graph instead of sharing it.

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

The pull from a sink should propagate through spindle returns transparently. `buildSpindleSubstitutions` and `getDirectExpression` need to follow through spindle returns without collapsing — the return expression is part of the signal graph, not a termination point.

### 2. Shared Pulls (Evaluate-Once)

When multiple sinks (or remap branches) pull the same signal at different coordinates, the compiler should recognize the shared upstream and evaluate it once — not duplicate the entire graph per pull.

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

Fix returns first — it's the most visible violation of pull-based evaluation. Shared pulls (evaluate-once) is the performance safety net that prevents the graph from exploding when pulls fan out through remaps. Should ship alongside or before, since fixing returns exposes more of the graph to duplication. Conditional signals are a longer-term project.

## Files

| Component | Change |
|-----------|--------|
| **IRTransformations** | Defer return inlining, keep expression trees through spindle returns |
| **MetalCodeGen** | Generalize `scanForHeavyRemaps` to IR-level CSE |
| **AudioBackend** | Memoized closures for remap bases |
| **Partitioner** | May split swatches for multi-pass rendering |
