# Feature: Cache Inside Spindles

## Problem

Currently, cache cannot be used effectively inside spindles because:

1. Spindle locals are processed in definition order
2. Forward references don't resolve
3. Cache self-references need to target the OUTPUT bundle, not spindle locals

```weft
// This DOESN'T work:
spindle edecay(rate) {
    prev.val = cache(out.val, 2, 1, me.i)  // out.val not defined yet
    out.val = prev.val * rate
    return.0 = out.val
}

// Error: Unknown bundle 'prev' (or 'out' depending on order)
```

## Current Workaround

Move cache to call site, pass previous value as parameter:

```weft
spindle edecay(rate, prev) {
    return.0 = prev * rate
}

// Usage:
env.val = edecay(0.9999, cache(env.val, 2, 1, me.i))
```

This works but is verbose and requires users to understand the cache pattern.

## Desired Behavior

Cache inside spindles should "just work":

```weft
spindle edecay(rate) {
    prev.val = cache(out.val, 2, 1, me.i)
    out.val = prev.val * rate
    return.0 = out.val
}

// Usage:
env.val = edecay(0.9999)  // cache references env.val automatically
```

## Implementation Strategy

When inlining a spindle call assigned to `target.strand`:

1. **Detect return-connected caches**: Find cache expressions that reference locals connected to the return value
2. **Substitute target**: Replace those local references with the assignment target

### Example Transformation

```weft
// Source:
spindle edecay(rate) {
    prev.val = cache(out.val, 2, 1, me.i)
    out.val = prev.val * rate
    return.0 = out.val
}
env.val = edecay(0.9999)

// Step 1: Trace return path
// return.0 -> out.val -> prev.val * rate -> cache(out.val, ...) * rate
//                                                 ^^^^^^^ cycle!

// Step 2: Replace cyclic reference with target
// cache(out.val, ...) -> cache(env.val, ...)

// Step 3: Final inlined result
env.val = cache(env.val, 2, 1, me.i) * 0.9999
```

### Algorithm

```swift
func inlineSpindleWithCacheSubstitution(
    spindleDef: IRSpindle,
    args: [IRExpr],
    targetBundle: String,
    targetStrand: Int
) -> IRExpr {
    // 1. Build standard param substitutions
    var subs = buildParamSubstitutions(spindleDef, args)

    // 2. Find the return expression
    let returnExpr = spindleDef.returns[targetStrand]

    // 3. Identify which local (if any) is returned
    let returnedLocal = findReturnedLocal(returnExpr, spindleDef.locals)

    // 4. Find all cache nodes that reference returnedLocal (directly or indirectly)
    let cyclicCaches = findCachesReferencingLocal(returnedLocal, spindleDef.locals)

    // 5. For each cyclic cache, substitute the local reference with target
    for cacheExpr in cyclicCaches {
        // cache(localRef, ...) -> cache(.index(targetBundle, targetStrand), ...)
        substitueCacheTarget(cacheExpr, targetBundle, targetStrand)
    }

    // 6. Build full substitutions including modified locals
    subs = rebuildSubstitutions(spindleDef, args, modifiedLocals)

    // 7. Inline and return
    return substituteAll(returnExpr, subs)
}
```

### Edge Cases

1. **Multiple returns**: Each return strand may have different cache cycles
2. **Nested spindle calls**: Cache inside a spindle that calls another spindle
3. **Multiple caches**: Same local referenced by multiple cache nodes
4. **Non-cyclic caches**: Cache that doesn't reference return path (should work normally)

## Files to Modify

### IRTransformations.swift

Add new function:
```swift
public static func inlineSpindleCall(
    spindleDef: IRSpindle,
    args: [IRExpr],
    targetBundle: String,
    targetStrandIndex: Int
) -> IRExpr
```

Add helpers:
- `findReturnedLocal(expr:locals:) -> String?`
- `findCachesReferencingLocal(local:locals:) -> [CacheReference]`
- `substituteCacheTarget(cache:target:) -> IRExpr`

### WeftLowering.swift

When lowering bundle declarations, use new inliner:
```swift
case .spindleCall(let call):
    // Use enhanced inliner that handles cache target substitution
    return try inlineSpindleCallWithTarget(
        call.name,
        args: call.args,
        targetBundle: bundleName,
        targetStrand: strandIndex
    )
```

### CacheManager.swift

May need updates to recognize inlined cache patterns.

## Testing

```weft
// Test 1: Simple decay
spindle edecay(rate) {
    prev.val = cache(out.val, 2, 1, me.i)
    out.val = prev.val * rate
    return.0 = out.val
}
env.val = edecay(0.999)
// Expected: env decays over time

// Test 2: AR envelope
spindle ar(gate, attack, release) {
    prev.val = cache(out.val, 2, 1, me.i)
    up.val = min(prev.val + attack, 1)
    down.val = prev.val * release
    out.val = lerp(down.val, up.val, gate)
    return.0 = out.val
}
env.val = ar(gate.val, 0.01, 0.999)
// Expected: envelope follows gate

// Test 3: Filter
spindle lpf(input, freq) {
    prev.val = cache(out.val, 2, 1, me.i)
    alpha.val = freq / me.sampleRate
    out.val = prev.val + alpha.val * (input - prev.val)
    return.0 = out.val
}
filtered.val = lpf(noise.val, 1000)
// Expected: lowpass filtered noise

// Test 4: Multiple instances (should have independent state)
env1.val = edecay(0.999)
env2.val = edecay(0.99)
// Expected: env1 and env2 decay at different rates
```

## Alternative Approaches

### A: Magic "self" reference

Instead of detecting cycles, add explicit `self` keyword:

```weft
spindle edecay(rate) {
    prev.val = cache(self, 2, 1, me.i)  // self = output
    return.0 = prev.val * rate
}
```

Pros: Explicit, no cycle detection needed
Cons: New keyword, less intuitive

### B: Lazy local evaluation

Change local processing to be lazy/graph-based instead of ordered:

```swift
// Build dependency graph of locals
// Evaluate in topological order
// Cache nodes break cycles
```

Pros: More general solution
Cons: Bigger change to lowering

### C: Keep current behavior

Document that cache must be at call site. Update std_music.weft accordingly.

Pros: No code changes
Cons: Verbose, less intuitive for users

## Recommendation

Start with the targeted fix (Strategy in Implementation section). It's the smallest change that enables the desired syntax. If edge cases become problematic, consider moving to lazy evaluation (Alternative B).
