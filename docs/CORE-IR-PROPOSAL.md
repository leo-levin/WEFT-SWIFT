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
      | Stream b τ               -- Indexed family over backend b
      | Later τ                  -- Guarded delay (for feedback)
      | ∀b. τ                    -- Backend-polymorphic (pure)

Backends:
  b ::= (user-defined)           -- NOT hardcoded to Visual/Audio

  -- Each backend defines:
  -- • Coordinate type (what fields does `here` have?)
  -- • Owned builtins (which resources belong to this backend?)
  -- • Iteration domain (per-pixel? per-sample? per-vertex?)

Expressions:
  e ::= n                        -- Float literal
      | x                        -- Variable
      | ()                       -- Unit
      | (e₁, e₂)                 -- Pair
      | fst e | snd e            -- Projections
      | e.ₙ                      -- Static projection (strand n)
      | e.(e')                   -- Dynamic projection (conditional!)
      | let x = e₁ in e₂         -- Binding
      | e₁ ⊕ e₂                  -- Binary operators
      | ⊖ e                      -- Unary operators
      | prim(e₁, ..., eₙ)        -- Builtin functions
      | here                     -- Current index
      | e @ j                    -- Reindex (sample e at index j)
      | pure e                   -- Lift to stream
      | e₁ <*> e₂                -- Applicative apply
      | fix (λx. e)              -- Guarded fixpoint
      | ▷ e                      -- Delay
      | e ⊛                      -- Force
      | read r e                 -- Read resource (IMPURE)

Programs:
  P ::= Decl*
  Decl ::= x : τ = e
```

### 3.4 Typing Rules (Selected)

```
─────────────────────────────
    here : Stream b (Coords b)      -- Coords is backend-specific


  e : Stream b τ    j : Stream b' (Coords b)
────────────────────────────────────────────
          e @ j : Stream b' τ               -- Reindex across backends


           e : τ    (τ is pure, no Stream)
          ────────────────────────────────
               pure e : ∀b. Stream b τ      -- Polymorphic lifting


  f : Stream b (τ → σ)    x : Stream b τ
─────────────────────────────────────────
          f <*> x : Stream b σ


     e : Later τ → τ     (guarded in x)
    ───────────────────────────────────
            fix (λx. e) : τ


        e : ∀b. Stream b τ
       ─────────────────────
        e : Stream b' τ                     -- Instantiate polymorphic
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

**Update:** Since resources (camera, microphone) are NOT pure, remap has real semantic content—it's not just substitution.

**Questions:**
- If `e = camera(me.x, me.y)` and we do `e(me.x ~ me.x + 0.1)`, does this:
  - (a) Substitute to get `camera(me.x + 0.1, me.y)` and sample once?
  - (b) Sample `camera` twice (original and offset)?
- Is `remap` fundamentally about **coordinate transformation** or **re-evaluation**?
- Does remapping a cached expression read from the same cache or create a new one?

**This is now clearly fundamental, not sugar.**

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

**Key fact:** Resources are NOT pure. `camera(u, v)` returns different values on different frames even for the same `(u, v)`.

**Option A:** Resources are frame-indexed
```
camera : Frame → UV → RGB
-- Implicitly: current frame is in scope, like `me.t`
```

**Option B:** Resources are effectful operations (monadic)
```
camera : UV → IO RGB
-- But WEFT doesn't have IO monad...
```

**Option C:** Resources are "external signals" with implicit time dependency
```
camera : Signal (UV → RGB)
-- A time-varying function
```

**Option D:** Resources are textures that get "captured" at frame boundaries
```
-- At frame start: cameraTexture = captureCamera()
-- During frame: camera(u,v) = sampleTexture(cameraTexture, u, v)
-- This makes per-frame behavior pure, with impurity at frame boundaries
```

**Question:** Which model matches the actual implementation? Option D seems closest to how GPU code typically works (capture input textures, then pure sampling).

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

### Q9: ~~What about conditionals?~~ RESOLVED

**Answer:** Conditionals are expressed via dynamic bundle indexing:

```weft
[elseExpr, thenExpr].(condition)
```

Where `condition` evaluates to 0 or 1. This indexes into the 2-element bundle.

**Implications for Core:**
- Dynamic indexing (`bundle.(expr)`) is fundamental, not sugar
- No need for `if-then-else` or sum types
- This is similar to `select` in GPU shader languages
- Both branches are evaluated (no short-circuiting) — important for side-effect semantics

**Open question:** What happens if condition is not exactly 0 or 1? Linear interpolation? Floor? Error?

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

### A1: ~~WEFT is pure except for `cache`~~ WRONG

~~I assume all expressions are referentially transparent except for `cache` which introduces controlled state. Resources (`camera`, etc.) are pure functions of their arguments.~~

**Correction:** Resources like `camera` and `microphone` are **NOT pure**. They read from external state that changes over time independently of the program.

**Implications:**
- `remap` cannot simply be substitution for resource-containing expressions
- `camera(u, v)` at the same `(u, v)` returns different values on different frames
- This means resources are more like "effectful reads" than pure functions
- Core needs to distinguish pure expressions from effectful ones

**New question:** What IS the model for resources?
- Option A: Resources are implicit parameters that change each frame (like `me.t`)
- Option B: Resources are monadic effects that must be sequenced
- Option C: Resources are first-class "signals" with their own identity

### A2: Evaluation is synchronous

I assume each tick fully evaluates all needed expressions before the next tick. There's no async, no partial evaluation, no lazy semantics.

**Could be wrong if:** There's intended laziness or demand-driven evaluation I missed.

### A3: Width is a type-level concern

I assume strand count ("width") is static and known at compile time. `display[r,g,b]` always has 3 strands.

**Could be wrong if:** Dynamic width is intended (e.g., variable number of audio channels).

### A4: Spindles don't need to be first-class

I assume all spindle calls can be inlined. There's no need for higher-order programming.

**Could be wrong if:** There are planned features requiring function values.

### A5: ~~The two-domain model is fixed~~ WRONG

~~I assume Visual and Audio are the only domains, with fixed coordinate types.~~

**Correction:** WEFT should support **arbitrary backends**, not just Visual and Audio.

**Implications:**
- Index sorts can't be hardcoded as `V | A | P`
- Backends define their own coordinate systems
- The type system needs to be parameterized by backend
- Cross-backend communication needs a general solution

**New questions:**
- How are backends declared/registered?
- What defines a backend's coordinate type?
- Can user code define new backends, or only the runtime?
- How do we type expressions that work across any backend (polymorphism)?

**Revised type system sketch:**
```
Backend b ::= (declared at runtime/config level)
Coords b ::= (backend-specific, e.g., {x,y,t} for visual, {i,t,rate} for audio)

τ ::= Float
    | τ × τ
    | Stream b τ        -- Parameterized by backend b
    | ∀b. Stream b τ    -- Backend-polymorphic (pure expressions)
```

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

3. ~~**Should resources be pure?**~~ **ANSWERED: No.** New question: What's the right model for impure resources? Frame-captured textures?

4. **Are there WEFT features I misunderstood?** Please correct my mental model.
   - ✓ Conditionals are via bundle indexing: `[else, then].(cond)`
   - ✓ Resources (camera, mic) are not pure

5. **What's the goal of Core?** Optimization? Verification? Documentation? Portability? This affects design priorities.

6. **Is explicit typing worth the complexity?** Or should Core stay dynamically typed?

7. **NEW: Is dynamic bundle indexing fundamental?** Given that conditionals use `[a,b].(cond)`, dynamic indexing seems core to the language. Should this be a primitive, or can it desugar to something simpler?

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
