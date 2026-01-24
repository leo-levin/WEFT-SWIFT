```markdown
# WEFT Signal Model

## Core Concept: Signals

A **signal** is a function you can sample. Every signal has:

1. **Domain**: what coordinates it varies over
2. **Access**: for each coordinate, `free` (seekable) or `bound` (only "now")
3. **Hardware**: what devices it requires (camera, microphone, etc.)
4. **Stateful**: whether it uses cache

These are computed once during IR construction and stored on the signal.

## Free vs Bound

**Free**: You control the coordinate. "Give me the value at position 47."

**Bound**: The coordinate is given to you. You can only ask for "now."
```

camera.r(me.x + 10, me.y, ???) // fine, x and y are free
camera.r(me.x, me.y, me.t - 1) // INVALID: t is bound, can't seek into past

video_file.r(me.x, me.y, me.t - 1) // fine, all free, can seek

```

The reason a dimension is bound: it comes from hardware/world that only gives you the present.

## Composition

When signals combine, domain and access propagate:

```

foo.val = sin(camera.r + noise(me.x))

// inferred:
foo.val:
domain: [(x, free), (y, free), (t, bound)]
hardware: {camera}
stateful: false

```

Rules:
- **Domain**: union of all input domains
- **Access**: bound wins (if any input has bound t, output has bound t)
- **Hardware**: union of all input hardware
- **Stateful**: true if any input is stateful or expression contains cache

## Remap

Remap substitutes one coordinate for another:

```

img.r(me.x ~ audio.left)

```

Domain transformation:
- Remove the remapped dimension from source
- Add the replacement's domain
- Access comes from wherever the dimension originated

```

img.r: domain [(x, free), (y, free), (t, bound)]
audio.left: domain [(t, bound)]

img.r(me.x ~ audio.left):
domain [(y, free), (t, bound)]
// x removed, audio.left's t merged with existing t

```

## Cache

Cache stores history, triggered by a signal:

```

cache(value, history_size, tap_index, trigger)

```

- **value**: what to store
- **history_size**: how many values to keep
- **tap_index**: which historical value to output (can be a signal)
- **trigger**: when to store a new value

```

prev.r = cache(current.r, 2, 1, me.t) // previous frame

```

Domain transformation:
```

output.domain = value.domain ∪ tap.domain
output.stateful = true

````

Storage size = product(free dimension sizes) × history_size:
- `cache(camera.r, 60, ...)` → width × height × 60 (per-pixel history)
- `cache(mouse.x, 60, ...)` → 1 × 60 (scalar history)

## Backends

A backend declares:

```swift
protocol Backend {
    static var identifier: String { get }
    static var hardwareOwned: Set<IRHardware> { get }
    static var coordinateSpecs: [String: IRDimension] { get }
    static var primitiveSpecs: [String: PrimitiveSpec] { get }
    var iterates: Set<String> { get }
}
````

Visual backend:

```swift
identifier: "visual"
hardwareOwned: [.camera, .gpu]
coordinateSpecs: [
    "x": IRDimension(name: "x", access: .free),
    "y": IRDimension(name: "y", access: .free),
    "t": IRDimension(name: "t", access: .bound),
]
iterates: ["x", "y"]
```

Audio backend:

```swift
identifier: "audio"
hardwareOwned: [.microphone, .speaker]
coordinateSpecs: [
    "i": IRDimension(name: "i", access: .free),
    "t": IRDimension(name: "t", access: .free),  // derived from i
]
iterates: ["i"]
```

## Primitives

Primitives are backend-specific operations with domain signatures:

```swift
PrimitiveSpec(
    name: "camera",
    domainTransform: { _ in [
        IRDimension(name: "x", access: .free),
        IRDimension(name: "y", access: .free),
        IRDimension(name: "t", access: .bound)
    ]},
    hardwareRequired: [.camera],
    addsState: false
)
```

Domain-transparent builtins (sin, cos, +, -, etc.) just merge input domains.

## Sinks

Sinks define the iteration domain:

```
display: iterates (x, y), one frame at a time
play:    iterates (i), streaming samples
```

Compatibility rule:

```
signal.domain ⊆ sink.iteration_domain  → OK (constant over extra dims)
signal.domain ⊄ sink.iteration_domain  → ERROR
```

Examples:

```
display.r = me.t           // OK: (t) ⊆ (x, y), constant across pixels
display.r = camera.r       // OK: (x, y, t) matches iteration
play.val = sin(me.t * 440) // OK: (t) ⊆ (i)
play.val = sin(me.x)       // ERROR: (x) ⊄ (i), audio has no x
```

## Partitioning

Signals are routed to backends based on hardware:

```swift
func canHandle(_ signal: IRSignal) -> Bool {
    // Check hardware intersection
    if !signal.hardware.isEmpty {
        return !hardwareOwned.isDisjoint(with: signal.hardware)
    }
    // Pure signal: can go anywhere that provides its coordinates
    let neededCoords = Set(signal.domain.map { $0.name })
    let providedCoords = Set(coordinateSpecs.keys)
    return neededCoords.isSubset(of: providedCoords)
}
```

Pure signals (no hardware) can be duplicated to any backend that provides their coordinates.

Buffer boundaries appear where hardware requirements change:

```
red_at_mouse = camera.r(mouse.x, mouse.y)  // hardware: {camera}
audio_out.val = sin(me.t * 440) * red_at_mouse

// Visual computes red_at_mouse → buffer → Audio uses it
```

## Derived Properties

Not stored, computed from annotations:

```swift
extension IRSignal {
    var isPure: Bool {
        hardware.isEmpty && !stateful
    }

    var isExternal: Bool {
        !hardware.isEmpty
    }

    var boundDimensions: [String] {
        domain.filter { $0.access == .bound }.map { $0.name }
    }
}
```

## Adding a New Backend

One file:

```swift
public class MIDIBackend: Backend {
    public static let identifier = "midi"
    public static let hardwareOwned: Set<IRHardware> = [.custom("midi")]

    public static let coordinateSpecs: [String: IRDimension] = [
        "note": IRDimension(name: "note", access: .free),
        "t": IRDimension(name: "t", access: .bound),
    ]

    public static let primitiveSpecs: [String: PrimitiveSpec] = [
        "noteOn": PrimitiveSpec(
            name: "noteOn",
            domainTransform: { _ in [IRDimension(name: "t", access: .bound)] },
            hardwareRequired: [.custom("midi")],
            addsState: false
        )
    ]

    // ... compile and execute methods
}

// Register at app startup:
BackendRegistry.shared.register(MIDIBackend.self)
```

No edits to Partitioner, Coordinator, or IRAnnotations needed.

## IR Types

```swift
struct IRSignal {
    let name: String
    let expr: IRExpr
    let domain: [IRDimension]
    let hardware: Set<IRHardware>
    let stateful: Bool
}

struct IRDimension: Hashable {
    let name: String
    let access: IRAccess
}

enum IRAccess: Hashable {
    case free
    case bound
}

enum IRHardware: Hashable {
    case camera
    case microphone
    case speaker
    case gpu
    case custom(String)
}

indirect enum IRExpr {
    case literal(Double)
    case coord(String)
    case ref(String)
    case builtin(IRBuiltin, [IRExpr])
    case primitive(String, [IRExpr])
    case index(IRExpr, IRIndexer)
    case remap(IRExpr, String, IRExpr)
    case cache(value: IRExpr, size: Int, tap: IRExpr, trigger: IRExpr)
}
```

## Dev Mode Display

```
▼ display [x y t·]                    VISUAL external stateful
   r: lerp(0.5, diff.r + 0.5, step(...))
      (x, y, t·) cam
   g: ...
   b: ...

▶ thresh []                           pure
```

- `t·` = bound dimension
- `x y` = free dimensions
- `[]` = constant (empty domain)
- `cam` = camera hardware
- `stateful` = uses cache

```

```
