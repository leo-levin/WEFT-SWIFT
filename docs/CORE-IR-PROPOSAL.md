# WEFT Core IR Design Proposal

**Author:** Claude (Opus 4.5)
**Date:** January 2026
**Status:** Draft / Open for Discussion

---

## 1. Executive Summary

This document proposes a minimal "Core" intermediate representation for WEFT, analogous to GHC's Core for Haskell. The goal is to identify the fundamental semantic primitives of WEFT versus syntactic sugar that could desugar to simpler constructs.

**Key claims:**
1. WEFT is a **synchronous dataflow language** with **signal-edge-triggered state**
2. The core can be reduced to ~10 expression forms
3. Most surface syntax (spindles, chains, ranges, remap) is sugar
4. The `cache` primitive has unusual semantics that deserve careful treatment

**This document is intended to provoke discussion.** Many design choices are debatable.

---

## 2. Background: What I Observed

### 2.1 The Current IR

The existing IR (`Sources/SWeftLib/IR/IR.swift`) has these expression forms:

```swift
public indirect enum IRExpr {
    case num(Double)
    case param(String)
    case index(bundle: String, indexExpr: IRExpr)
    case binaryOp(op: String, left: IRExpr, right: IRExpr)
    case unaryOp(op: String, operand: IRExpr)
    case call(spindle: String, args: [IRExpr])
    case builtin(name: String, args: [IRExpr])
    case extract(call: IRExpr, index: Int)
    case remap(base: IRExpr, substitutions: [String: IRExpr])
    case cacheRead(cacheId: String, tapIndex: Int)
}
```

### 2.2 The Evaluation Model

From reading the codebase, I understand WEFT as:

- **Synchronous dataflow**: Programs define a dependency graph evaluated once per "tick"
- **Implicit iteration**: Visual code runs per-pixel, audio code runs per-sample
- **Pull-based**: Sinks (`display`, `play`) pull values through the graph
- **Partitioned execution**: Programs split into "swatches" by backend domain

### 2.3 The Cache Mechanism

The `cache(value, historySize, tapIndex, signal)` builtin is the only source of state. It has **signal-edge semantics**: the cache updates only when the `signal` argument **changes value**, not on every tick.

This is implemented in `CacheManager.swift` with explicit cycle-breaking via `cacheRead`.

---

## 3. Proposed Core IR

### 3.1 Design Philosophy

I'm proposing a Core that:
1. Makes implicit structure explicit (especially the indexed-family nature)
2. Uses standard PL concepts (products, guarded recursion, applicative functors)
3. Has clear typing rules and operational semantics
4. Enables equational reasoning

### 3.2 The Key Insight

**WEFT expressions are indexed families, not plain values.**

A "visual Float" is really a function `(x, y, t) → Float`. The coordinate context (`me`) provides the index. This is why `remap` exists—it's reindexing.

### 3.3 Proposed Syntax

```
Types:
  τ ::= Float                    -- Base type
      | τ × τ                    -- Product (bundles)
      | ●                        -- Unit
      | Stream i τ               -- Indexed family
      | Later τ                  -- Guarded delay (for feedback)

Index sorts:
  i ::= V                        -- Visual: (x, y, t)
      | A                        -- Audio: (i, t, rate)
      | P                        -- Pure: ()

Expressions:
  e ::= n                        -- Float literal
      | x                        -- Variable
      | ()                       -- Unit
      | (e₁, e₂)                 -- Pair
      | fst e | snd e            -- Projections
      | let x = e₁ in e₂         -- Binding
      | e₁ ⊕ e₂                  -- Binary operators
      | ⊖ e                      -- Unary operators
      | prim(e₁, ..., eₙ)        -- Builtin functions
      | here                     -- Current index
      | e ! j                    -- Reindex (sample e at index j)
      | pure e                   -- Lift to stream
      | e₁ <*> e₂                -- Applicative apply
      | fix (λx. e)              -- Guarded fixpoint
      | ▷ e                      -- Delay
      | e ⊛                      -- Force
      | sample r e               -- Sample resource

Programs:
  P ::= Decl*
  Decl ::= x : τ = e
```

### 3.4 Typing Rules (Selected)

```
─────────────────────────────
    here : Stream i (Idx i)


  e : Stream i τ    j : Stream i' (Idx i)
─────────────────────────────────────────
          e ! j : Stream i' τ


         e : τ    (where τ has no Stream)
        ─────────────────────────────────
              pure e : Stream i τ


  f : Stream i (τ → σ)    x : Stream i τ
─────────────────────────────────────────
          f <*> x : Stream i σ


     e : Later τ → τ     (guarded in x)
    ───────────────────────────────────
            fix (λx. e) : τ
```

### 3.5 Desugaring Examples

**Surface:**
```weft
display.r = me.x + me.y
```

**Core:**
```
display_r : Stream V Float
display_r = let idx = here in (fst idx) + (fst (snd idx))
```

**Surface:**
```weft
trail.val = cache(max(input, trail.val * 0.95), 2, 1, me.t)
```

**Core:**
```
trail : Stream V Float → Stream V Float
trail input = fix (λprev →
    let t = snd (snd here) in
    whenChanges t (max input ((▷prev)⊛ * 0.95))
)
```

---

## 4. Open Questions

### Q1: Is the indexed-family model right?

**My assumption:** Every WEFT expression is implicitly `Index → Value`, and making this explicit clarifies the semantics.

**Alternative view:** WEFT is simpler than this. Expressions are just values computed in a context. The "indexed family" framing adds complexity without benefit.

**Question for discussion:** Does the indexed-family model help or hurt understanding? Is there a simpler framing?

---

### Q2: Should `here` be primitive or derived?

**My proposal:** `here` is a primitive that returns the current index.

**Alternative:** Keep the current `me.x`, `me.y`, etc. as separate primitives. This is simpler and matches how backends actually provide these values.

**Trade-off:**
- `here` is more uniform and enables `reindex` to work cleanly
- Separate coord primitives are simpler and match implementation

---

### Q3: How should reindexing (`remap`) work?

**My proposal:** Explicit `e ! j` operator that samples expression `e` at index `j`.

**Current behavior:** `remap` does substitution, which works for pure expressions but has unclear semantics for resources.

**Questions:**
- If `e` contains `camera(...)`, does `e ! j` re-sample the camera? Or is it memoized?
- Is remap just substitution (sugar) or does it have real semantic content?

---

### Q4: What are the semantics of `cache`?

**My understanding:**
- Cache is a circular buffer that stores history
- It updates ("ticks") when the `signal` argument changes
- `tapIndex` reads from history (0 = current, 1 = previous, etc.)

**My proposal:** Model this as guarded recursion with explicit `Later` type.

**Open questions:**
- Is signal-edge-triggering fundamental, or could we use simpler time-stepped delay?
- What happens with `historySize > 2`? Is this multiple delays or a more complex buffer?
- Is `cacheRead` a separate primitive, or a derived form?

---

### Q5: Should spindles be first-class functions?

**Current state:** Spindles are macros—they get inlined at call sites.

**My proposal:** Keep them as sugar (inline during lowering).

**Alternative:** Make functions first-class with proper closures.

**Question:** Are there use cases for higher-order spindles? Passing spindles as arguments? If so, we need lambdas in Core.

---

### Q6: What is the type of resources?

**Resources:** `camera`, `microphone`, `texture`, `mouse`, `sample`, `load`

**Option A:** Resources are builtins with special types
```
camera : Stream V (Float × Float × Float)  -- Always at current pixel
camera_at : (Float × Float) → Stream V (Float × Float × Float)  -- At specified UV
```

**Option B:** Resources are indexed families that you sample
```
camera : Stream V Float → Stream V Float → Stream V (Float × Float × Float)
-- camera u v = RGB at (u, v)
```

**Option C:** Resources are opaque handles + sampling primitives
```
camera : Resource RGB
sample : Resource τ → Idx → τ
```

**Question:** Which model best captures how resources actually work in WEFT?

---

### Q7: How do we handle cross-domain communication?

**Current behavior:** Visual and audio swatches can reference each other's bundles. Buffers flow between domains.

**Questions:**
- What's the typing story? Is `Stream V Float` vs `Stream A Float` enforced?
- How do you convert between domains? Downsampling? Upsampling?
- Is this implicit coercion or explicit conversion?

---

### Q8: Is `let` needed in Core?

**My proposal:** Yes, explicit `let` enables:
- Clear sharing semantics
- Easier optimization (CSE is obvious)
- Cleaner desugaring target

**Alternative:** Bundle declarations handle all sharing. No need for expression-level `let`.

**Question:** Does adding `let` complicate the dataflow model? Bundles are the scheduling unit—does `let` interfere with that?

---

### Q9: What about conditionals?

**Current state:** WEFT has comparison operators (`<`, `==`, etc.) but I didn't see explicit `if-then-else`.

**Questions:**
- Is there `if e₁ then e₂ else e₃`?
- If not, is `step`/`smoothstep` sufficient for all conditional needs?
- Should Core have sum types and case expressions?

---

### Q10: Should types be explicit in Core?

**My proposal:** Yes, Core expressions are explicitly typed.

**Alternative:** Types are inferred/implicit (current state).

**Trade-offs:**
- Explicit types catch errors early and document intent
- Implicit types are more concise
- Width inference already exists—should strand counts be types?

---

## 5. Assumptions I'm Making

These are beliefs I've formed that may be wrong. Please challenge them.

### A1: WEFT is pure except for `cache`

I assume all expressions are referentially transparent except for `cache` which introduces controlled state. Resources (`camera`, etc.) are pure functions of their arguments.

**Could be wrong if:** Resources have side effects, caching behavior, or frame-dependent state beyond what's captured by coordinates.

### A2: Evaluation is synchronous

I assume each tick fully evaluates all needed expressions before the next tick. There's no async, no partial evaluation, no lazy semantics.

**Could be wrong if:** There's intended laziness or demand-driven evaluation I missed.

### A3: Width is a type-level concern

I assume strand count ("width") is static and known at compile time. `display[r,g,b]` always has 3 strands.

**Could be wrong if:** Dynamic width is intended (e.g., variable number of audio channels).

### A4: Spindles don't need to be first-class

I assume all spindle calls can be inlined. There's no need for higher-order programming.

**Could be wrong if:** There are planned features requiring function values.

### A5: The two-domain model is fixed

I assume Visual and Audio are the only domains, with fixed coordinate types.

**Could be wrong if:** The system should support user-defined domains (3D, MIDI, network, etc.).

### A6: Cache signal-edge semantics are intentional

I assume the "tick on change" behavior is a deliberate design choice, not an implementation accident.

**Could be wrong if:** This was expedient rather than principled, and simpler delay semantics would suffice.

---

## 6. Alternative Designs Considered

### Alt 1: Keep it simple—just clean up the AST

Don't introduce new abstractions. Just:
- Remove redundant constructs
- Clarify what's sugar vs primitive
- Better document existing semantics

**Pro:** Less work, less risk of over-engineering
**Con:** Misses opportunity for principled foundation

### Alt 2: Arrow-based formulation

Model WEFT as a restricted Arrow (like Yampa):
```
type SF i o = Stream i → Stream o
arr : (a → b) → SF a b
(>>>) : SF a b → SF b c → SF a c
loop : SF (a, c) (b, c) → SF a b
```

**Pro:** Well-studied semantics, lots of literature
**Con:** Might be overkill for WEFT's needs

### Alt 3: Synchronous dataflow (Lustre/Esterel style)

Model WEFT as a synchronous language:
```
node filter(input : float) returns (output : float)
let
    output = 0.0 -> pre(output) * 0.9 + input * 0.1
tel
```

**Pro:** Matches WEFT's actual execution model closely
**Con:** Less familiar to functional programmers

### Alt 4: Shader-first model

Accept that WEFT is basically a shader language:
```
-- Everything is implicitly: Coord → Color
main(uv : vec2, t : float) → vec4
```

**Pro:** Simple, matches target
**Con:** Doesn't generalize well to audio or other domains

---

## 7. Requested Feedback

I'd appreciate thoughts on:

1. **Is the indexed-family framing useful?** Or is it over-complicating things?

2. **What's the right model for `cache`?** Guarded recursion? Explicit state? Something else?

3. **Should resources be pure?** What are the actual semantics of `camera`, `microphone`, etc.?

4. **Are there WEFT features I misunderstood?** Please correct my mental model.

5. **What's the goal of Core?** Optimization? Verification? Documentation? Portability? This affects design priorities.

6. **Is explicit typing worth the complexity?** Or should Core stay dynamically typed?

---

## 8. Next Steps (if we proceed)

1. **Settle open questions** — especially around cache, resources, and reindexing
2. **Write formal semantics** — small-step or denotational
3. **Implement Core types** — `CoreExpr`, `CoreType` in Swift
4. **Build lowering pass** — Surface IR → Core
5. **Validate** — ensure all existing programs can be expressed
6. **Iterate** — refine based on what we learn

---

## Appendix A: Current IR to Proposed Core Mapping

| Current IR | Proposed Core | Notes |
|------------|---------------|-------|
| `num(n)` | `n` | Direct |
| `param(s)` | `proj(here, s)` | Extract from index |
| `index(b, i)` | `proj(b, i)` | Bundle projection |
| `binaryOp(op, l, r)` | `l ⊕ r` | Direct |
| `unaryOp(op, e)` | `⊖ e` | Direct |
| `builtin(f, args)` | `prim(f, args)` | Direct |
| `call(s, args)` | Inline expansion | Sugar |
| `extract(c, i)` | `proj(c, i)` | After inlining |
| `remap(e, subs)` | `e ! modified_idx` | Reindexing |
| `cacheRead(id, t)` | `(▷ⁿ e)⊛` | Guarded delay |

---

## Appendix B: Example Full Desugaring

**Surface WEFT:**
```weft
img[r,g,b] = camera(me.x, me.y)
brightness.val = img.r * 0.3 + img.g * 0.6 + img.b * 0.1
display[r,g,b] = [brightness.val, brightness.val, brightness.val]
```

**Proposed Core:**
```
img : Stream V (Float × Float × Float)
img =
  let (x, y, t) = here in
  sample camera (x, y)

brightness : Stream V Float
brightness =
  let (r, g, b) = img in
  r * 0.3 + g * 0.6 + b * 0.1

display : Stream V (Float × Float × Float)
display = (brightness, brightness, brightness)
```

---

*End of proposal. Feedback welcome.*
