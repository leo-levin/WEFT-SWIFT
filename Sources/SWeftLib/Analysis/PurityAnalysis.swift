// PurityAnalysis.swift - Classify nodes as pure, stateful, or external

import Foundation

// MARK: - Purity Classification

public enum Purity: String, Hashable {
    case pure       // No state, can be recomputed anywhere
    case stateful   // Uses cache or self-reference with offset
    case external   // Depends on external input (camera, microphone, etc.)
}

// MARK: - Purity Analysis

public class PurityAnalysis {
    /// Registry for backend metadata
    private let registry: BackendRegistry

    /// Global stateful builtins (not backend-specific)
    private static let globalStatefulBuiltins: Set<String> = ["cache"]

    /// Map from bundle name to purity classification
    public private(set) var purity: [String: Purity] = [:]

    /// Bundles that have self-reference (reference themselves)
    public private(set) var selfReferencing: Set<String> = []

    /// Bundles that use cache
    public private(set) var usesCache: Set<String> = []

    public init(registry: BackendRegistry = .shared) {
        self.registry = registry
    }

    /// Combined external builtins from all backends
    private var externalBuiltins: Set<String> {
        registry.allExternalBuiltins
    }

    /// Combined stateful builtins from all backends plus global ones
    private var statefulBuiltins: Set<String> {
        registry.allStatefulBuiltins.union(Self.globalStatefulBuiltins)
    }

    /// Analyze purity for all bundles
    public func analyze(program: IRProgram) {
        purity = [:]
        selfReferencing = []
        usesCache = []

        // First pass: direct classification
        for (bundleName, bundle) in program.bundles {
            var bundlePurity: Purity = .pure

            for strand in bundle.strands {
                let exprPurity = classifyExpression(
                    expr: strand.expr,
                    bundleName: bundleName,
                    program: program
                )

                // Escalate: pure < stateful < external
                bundlePurity = max(bundlePurity, exprPurity)
            }

            purity[bundleName] = bundlePurity
        }

        // Second pass: propagate through dependencies
        propagatePurity(program: program)
    }

    /// Classify a single expression
    private func classifyExpression(
        expr: IRExpr,
        bundleName: String,
        program: IRProgram
    ) -> Purity {
        switch expr {
        case .num, .param:
            return .pure

        case .index(let bundle, let indexExpr):
            // Check for self-reference
            if bundle == bundleName {
                selfReferencing.insert(bundleName)
                return .stateful
            }
            // Recurse into index expression
            return classifyExpression(expr: indexExpr, bundleName: bundleName, program: program)

        case .binaryOp(_, let left, let right):
            return max(
                classifyExpression(expr: left, bundleName: bundleName, program: program),
                classifyExpression(expr: right, bundleName: bundleName, program: program)
            )

        case .unaryOp(_, let operand):
            return classifyExpression(expr: operand, bundleName: bundleName, program: program)

        case .call(_, let args):
            return args.map {
                classifyExpression(expr: $0, bundleName: bundleName, program: program)
            }.max() ?? .pure

        case .builtin(let name, let args):
            // Check builtin classification
            var result: Purity = .pure

            if externalBuiltins.contains(name) {
                result = .external
            } else if statefulBuiltins.contains(name) {
                result = .stateful
                usesCache.insert(bundleName)
            }

            // Also check arguments
            for arg in args {
                result = max(result, classifyExpression(expr: arg, bundleName: bundleName, program: program))
            }

            return result

        case .extract(let call, _):
            return classifyExpression(expr: call, bundleName: bundleName, program: program)

        case .remap(let base, let substitutions):
            var result = classifyExpression(expr: base, bundleName: bundleName, program: program)
            for (_, subExpr) in substitutions {
                result = max(result, classifyExpression(expr: subExpr, bundleName: bundleName, program: program))
            }
            return result
        }
    }

    /// Propagate purity through dependency chains
    /// If a bundle depends on stateful/external, it inherits that classification
    private func propagatePurity(program: IRProgram) {
        var changed = true

        while changed {
            changed = false

            for (bundleName, bundle) in program.bundles {
                let currentPurity = purity[bundleName] ?? .pure

                for strand in bundle.strands {
                    let refs = collectBundleReferences(expr: strand.expr)

                    for ref in refs {
                        if ref == bundleName { continue }  // Skip self-reference (already handled)
                        if ref == "me" { continue }        // Skip coordinate bundle

                        if let depPurity = purity[ref], depPurity > currentPurity {
                            purity[bundleName] = depPurity
                            changed = true
                        }
                    }
                }
            }
        }
    }

    /// Collect bundle references from expression
    private func collectBundleReferences(expr: IRExpr) -> Set<String> {
        switch expr {
        case .num, .param:
            return []

        case .index(let bundle, let indexExpr):
            var refs = collectBundleReferences(expr: indexExpr)
            refs.insert(bundle)
            return refs

        case .binaryOp(_, let left, let right):
            return collectBundleReferences(expr: left)
                .union(collectBundleReferences(expr: right))

        case .unaryOp(_, let operand):
            return collectBundleReferences(expr: operand)

        case .call(_, let args):
            return args.reduce(into: Set<String>()) {
                $0.formUnion(collectBundleReferences(expr: $1))
            }

        case .builtin(_, let args):
            return args.reduce(into: Set<String>()) {
                $0.formUnion(collectBundleReferences(expr: $1))
            }

        case .extract(let call, _):
            return collectBundleReferences(expr: call)

        case .remap(let base, let substitutions):
            var refs = collectBundleReferences(expr: base)
            for (_, subExpr) in substitutions {
                refs.formUnion(collectBundleReferences(expr: subExpr))
            }
            return refs
        }
    }

    /// Get bundles with a specific purity
    public func bundles(with purity: Purity) -> Set<String> {
        Set(self.purity.filter { $0.value == purity }.keys)
    }

    /// Check if a bundle is pure (can be duplicated across backends)
    public func isPure(_ bundleName: String) -> Bool {
        purity[bundleName] == .pure
    }
}

// MARK: - Purity Comparable

extension Purity: Comparable {
    public static func < (lhs: Purity, rhs: Purity) -> Bool {
        let order: [Purity] = [.pure, .stateful, .external]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}
