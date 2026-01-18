// OwnershipAnalysis.swift - Determine backend ownership from builtins

import Foundation

// MARK: - Backend Domain

public enum BackendDomain: String, Hashable, CaseIterable {
    case visual
    case audio
    case none  // Pure computation, no domain-specific builtins
}

// MARK: - Ownership Analysis

public class OwnershipAnalysis {
    /// Registry for backend metadata
    private let registry: BackendRegistry

    /// Map from bundle name to its backend domain
    public private(set) var ownership: [String: BackendDomain] = [:]

    /// Map from bundle name to backend identifier (for sink bundles only)
    /// e.g., "display" -> "visual", "play" -> "audio"
    public private(set) var sinks: [String: String] = [:]

    public init(registry: BackendRegistry = .shared) {
        self.registry = registry
    }

    /// Analyze backend ownership for all bundles
    public func analyze(program: IRProgram) {
        ownership = [:]
        sinks = [:]

        // Get owned builtins from registry
        let ownedBuiltins = registry.allOwnedBuiltins
        let outputBindings = registry.allOutputBindings

        // First pass: determine direct ownership from builtins
        for (bundleName, bundle) in program.bundles {
            // Check if this is an output sink (via registry lookup)
            if let (backendId, _) = outputBindings[bundleName] {
                sinks[bundleName] = backendId
                ownership[bundleName] = backendIdToDomain(backendId)
                continue
            }

            // Analyze expressions for domain-specific builtins
            var domain: BackendDomain = .none
            for strand in bundle.strands {
                let builtins = strand.expr.allBuiltins()

                for builtin in builtins {
                    if let backendId = ownedBuiltins[builtin] {
                        let builtinDomain = backendIdToDomain(backendId)
                        if domain == .none {
                            domain = builtinDomain
                        } else if domain != builtinDomain {
                            // Cross-domain - visual takes precedence for rendering
                            domain = .visual
                        }
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
                guard ownership[bundleName] == BackendDomain.none else { continue }

                // Check if any dependency has a domain
                for strand in bundle.strands {
                    let refs = collectBundleReferences(expr: strand.expr)

                    for ref in refs {
                        if let depDomain = ownership[ref], depDomain != BackendDomain.none {
                            // Inherit domain from dependency
                            ownership[bundleName] = depDomain
                            changed = true
                            break
                        }
                    }
                    if ownership[bundleName] != BackendDomain.none {
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
        }
    }

    /// Get bundles owned by a specific backend
    public func bundles(for domain: BackendDomain) -> Set<String> {
        Set(ownership.filter { $0.value == domain }.keys)
    }

    /// Get the output sink bundles (bundleName -> backendId)
    public func outputBundles() -> [String: String] {
        sinks
    }

    /// Convert backend identifier to domain enum
    private func backendIdToDomain(_ backendId: String) -> BackendDomain {
        BackendDomain(rawValue: backendId) ?? .none
    }
}
