// OwnershipAnalysis.swift - Determine backend ownership from builtins

import Foundation

// MARK: - Backend Domain

public enum BackendDomain: String, Hashable, CaseIterable {
    case visual
    case audio
    case none  // Pure computation, no domain-specific builtins
}

// MARK: - Output Sinks

public enum OutputSink: String, Hashable {
    case display  // Visual output
    case play     // Audio output
}

// MARK: - Ownership Analysis

public class OwnershipAnalysis {
    /// Builtins that belong to visual domain
    public static let visualBuiltins: Set<String> = ["camera", "texture", "load"]

    /// Builtins that belong to audio domain
    public static let audioBuiltins: Set<String> = ["microphone"]

    /// Output sink bundle names
    public static let outputSinks: [String: OutputSink] = [
        "display": .display,
        "play": .play
    ]

    /// Map from bundle name to its backend domain
    public private(set) var ownership: [String: BackendDomain] = [:]

    /// Map from bundle name to output sink (if it is one)
    public private(set) var sinks: [String: OutputSink] = [:]

    public init() {}

    /// Analyze backend ownership for all bundles
    public func analyze(program: IRProgram) {
        ownership = [:]
        sinks = [:]

        // First pass: determine direct ownership from builtins
        for (bundleName, bundle) in program.bundles {
            // Check if this is an output sink
            if let sink = Self.outputSinks[bundleName] {
                sinks[bundleName] = sink
                ownership[bundleName] = sink == .display ? .visual : .audio
                continue
            }

            // Analyze expressions for domain-specific builtins
            var domain: BackendDomain = .none
            for strand in bundle.strands {
                let builtins = strand.expr.allBuiltins()

                if !builtins.isDisjoint(with: Self.visualBuiltins) {
                    domain = .visual
                }
                if !builtins.isDisjoint(with: Self.audioBuiltins) {
                    if domain == .visual {
                        // Cross-domain - will be handled by coordinator
                        // For now, mark as visual (display takes precedence for rendering)
                    } else {
                        domain = .audio
                    }
                }
            }

            ownership[bundleName] = domain
        }

        // Second pass: propagate ownership from dependencies
        // Bundles inherit domain from their stateful dependencies
        propagateOwnership(program: program)
    }

    /// Propagate ownership through dependency chains
    private func propagateOwnership(program: IRProgram) {
        var changed = true

        while changed {
            changed = false

            for (bundleName, bundle) in program.bundles {
                guard ownership[bundleName] == .none else { continue }

                // Check if any dependency has a domain
                for strand in bundle.strands {
                    let refs = collectBundleReferences(expr: strand.expr)

                    for ref in refs {
                        if let depDomain = ownership[ref], depDomain != .none {
                            // Inherit domain from dependency
                            ownership[bundleName] = depDomain
                            changed = true
                            break
                        }
                    }
                    if ownership[bundleName] != .none {
                        break
                    }
                }
            }
        }
    }

    /// Collect bundle references from an expression (just names, not strands)
    private func collectBundleReferences(expr: IRExpr) -> Set<String> {
        switch expr {
        case .num, .param:
            return []

        case .index(let bundle, let indexExpr):
            var refs = collectBundleReferences(expr: indexExpr)
            if bundle != "me" {
                refs.insert(bundle)
            }
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

        case .texture(_, let u, let v, _):
            return collectBundleReferences(expr: u)
                .union(collectBundleReferences(expr: v))

        case .camera(let u, let v, _):
            return collectBundleReferences(expr: u)
                .union(collectBundleReferences(expr: v))

        case .microphone(let offset, _):
            return collectBundleReferences(expr: offset)
        }
    }

    /// Get bundles owned by a specific backend
    public func bundles(for domain: BackendDomain) -> Set<String> {
        Set(ownership.filter { $0.value == domain }.keys)
    }

    /// Get the output sink bundles
    public func outputBundles() -> [String: OutputSink] {
        sinks
    }
}
