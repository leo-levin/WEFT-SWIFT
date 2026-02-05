// WeftDesugar.swift - AST-to-AST desugaring pass
//
// Transforms $name(expr) tag expressions into synthetic bundles.
// Example:
//   bar[x] = foo.x * $speed(12) + $speed
// Desugars to:
//   $speed[0] = 12
//   bar[x] = foo.x * $speed.0 + $speed.0

import Foundation

public class WeftDesugar {

    public init() {}

    /// Desugar a WeftProgram, replacing tag expressions with synthetic bundles.
    public func desugar(_ program: WeftProgram) -> WeftProgram {
        // Phase 1: Collect all tag definitions from all statements
        var tagDefs: [String: Expr] = [:]  // $name -> expr (first definition wins)
        for stmt in program.statements {
            collectTags(stmt, into: &tagDefs)
        }

        // If no tags found, return program unchanged
        if tagDefs.isEmpty {
            return program
        }

        // Phase 2: Emit synthetic bundles for each tag
        var syntheticBundles: [Statement] = []
        for (name, expr) in tagDefs.sorted(by: { $0.key < $1.key }) {
            let rewrittenExpr = rewriteExpr(expr, tags: tagDefs)
            let bundle = BundleDecl(
                name: name,
                outputs: [.index(0)],
                expr: rewrittenExpr
            )
            syntheticBundles.append(.bundleDecl(bundle))
        }

        // Phase 3: Rewrite all original statements
        let rewrittenStatements = program.statements.map { rewriteStatement($0, tags: tagDefs) }

        return WeftProgram(statements: syntheticBundles + rewrittenStatements)
    }

    // MARK: - Phase 1: Collection

    private func collectTags(_ stmt: Statement, into tagDefs: inout [String: Expr]) {
        switch stmt {
        case .bundleDecl(let decl):
            collectTagsFromExpr(decl.expr, into: &tagDefs)
        case .spindleDef(let def):
            for bodyStmt in def.body {
                switch bodyStmt {
                case .bundleDecl(let decl):
                    collectTagsFromExpr(decl.expr, into: &tagDefs)
                case .returnAssign(let ret):
                    collectTagsFromExpr(ret.expr, into: &tagDefs)
                }
            }
        }
    }

    private func collectTagsFromExpr(_ expr: Expr, into tagDefs: inout [String: Expr]) {
        switch expr {
        case .tagExpr(let tag):
            // First definition wins
            if tagDefs[tag.name] == nil {
                tagDefs[tag.name] = tag.expr
            }
            // Also collect from the inner expression
            collectTagsFromExpr(tag.expr, into: &tagDefs)

        case .binaryOp(let op):
            collectTagsFromExpr(op.left, into: &tagDefs)
            collectTagsFromExpr(op.right, into: &tagDefs)

        case .unaryOp(let op):
            collectTagsFromExpr(op.operand, into: &tagDefs)

        case .spindleCall(let call):
            for arg in call.args {
                collectTagsFromExpr(arg, into: &tagDefs)
            }

        case .callExtract(let extract):
            collectTagsFromExpr(extract.call, into: &tagDefs)

        case .remapExpr(let remap):
            collectTagsFromExpr(remap.base, into: &tagDefs)
            for r in remap.remappings {
                collectTagsFromExpr(r.expr, into: &tagDefs)
            }

        case .bundleLit(let elements):
            for el in elements {
                collectTagsFromExpr(el, into: &tagDefs)
            }

        case .chainExpr(let chain):
            collectTagsFromExpr(chain.base, into: &tagDefs)
            for pattern in chain.patterns {
                for output in pattern.outputs {
                    collectTagsFromExpr(output.value, into: &tagDefs)
                }
            }

        case .strandAccess(let access):
            if case .expr(let inner) = access.accessor {
                collectTagsFromExpr(inner, into: &tagDefs)
            }
            if case .bundleLit(let elements) = access.bundle {
                for el in elements {
                    collectTagsFromExpr(el, into: &tagDefs)
                }
            }

        case .number, .string, .identifier, .rangeExpr:
            break
        }
    }

    // MARK: - Phase 3: Rewriting

    private func rewriteStatement(_ stmt: Statement, tags: [String: Expr]) -> Statement {
        switch stmt {
        case .bundleDecl(let decl):
            return .bundleDecl(BundleDecl(
                name: decl.name,
                outputs: decl.outputs,
                expr: rewriteExpr(decl.expr, tags: tags)
            ))
        case .spindleDef(let def):
            let newBody = def.body.map { bodyStmt -> BodyStatement in
                switch bodyStmt {
                case .bundleDecl(let decl):
                    return .bundleDecl(BundleDecl(
                        name: decl.name,
                        outputs: decl.outputs,
                        expr: rewriteExpr(decl.expr, tags: tags)
                    ))
                case .returnAssign(let ret):
                    return .returnAssign(ReturnAssign(
                        index: ret.index,
                        expr: rewriteExpr(ret.expr, tags: tags)
                    ))
                }
            }
            return .spindleDef(SpindleDef(name: def.name, params: def.params, body: newBody))
        }
    }

    private func rewriteExpr(_ expr: Expr, tags: [String: Expr]) -> Expr {
        switch expr {
        case .tagExpr(let tag):
            // Replace $name(expr) with $name.0
            return .strandAccess(StrandAccess(bundle: .named(tag.name), accessor: .index(0)))

        case .identifier(let name) where name.hasPrefix("$") && tags[name] != nil:
            // Replace bare $name with $name.0
            return .strandAccess(StrandAccess(bundle: .named(name), accessor: .index(0)))

        case .binaryOp(let op):
            return .binaryOp(BinaryOp(
                left: rewriteExpr(op.left, tags: tags),
                op: op.op,
                right: rewriteExpr(op.right, tags: tags)
            ))

        case .unaryOp(let op):
            return .unaryOp(UnaryOp(
                op: op.op,
                operand: rewriteExpr(op.operand, tags: tags)
            ))

        case .spindleCall(let call):
            return .spindleCall(SpindleCall(
                name: call.name,
                args: call.args.map { rewriteExpr($0, tags: tags) }
            ))

        case .callExtract(let extract):
            return .callExtract(CallExtract(
                call: rewriteExpr(extract.call, tags: tags),
                index: extract.index
            ))

        case .remapExpr(let remap):
            return .remapExpr(RemapExpr(
                base: rewriteExpr(remap.base, tags: tags),
                remappings: remap.remappings.map { r in
                    RemapArg(domain: r.domain, expr: rewriteExpr(r.expr, tags: tags))
                }
            ))

        case .bundleLit(let elements):
            return .bundleLit(elements.map { rewriteExpr($0, tags: tags) })

        case .chainExpr(let chain):
            return .chainExpr(ChainExpr(
                base: rewriteExpr(chain.base, tags: tags),
                patterns: chain.patterns.map { pattern in
                    PatternBlock(outputs: pattern.outputs.map { output in
                        PatternOutput(value: rewriteExpr(output.value, tags: tags))
                    })
                }
            ))

        case .strandAccess(let access):
            var newBundle = access.bundle
            if case .bundleLit(let elements) = access.bundle {
                newBundle = .bundleLit(elements.map { rewriteExpr($0, tags: tags) })
            }
            var newAccessor = access.accessor
            if case .expr(let inner) = access.accessor {
                newAccessor = .expr(rewriteExpr(inner, tags: tags))
            }
            return .strandAccess(StrandAccess(bundle: newBundle, accessor: newAccessor))

        case .number, .string, .identifier, .rangeExpr:
            return expr
        }
    }
}
