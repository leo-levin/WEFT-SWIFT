// IRInterpreter.swift - CPU-side expression evaluator for Loom visualization

import Foundation

/// Evaluates IRExpr trees at arbitrary coordinate values on the CPU.
/// Used by Loom to sample strand values at a grid of input coordinates.
public class IRInterpreter {
    public let program: IRProgram

    /// Track bundles currently being evaluated to detect cycles
    private var evaluating: Set<String> = []

    public init(program: IRProgram) {
        self.program = program
    }

    /// Evaluate an expression at given coordinate values.
    /// `coordinates` maps names like "x", "y", "t" (and "me.x", "me.y", "me.t") to values.
    public func evaluate(_ expr: IRExpr, coordinates: [String: Double]) -> Double {
        switch expr {
        case .num(let value):
            return value

        case .param(let name):
            return coordinates[name] ?? coordinates["me.\(name)"] ?? 0.0

        case .index(let bundle, let indexExpr):
            if bundle == "me" {
                if case .param(let field) = indexExpr {
                    return coordinates[field] ?? coordinates["me.\(field)"] ?? 0.0
                }
                if case .num(let idx) = indexExpr {
                    let fields = ["x", "y", "t", "w", "h"]
                    let i = Int(idx)
                    if i >= 0 && i < fields.count {
                        return coordinates[fields[i]] ?? coordinates["me.\(fields[i])"] ?? 0.0
                    }
                }
                return 0.0
            }

            // Resolve bundle strand reference
            if let targetBundle = program.bundles[bundle] {
                // Cycle detection
                let strandKey: String
                if case .param(let field) = indexExpr {
                    strandKey = "\(bundle).\(field)"
                } else if case .num(let idx) = indexExpr {
                    strandKey = "\(bundle).\(Int(idx))"
                } else {
                    strandKey = bundle
                }

                guard !evaluating.contains(strandKey) else {
                    return 0.0 // Break cycle
                }
                evaluating.insert(strandKey)
                defer { evaluating.remove(strandKey) }

                if case .num(let idx) = indexExpr {
                    let strandIdx = Int(idx)
                    if strandIdx >= 0 && strandIdx < targetBundle.strands.count {
                        return evaluate(targetBundle.strands[strandIdx].expr, coordinates: coordinates)
                    }
                } else if case .param(let field) = indexExpr {
                    if let strand = targetBundle.strands.first(where: { $0.name == field }) {
                        return evaluate(strand.expr, coordinates: coordinates)
                    }
                }
            }
            return 0.0

        case .binaryOp(let op, let left, let right):
            let l = evaluate(left, coordinates: coordinates)
            let r = evaluate(right, coordinates: coordinates)
            return applyBinaryOp(op, l, r)

        case .unaryOp(let op, let operand):
            let v = evaluate(operand, coordinates: coordinates)
            return applyUnaryOp(op, v)

        case .builtin(let name, let args):
            return evaluateBuiltin(name, args: args, coordinates: coordinates)

        case .call(let spindle, let args):
            guard let spindleDef = program.spindles[spindle],
                  !spindleDef.returns.isEmpty else { return 0.0 }
            let substitutions = IRTransformations.buildSpindleSubstitutions(
                spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(
                in: spindleDef.returns[0], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(
                in: inlined, substitutions: substitutions)
            return evaluate(inlined, coordinates: coordinates)

        case .extract(let callExpr, let index):
            guard case .call(let spindle, let args) = callExpr,
                  let spindleDef = program.spindles[spindle],
                  index < spindleDef.returns.count else { return 0.0 }
            let substitutions = IRTransformations.buildSpindleSubstitutions(
                spindleDef: spindleDef, args: args)
            var inlined = IRTransformations.substituteParams(
                in: spindleDef.returns[index], substitutions: substitutions)
            inlined = IRTransformations.substituteIndexRefs(
                in: inlined, substitutions: substitutions)
            return evaluate(inlined, coordinates: coordinates)

        case .remap(let base, let substitutions):
            let directExpr = IRTransformations.getDirectExpression(base, program: program)
            let remapped = IRTransformations.applyRemap(to: directExpr, substitutions: substitutions)
            return evaluate(remapped, coordinates: coordinates)

        case .cacheRead:
            return 0.0 // Cache history not available in Loom mode
        }
    }

    // MARK: - Operators

    private func applyBinaryOp(_ op: String, _ l: Double, _ r: Double) -> Double {
        switch op {
        case "+": return l + r
        case "-": return l - r
        case "*": return l * r
        case "/": return r != 0 ? l / r : 0.0
        case "%": return r != 0 ? l.truncatingRemainder(dividingBy: r) : 0.0
        case "^": return pow(l, r)
        case "<": return l < r ? 1.0 : 0.0
        case ">": return l > r ? 1.0 : 0.0
        case "<=": return l <= r ? 1.0 : 0.0
        case ">=": return l >= r ? 1.0 : 0.0
        case "==": return l == r ? 1.0 : 0.0
        case "!=": return l != r ? 1.0 : 0.0
        case "&&": return (l != 0 && r != 0) ? 1.0 : 0.0
        case "||": return (l != 0 || r != 0) ? 1.0 : 0.0
        default: return 0.0
        }
    }

    private func applyUnaryOp(_ op: String, _ v: Double) -> Double {
        switch op {
        case "-": return -v
        case "!": return v == 0 ? 1.0 : 0.0
        default: return 0.0
        }
    }

    // MARK: - Builtins

    private func evaluateBuiltin(_ name: String, args: [IRExpr], coordinates: [String: Double]) -> Double {
        // Cache: return value expression directly (no history buffer)
        if name == "cache" && !args.isEmpty {
            return evaluate(args[0], coordinates: coordinates)
        }

        // Select: short-circuit evaluation
        if name == "select" && args.count >= 2 {
            let idx = Int(evaluate(args[0], coordinates: coordinates))
            let branches = Array(args.dropFirst())
            let clampedIdx = max(0, min(idx, branches.count - 1))
            return evaluate(branches[clampedIdx], coordinates: coordinates)
        }

        let argValues = args.map { evaluate($0, coordinates: coordinates) }

        switch name {
        // Math - single arg
        case "sin": return sin(argValues[safe: 0] ?? 0)
        case "cos": return cos(argValues[safe: 0] ?? 0)
        case "tan": return tan(argValues[safe: 0] ?? 0)
        case "asin": return asin(argValues[safe: 0] ?? 0)
        case "acos": return acos(argValues[safe: 0] ?? 0)
        case "atan": return atan(argValues[safe: 0] ?? 0)
        case "abs": return abs(argValues[safe: 0] ?? 0)
        case "floor": return floor(argValues[safe: 0] ?? 0)
        case "ceil": return ceil(argValues[safe: 0] ?? 0)
        case "round": return (argValues[safe: 0] ?? 0).rounded()
        case "sqrt": return sqrt(max(0, argValues[safe: 0] ?? 0))
        case "exp": return exp(argValues[safe: 0] ?? 0)
        case "log": return log(max(1e-10, argValues[safe: 0] ?? 1e-10))
        case "log2": return log2(max(1e-10, argValues[safe: 0] ?? 1e-10))
        case "sign":
            let v = argValues[safe: 0] ?? 0
            if v > 0 { return 1.0 }
            if v < 0 { return -1.0 }
            return 0.0
        case "fract":
            let v = argValues[safe: 0] ?? 0
            return v - floor(v)

        // Math - two arg
        case "atan2": return atan2(argValues[safe: 0] ?? 0, argValues[safe: 1] ?? 0)
        case "pow": return pow(argValues[safe: 0] ?? 0, argValues[safe: 1] ?? 0)
        case "mod":
            let r = argValues[safe: 1] ?? 1
            return r != 0 ? (argValues[safe: 0] ?? 0).truncatingRemainder(dividingBy: r) : 0.0
        case "min": return min(argValues[safe: 0] ?? 0, argValues[safe: 1] ?? 0)
        case "max": return max(argValues[safe: 0] ?? 0, argValues[safe: 1] ?? 0)
        case "step":
            return (argValues[safe: 1] ?? 0) < (argValues[safe: 0] ?? 0) ? 0.0 : 1.0

        // Math - three arg
        case "clamp":
            return min(max(argValues[safe: 0] ?? 0, argValues[safe: 1] ?? 0), argValues[safe: 2] ?? 1)
        case "lerp", "mix":
            let a = argValues[safe: 0] ?? 0
            let b = argValues[safe: 1] ?? 0
            let t = argValues[safe: 2] ?? 0
            return a + (b - a) * t
        case "smoothstep":
            let edge0 = argValues[safe: 0] ?? 0
            let edge1 = argValues[safe: 1] ?? 1
            let x = argValues[safe: 2] ?? 0
            guard edge1 != edge0 else { return 0.0 }
            let t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
            return t * t * (3.0 - 2.0 * t)

        // Oscillator
        case "osc":
            let v = argValues[safe: 0] ?? 0
            return sin(v * 2.0 * .pi) * 0.5 + 0.5

        // Noise (hash-based, matches Metal/Audio implementation)
        case "noise":
            let x = argValues[safe: 0] ?? 0
            let y = argValues[safe: 1] ?? 0
            let dot = x * 12.9898 + y * 78.233
            let sinVal = sin(dot)
            let scaled = sinVal * 43758.5453
            return scaled - floor(scaled)

        // Resource builtins - synthetic coordinate-passthrough values for Loom
        case "camera", "texture", "load":
            if argValues.count >= 3 {
                let u = argValues[0]
                let v = argValues[1]
                let channel = Int(argValues[2])
                switch channel {
                case 0: return u
                case 1: return v
                case 2: return (u + v) / 2
                default: return 0
                }
            } else if argValues.count >= 2 {
                return argValues[0]
            }
            return 0.5

        // Hardware builtins - return 0 in Loom mode
        case "microphone", "sample", "text":
            return 0.0

        // Input builtins - return 0 in Loom mode
        case "mouse", "key":
            return 0.0

        default:
            return 0.0
        }
    }
}

// MARK: - Safe Array Access

private extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
