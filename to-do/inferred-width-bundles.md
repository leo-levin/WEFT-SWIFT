# Feature: Inferred-Width Bundle Assignment

## Current Behavior

Bundle declarations require explicit output specifiers:

```weft
// These work:
pattern[0,1,2,3] = [bd, sd, bd, sd]
pattern[a,b,c,d] = [bd, sd, bd, sd]
foo.val = 42

// This doesn't work:
pattern = [bd, sd, bd, sd]  // Error: expected . or [
```

## Desired Behavior

Allow bundle assignment without output specifiers when width can be inferred:

```weft
pattern = [bd, sd, bd, sd]  // Infer width=4, strands named 0,1,2,3
play = sample("kick.wav")   // Infer width=2, strands named 0,1 (or l,r?)
```

Access via numeric index:
```weft
x = pattern.0    // first element
x = pattern.3    // fourth element
x = pattern.(i)  // dynamic index
```

## Implementation

### Parser Changes (WeftParser.swift)

In `parseBundleDecl()`, add a third case:

```swift
var outputs: [OutputItem] = []

if match(.dot) {
    // Shorthand: name.strand = expr
    // ... existing code ...
} else if match(.leftBracket) {
    // Full: name[r, g, b] = expr
    // ... existing code ...
} else if match(.equal) {
    // Inferred: name = expr (width inferred, numeric indices)
    // Don't consume = here, fall through
    outputs = []  // Empty signals "infer from expr"
} else {
    throw ParseError.unexpectedToken(...)
}
```

### Lowering Changes (WeftLowering.swift)

In `registerBundle()` and `lowerBundleDecl()`, handle empty outputs:

```swift
if decl.outputs.isEmpty {
    // Infer width from expression
    let width = try inferWidth(decl.expr)
    outputs = (0..<width).map { .index($0) }
}
```

### AST Changes (WeftAST.swift)

`BundleDecl.outputs` can be empty - add comment documenting this means "infer width".

## Edge Cases

1. **Single value:** `x = 42` - should this create `x.0 = 42` or `x.val = 42`?
   - Proposal: Single values use `.0` for consistency with arrays

2. **Chained expressions:** `x = foo -> { .0 * 2 }` - infer from chain output width

3. **Resource builtins:** `cam = camera(me.x, me.y)` - infer width=3 from builtin spec

## Files to Modify

- `Sources/SWeftLib/Parser/WeftParser.swift` - Accept `name = expr` syntax
- `Sources/SWeftLib/Parser/WeftLowering.swift` - Infer width when outputs empty
- `Sources/SWeftLib/Parser/WeftAST.swift` - Document empty outputs behavior

## Testing

```weft
// Should all work:
nums = [1, 2, 3]
x = nums.0 + nums.1 + nums.2  // 6

snd = sample("test.wav")
play.l = snd.0
play.r = snd.1

pattern = [bd, sd, bd, sd]
hit = pattern.(step)
```
