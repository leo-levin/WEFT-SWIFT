# WEFT Swift Architecture

## Core Philosophy

WEFT is a **domain-agnostic language** for creative computation. You can write code that spans visual, audio, MIDI, OSC, 3D, or any other domain. The language doesn't care—but computation does.

The compiler's job is to take domain-agnostic WEFT code and figure out how to execute it across multiple specialized backends.

---

## Mental Model

**A node is a function from coordinates to values.**

- Visual node: `(x, y, t) → (r, g, b)`
- Audio node: `(i, t) → (out)`
- MIDI node: `(channel, t) → (note, velocity)`

The coordinate system is domain-specific. The user provides coordinates when accessing across domains—coordinate mapping is the user's responsibility, not the system's.

---

## Pure vs Stateful

Every node is either **pure** or **stateful/external**.

**Pure nodes** produce the same output for the same input, regardless of when or where they're computed. Math operations, stateless transformations.

**Stateful nodes** depend on history. Statefulness comes from:
- Using `cache` (history buffer with signal-driven ticks)
- Self-reference with coordinate offset (recursive computation)

**External nodes** come from hardware or the outside world. `microphone()`, `camera()`, `midi_in()`.

This distinction matters for cross-domain access. Statefulness propagates: if a node depends on anything stateful, it's effectively stateful.

---

## Cross-Domain Access

When domain A needs a value from domain B:

**If the node is pure:** Domain A can recompute it locally by substituting its coordinates into the expression. No communication needed.

**If the node is stateful/external:** Domain A must read from a buffer that domain B has written to. The value can't be recomputed—it depends on state that only B has.

---

## Backend Ownership

A node's backend is determined **only by builtins**.

Each backend registers its domain-specific builtins:

- `camera`, `load` → visual
- `microphone` → audio
- `midi_in` → midi
- `osc_in` → osc
- etc.

If a node uses a domain-specific builtin, it belongs to that backend. If a node uses no domain-specific builtins (pure math, generic operations), it has **no native backend**.

---

## Duplication vs Cross-Domain

**Pure nodes are duplicated, not shared.**

If both visual and audio need `sin(x * 440)`, each backend computes it independently. No cross-domain connection. This minimizes dependencies between Swatches.

**Cross-domain connections only exist for stateful/external nodes.**

If visual needs `microphone()` output, that's a true cross-domain connection—audio owns the microphone, visual reads from audio's buffer.

This means:

- Pure expressions can appear in multiple Swatches (duplicated)
- Stateful/external nodes appear in exactly one Swatch (their owner)
- Cross-domain edges only connect to stateful/external nodes

---

## The Graph

The compiler builds a dependency graph from the IR. Each node has:

- Dependencies (what it reads from)
- Backend ownership (from builtins, or none if pure)

Edges are either:

1. **Same-backend** — both nodes belong to the same backend
2. **Cross-domain** — connects to a stateful/external node in another backend
3. **Duplicated** — pure node needed by multiple backends (no edge, just copy the expression)

---

## Swatches

A **Swatch** is a connected subgraph of same-backend edges.

Cross-domain edges don't contribute to connectivity. This means if there's back-and-forth between domains, you get multiple smaller Swatches rather than one large one.

**A Swatch is the unit of compilation for a backend.**

Example with interleaving:

```
audio.a → img.x → audio.b → img.y
```

The cross-domain edges break connectivity, creating 4 Swatches:

1. `{audio.a}` — audio
2. `{img.x}` — visual (depends on swatch 1)
3. `{audio.b}` — audio (depends on swatch 2)
4. `{img.y}` — visual (depends on swatch 3)

---

## Swatch Inputs and Outputs

Each Swatch has explicit inputs and outputs.

**Inputs:** Cross-domain values this Swatch needs to read.

- If the source is pure → Swatch can recompute it (inline the expression)
- If the source is stateful → Swatch reads from a buffer

**Outputs:** Values this Swatch exposes. Three types:

1. **Render sinks** — `display`, `play`, etc. Final output to hardware.
2. **Cross-domain refs** — Another Swatch needs to read this value.
3. **Debug probes** — Values exposed for inspection (treated like render).

---

## Functional Compilation

**Only outputs matter. Everything else is just how to compute those outputs.**

Intermediate values don't "exist" as stored data. They're expressions that get composed and inlined. Only materialize at:

1. Render sinks (hardware needs actual values)
2. Stateful cross-domain boundaries (can't recompute)
3. Debug probes

**A Swatch compiles to n functions, where n = number of outputs.**

Example:

```
a = sin(me.t * 440)
b = a * 0.5
c = b + 0.1
play c
```

There are no stored values for `a`, `b`, `c`. There's one output (`play`) with a fully-inlined expression:

```
play: sin(me.t * 440) * 0.5 + 0.1
```

**Swatch as function:**

```
Swatch {
    backend: visual
    inputs: [audioBuffer]
    outputs: [
        (display, expr_rgb),
        (brightness, expr_b)
    ]
}
```

Compiles to:

```
(me, audioBuffer) → {
    display: expr_rgb(me, audioBuffer),
    brightness: expr_b(me, audioBuffer)
}
```

The backend decides whether to emit one combined function or separate ones. Common subexpressions can be extracted during codegen if needed.

---

## Bundles and Dynamic Indexing

A bundle is a collection of expressions, not computed values. Strand access selects which expression to use.

**Static index** — resolved at compile time:

```
color.r       → inline that strand's expression
color.0       → inline that strand's expression
[a, b, c].1   → inline `b`
```

**Dynamic index** — resolved at runtime:

```
color.(i)        → emit selection code
[a, b, c].(i)    → emit selection code
```

Dynamic indexing compiles to a switch/conditional:

```
[a, b, c].(i)  →  switch(i) { 0: a, 1: b, 2: c }
```

Only the selected branch evaluates. This is how conditionals work in WEFT:

```
[me.x, 1/me.x].(me.x == 0)   // safe: 1/me.x only evaluates when me.x != 0
```

No special lazy evaluation machinery. The bundle is just grouped expressions. Dynamic indexing emits control flow that selects which expression to evaluate.

**Cross-domain refs in branches:**

```
[sin(me.x), audio.left(me.t ~ me.x)].(condition)
```

If one branch has a cross-domain reference:

- **Compile time:** The whole expression has the dependency. The Swatch needs the buffer bound, must execute after the producer.
- **Runtime:** The buffer read only happens if that branch is selected.

Dependencies are static (must prepare for all branches). Execution is dynamic (only selected branch runs).

---

## Spindles

A spindle is a parameterized expression — a function that returns one or more values.

**Spindle calls inline by substitution:**

```
spindle add_and_mult(a, b) {
  return .0 = a + b
  return .1 = a * b
}

foo = add_and_mult(x, y).0  →  inlines to: x + y
```

Only the requested return expression is inlined. Unused returns aren't computed.

**Spindle properties propagate from their body:**

- Uses stateful builtin → spindle is stateful
- Uses domain-specific builtin → spindle belongs to that domain
- Pure body → spindle is pure, can duplicate across backends

**Stateful spindles create instances:**

```
a = filter(input1, 100).0
b = filter(input2, 200).0
```

Each call site with different args is a separate stateful node with its own state. A stateful spindle is a node factory.

**Recursive spindles:**

```
spindle fib(n) {
  return .0 = [0, 1, fib(n-1) + fib(n-2)].(clamp(n, 0, 2))
}
```

Recursion can't inline infinitely. Recursive spindles:

- Detected via call graph cycle analysis
- Emit as actual functions (not inlined)
- Run on CPU (GPU doesn't support recursion)
- If GPU needs the result, it's a cross-domain dependency

**Self-reference with coordinate offset:**

```
fib = [0, 1, fib(me.t ~ me.t-1) + fib(me.t ~ me.t-2)].(clamp(me.t, 0, 2))
```

This is self-reference (fib references fib with offset coordinates). It creates a recurrence relation that must be evaluated sequentially.

**For efficient feedback**, use `cache` instead—it provides a history buffer with O(1) lookup. See the "Self-Reference and Feedback" section for details.

---

## Self-Reference and Feedback

A bundle can reference itself with a coordinate offset:

```
row_sum = row_sum(me.x ~ me.x-1) + input.0
```

This creates a **recurrence relation**. The value at coordinate N depends on the value at coordinate N-1. Self-reference compiles to recursive computation with memoization—correct but potentially slow.

**The `cache` spindle is the primitive for efficient feedback:**

```
cache(value, history_size, tap_index, signal)
```

- **value** — what to store in the history buffer
- **history_size** — how many values to keep
- **tap_index** — which historical value to return (0 = most recent, N = N ticks ago)
- **signal** — what defines a "tick"

**Tick semantics: tick when signal CHANGES.**

The cache ticks (shifts history, stores new value) when the signal value differs from its value at the previous tick. This is edge-triggered, not level-triggered.

**Why change-based?** A constant signal like `1` is positive everywhere—every pixel, every sample. "Tick when positive" would be ambiguous. "Tick when changed" is unambiguous: a constant never changes after initialization, so it ticks once and freezes.

**Domain-agnostic through signal choice:**

```
cache(brightness, 1, 0, me.t)         // tick per frame (visual feedback)
cache(sample, 44100, 22050, me.i)     // tick per sample (audio delay line)
cache(value, 10, 5, floor(me.t/10))   // tick every 10 frames
cache(value, 1, 0, 1)                 // tick once, then frozen forever
```

The signal parameter makes cache work for any domain without hardcoding "frames" or "samples."

**Signal selection matters.** The signal should be a value that changes across invocations *at the same coordinate*. Spatial coordinates like `me.x` are constant at each pixel across frames—they make poor signals (tick once, then frozen). Time-like coordinates (`me.t`, `me.i`) change at every coordinate and are typically what you want.

**Feedback loop example:**

```
brightness = cache(brightness, 1, 0, me.t) * 0.99 + input * 0.01
```

- `cache(brightness, 1, 0, me.t)` returns the previous frame's brightness
- Compute new value: `prev * 0.99 + input * 0.01`
- Cache stores the new value for next tick
- No circularity: cache returns stored value (doesn't depend on current input)

**Audio delay example:**

```
delayed = cache(input, 44100, 22050, me.i)   // 0.5 sec delay at 44.1kHz
output = input * 0.7 + delayed * 0.3         // mix dry and wet
```

**Why two mechanisms (self-reference vs cache)?**

- **Self-reference** is general—works on any coordinate, any pattern. But it's recursive computation: potentially slow, evaluated sequentially.
- **Cache** is a history buffer—O(1) lookup, GPU-compatible. But requires explicit signal to define tick boundaries.

For spatial recurrence (convolution, prefix sums), use self-reference. For temporal feedback (trails, echoes, filters), use cache.

---

## Execution Model

The Swatch graph (Swatches connected by cross-domain dependencies) determines execution order.

1. Topologically sort the Swatch graph
2. Execute Swatches in order
3. Each Swatch writes its outputs to buffers (if stateful and cross-domain accessed)
4. Later Swatches read from those buffers

A single backend may have multiple Swatches if there's interleaving with other backends.

---

## Shared Memory

On Apple Silicon, all backends share unified memory. Buffers are accessible to CPU, GPU, and any compute kernel without copying.

This makes cross-domain buffer access essentially free—just a pointer lookup.

---

## Backend Responsibilities

Backends are relatively dumb. They receive:

- A Swatch (subgraph of nodes to compute)
- Input buffer bindings (for cross-domain reads)
- Output buffer requirements (what to write)

Backends compile the Swatch to their native format (Metal shader, audio graph, etc.) and execute when told.

The Coordinator handles:

- Building the Swatch graph
- Determining execution order
- Managing buffer allocation
- Orchestrating execution

---

## Compilation Pipeline

```
Source → Parse → AST → Lower → IR → Build Graph → Partition into Swatches → Compile per Backend
```

1. **Parse:** WEFT source → AST
2. **Lower:** AST → IR (bundles, spindles, expressions)
3. **Build Graph:** IR → node graph with backend ownership
4. **Partition:** Node graph → Swatches (connected same-backend components)
5. **Analyze:** Identify inputs/outputs, pure vs stateful
6. **Compile:** Hand each Swatch to its backend

---

## Unified Model

The compiler should be a small set of uniform rules, not case-by-case handling.

**Core principle: everything is an expression with properties.**

Every expression has:

- **Purity:** pure, stateful, or external
- **Domain:** which backend owns it (from builtins), or none
- **Dependencies:** what it references

**Properties propagate uniformly:**

- If any sub-expression is stateful → the whole thing is stateful
- If any sub-expression belongs to a domain → the whole thing does (or is cross-domain)
- Dependencies are the union of sub-expression dependencies

**Compilation is substitution until you hit a boundary:**

- Inline expressions recursively
- Stop at: outputs, cross-domain stateful refs, recursion

**The only special cases:**

1. **Recursion** — can't substitute infinitely → emit function → CPU
2. **Cross-domain stateful** — can't recompute → buffer read
3. **Dynamic index** — can't resolve at compile time → emit control flow
4. **Self-reference** — creates recurrence relation → recursive eval with memoization
5. **Cache** — signal-driven history buffer → tick when signal changes

Everything else follows from uniform application of these rules. If a new construct needs special handling, the model is probably wrong.
