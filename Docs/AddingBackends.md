# Adding a New Backend to WEFT

This guide explains how to implement a new backend for WEFT. Backends are "renderers" for the WEFT IR - they define what coordinates mean and how to execute expressions in their domain.

## Overview

WEFT's IR is **domain-agnostic**. It doesn't know about pixels, audio samples, or MIDI notes. That's what backends are for:

- **Visual Backend**: `me.x`, `me.y` are pixel coordinates (normalized 0-1)
- **Audio Backend**: `me.i` is sample index, `me.sampleRate` is sample rate
- **Your Backend**: You define what coordinates mean in your domain

## The Backend Protocol

Every backend must implement the `Backend` protocol:

```swift
public protocol Backend {
    // Identification
    static var identifier: String { get }            // e.g., "midi"

    // Capabilities
    static var ownedBuiltins: Set<String> { get }    // Builtins this backend owns
    static var externalBuiltins: Set<String> { get } // Hardware I/O builtins
    static var statefulBuiltins: Set<String> { get } // Stateful builtins (cache)
    static var bindings: [BackendBinding] { get }    // Input/output bindings
    static var coordinateFields: [String] { get }    // Available me.* fields

    // Execution
    func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit
    func execute(unit: CompiledUnit, inputs: [...], outputs: [...], time: Double)
}
```

## Step-by-Step Guide

### Step 1: Define Your Backend Class

Create a new file `Sources/SWeftLib/Backends/YourBackend/YourBackend.swift`:

```swift
import Foundation

// MARK: - Your Compiled Unit

public class YourCompiledUnit: CompiledUnit {
    public let swatchId: UUID
    // Add your compiled representation here
    // For CPU: closures or AST
    // For GPU: compiled shader/pipeline

    public init(swatchId: UUID) {
        self.swatchId = swatchId
    }
}

// MARK: - Your Backend

public class YourBackend: Backend {
    public static let identifier = "yourDomain"

    // What builtins make a bundle belong to your backend?
    public static let ownedBuiltins: Set<String> = ["yourInput"]

    // Which of those are hardware I/O?
    public static let externalBuiltins: Set<String> = ["yourInput"]

    // Stateful builtins (usually just cache)
    public static let statefulBuiltins: Set<String> = ["cache"]

    // What coordinates are available in your domain?
    public static let coordinateFields = ["yourCoord1", "yourCoord2", "t"]

    // Input and output bindings
    public static let bindings: [BackendBinding] = [
        .input(InputBinding(builtinName: "yourInput")),
        .output(OutputBinding(bundleName: "yourOutput", kernelName: "yourCallback"))
    ]

    public init() {}

    public func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit {
        // Generate executable code from IR
        // See Step 3 for details
    }

    public func execute(
        unit: CompiledUnit,
        inputs: [String: any Buffer],
        outputs: [String: any Buffer],
        time: Double
    ) {
        // Run the compiled code
        // See Step 4 for details
    }
}
```

### Step 2: Implement Code Generation

Create `Sources/SWeftLib/Backends/YourBackend/YourCodeGen.swift`:

```swift
import Foundation

public class YourCodeGen {
    private let program: IRProgram
    private let swatch: Swatch

    public init(program: IRProgram, swatch: Swatch) {
        self.program = program
        self.swatch = swatch
    }

    /// Generate executable code (closure, shader, etc.)
    public func generate() throws -> YourExecutableType {
        // Find the output bundle
        guard let outputBundle = program.bundles["yourOutput"] else {
            throw BackendError.missingResource("yourOutput bundle not found")
        }

        // Generate code for each strand expression
        for strand in outputBundle.strands {
            let code = try generateExpression(strand.expr)
            // ... use the generated code
        }

        return yourExecutable
    }

    /// Generate code for an IR expression
    private func generateExpression(_ expr: IRExpr) throws -> String {
        switch expr {
        case .num(let value):
            return "\(value)"

        case .param(let name):
            // Coordinate access: map to your domain's coordinates
            return name

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                // Access coordinate: me.yourCoord1, me.yourCoord2, etc.
                if case .param(let field) = indexExpr {
                    return mapCoordinate(field)
                }
            }
            // Access another bundle's strand
            return try resolveIndex(bundle, indexExpr)

        case .binaryOp(let op, let left, let right):
            let leftCode = try generateExpression(left)
            let rightCode = try generateExpression(right)
            return generateBinaryOp(op, leftCode, rightCode)

        case .unaryOp(let op, let operand):
            let operandCode = try generateExpression(operand)
            return generateUnaryOp(op, operandCode)

        case .builtin(let name, let args):
            return try generateBuiltin(name, args)

        case .call(let spindle, let args):
            // Inline spindle call using IRTransformations
            let substitutions = IRTransformations.buildSpindleSubstitutions(
                spindleDef: program.spindles[spindle]!,
                args: args
            )
            let inlined = IRTransformations.substituteParams(
                in: program.spindles[spindle]!.returns[0],
                substitutions: substitutions
            )
            return try generateExpression(inlined)

        // ... handle other cases
        }
    }

    /// Map coordinate field to your domain
    private func mapCoordinate(_ field: String) -> String {
        switch field {
        case "yourCoord1": return "coord1"
        case "yourCoord2": return "coord2"
        case "t": return "time"
        default: return "0"
        }
    }

    /// Generate builtin function calls
    private func generateBuiltin(_ name: String, _ args: [IRExpr]) throws -> String {
        // Use SharedBuiltins for reference
        let argCodes = try args.map { try generateExpression($0) }

        switch name {
        // Math builtins - implement for your target language
        case "sin": return "sin(\(argCodes[0]))"
        case "cos": return "cos(\(argCodes[0]))"
        // ... all builtins from SharedBuiltins.all

        // Your domain-specific builtins
        case "yourInput":
            return generateYourInput(args)

        default:
            throw BackendError.unsupportedExpression("Unknown builtin: \(name)")
        }
    }
}
```

### Step 3: Implement Compilation

In your `compile()` method:

```swift
public func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit {
    let codegen = YourCodeGen(program: ir, swatch: swatch)
    let executable = try codegen.generate()

    return YourCompiledUnit(
        swatchId: swatch.id,
        executable: executable
    )
}
```

### Step 4: Implement Execution

In your `execute()` method:

```swift
public func execute(
    unit: CompiledUnit,
    inputs: [String: any Buffer],
    outputs: [String: any Buffer],
    time: Double
) {
    guard let yourUnit = unit as? YourCompiledUnit else { return }

    // Run your executable
    // Read from inputs (cross-domain data)
    // Write to outputs (for other backends to consume)
}
```

### Step 5: Register Your Backend

In your app's initialization:

```swift
BackendRegistry.shared.register(YourBackend.self)
```

## How Partitioning Works

The `Partitioner` assigns bundles to backends based on:

1. **Output sinks**: Bundles named `display` go to visual, `play` goes to audio
2. **Owned builtins**: A bundle using `camera()` belongs to visual
3. **Dependencies**: Pure bundles are duplicated as needed

Your backend will receive swatches containing bundles that:
- Use your owned builtins, OR
- Are sinks for your output binding

## Example: Skeleton MIDI Backend

```swift
public class MIDIBackend: Backend {
    public static let identifier = "midi"
    public static let ownedBuiltins: Set<String> = ["midiNote", "midiCC", "midiPitchBend"]
    public static let externalBuiltins: Set<String> = ["midiNote"]
    public static let statefulBuiltins: Set<String> = ["cache"]
    public static let coordinateFields = ["note", "velocity", "channel", "t"]

    public static let bindings: [BackendBinding] = [
        .input(InputBinding(builtinName: "midiNote")),
        .output(OutputBinding(bundleName: "send", kernelName: "midiCallback"))
    ]

    public init() {}

    public func compile(swatch: Swatch, ir: IRProgram) throws -> CompiledUnit {
        // Parse IR, generate MIDI message generation code
        let codegen = MIDICodeGen(program: ir, swatch: swatch)
        let messageGenerator = try codegen.generate()

        return MIDICompiledUnit(swatchId: swatch.id, generator: messageGenerator)
    }

    public func execute(
        unit: CompiledUnit,
        inputs: [String: any Buffer],
        outputs: [String: any Buffer],
        time: Double
    ) {
        guard let midiUnit = unit as? MIDICompiledUnit else { return }

        // Generate and send MIDI messages
        let messages = midiUnit.generator(time)
        sendMIDIMessages(messages)
    }
}
```

## Testing Your Backend

Use `BackendParityTests` as a template:

```swift
func testYourBackendMathParity() throws {
    let expr = IRExpr.builtin(name: "sin", args: [.num(0.5)])
    let program = createYourProgram(expression: expr)

    let result = try evaluateYourBackend(program: program)
    XCTAssertEqual(result, sin(0.5), accuracy: 0.0001)
}
```

## Checklist

- [ ] Backend class implementing `Backend` protocol
- [ ] CompiledUnit class for your executable representation
- [ ] CodeGen class for IR -> executable translation
- [ ] All builtins from `SharedBuiltins.domainAgnostic` implemented
- [ ] Domain-specific builtins implemented
- [ ] Coordinate fields mapped to your domain
- [ ] Backend registered with `BackendRegistry`
- [ ] Parity tests passing

## Best Practices

1. **Use IRTransformations**: Don't reimplement spindle inlining - use the shared utilities
2. **Validate with SharedBuiltins**: Use `SharedBuiltins.validateBackend()` to check coverage
3. **Test domain-agnostic parity**: Same WEFT code should produce equivalent results
4. **Keep it minimal**: Only implement what's needed for your domain
