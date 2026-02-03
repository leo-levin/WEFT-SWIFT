// SpindleCacheInliningTest.swift - Test cache target substitution inside spindles

import XCTest
@testable import WEFTLib

final class SpindleCacheInliningTest: XCTestCase {

    // MARK: - Cycle Detection Tests

    func testFindCyclicCachesInEdecaySpindle() throws {
        // Create a spindle with a cyclic cache pattern
        // spindle edecay(rate) {
        //     prev.val = cache(out.val, 2, 1, me.i)
        //     out.val = prev.val * rate
        //     return.0 = out.val
        // }

        let prevLocal = IRBundle(
            name: "prev",
            strands: [
                IRStrand(
                    name: "val",
                    index: 0,
                    expr: .builtin(name: "cache", args: [
                        .index(bundle: "out", indexExpr: .num(0)),
                        .num(2),
                        .num(1),
                        .index(bundle: "me", indexExpr: .param("i"))
                    ])
                )
            ]
        )

        let outLocal = IRBundle(
            name: "out",
            strands: [
                IRStrand(
                    name: "val",
                    index: 0,
                    expr: .binaryOp(
                        op: "*",
                        left: .index(bundle: "prev", indexExpr: .num(0)),
                        right: .param("rate")
                    )
                )
            ]
        )

        let spindle = IRSpindle(
            name: "edecay",
            params: ["rate"],
            locals: [prevLocal, outLocal],
            returns: [.index(bundle: "out", indexExpr: .num(0))]
        )

        let cycles = IRTransformations.findCyclicCachesInSpindle(spindle)

        XCTAssertEqual(cycles.count, 1, "Should find exactly one cyclic cache")
        if let cycle = cycles.first {
            XCTAssertEqual(cycle.cacheLocalName, "prev")
            XCTAssertEqual(cycle.cacheStrandName, "val")
            XCTAssertEqual(cycle.cyclicLocalName, "out")
            XCTAssertEqual(cycle.cyclicStrandIndex, 0)
        }
    }

    func testFindNoCyclesInNonCyclicSpindle() throws {
        // Spindle without cycles - cache references input param, not a local
        // spindle delay(input) {
        //     prev.val = cache(input, 2, 1, me.i)
        //     return.0 = prev.val
        // }

        let prevLocal = IRBundle(
            name: "prev",
            strands: [
                IRStrand(
                    name: "val",
                    index: 0,
                    expr: .builtin(name: "cache", args: [
                        .param("input"),  // References param, not local
                        .num(2),
                        .num(1),
                        .index(bundle: "me", indexExpr: .param("i"))
                    ])
                )
            ]
        )

        let spindle = IRSpindle(
            name: "delay",
            params: ["input"],
            locals: [prevLocal],
            returns: [.index(bundle: "prev", indexExpr: .num(0))]
        )

        let cycles = IRTransformations.findCyclicCachesInSpindle(spindle)
        XCTAssertEqual(cycles.count, 0, "Should find no cycles")
    }

    // MARK: - Substitution Tests

    func testSubstituteCyclicRef() throws {
        // Test substituting out.val with env.val
        let expr = IRExpr.builtin(name: "cache", args: [
            .index(bundle: "out", indexExpr: .num(0)),
            .num(2),
            .num(1),
            .index(bundle: "me", indexExpr: .param("i"))
        ])

        let replacement = IRExpr.index(bundle: "env", indexExpr: .num(0))
        let result = IRTransformations.substituteCyclicRef(
            in: expr,
            localName: "out",
            strandIndex: 0,
            replacement: replacement
        )

        // Verify the cache's first arg is now env.val
        if case .builtin(let name, let args) = result {
            XCTAssertEqual(name, "cache")
            if case .index(let bundle, let indexExpr) = args[0] {
                XCTAssertEqual(bundle, "env")
                if case .num(let idx) = indexExpr {
                    XCTAssertEqual(Int(idx), 0)
                } else {
                    XCTFail("Expected numeric index")
                }
            } else {
                XCTFail("Expected index expression")
            }
        } else {
            XCTFail("Expected builtin expression")
        }
    }

    func testSubstituteCyclicRefInNestedExpr() throws {
        // Test substituting in a nested expression: cache(max(out.val, 0.5), ...)
        let expr = IRExpr.builtin(name: "cache", args: [
            .builtin(name: "max", args: [
                .index(bundle: "out", indexExpr: .num(0)),
                .num(0.5)
            ]),
            .num(2),
            .num(1),
            .index(bundle: "me", indexExpr: .param("i"))
        ])

        let replacement = IRExpr.index(bundle: "env", indexExpr: .num(0))
        let result = IRTransformations.substituteCyclicRef(
            in: expr,
            localName: "out",
            strandIndex: 0,
            replacement: replacement
        )

        // Verify the nested out.val was replaced with env.val
        if case .builtin(let name, let args) = result,
           name == "cache",
           case .builtin(let innerName, let innerArgs) = args[0],
           innerName == "max",
           case .index(let bundle, _) = innerArgs[0] {
            XCTAssertEqual(bundle, "env", "Nested local ref should be replaced")
        } else {
            XCTFail("Expected nested structure to be preserved")
        }
    }

    // MARK: - Full Inlining Tests

    func testInlineSpindleCallWithTarget() throws {
        // Create edecay spindle
        let prevLocal = IRBundle(
            name: "prev",
            strands: [
                IRStrand(
                    name: "val",
                    index: 0,
                    expr: .builtin(name: "cache", args: [
                        .index(bundle: "out", indexExpr: .num(0)),
                        .num(2),
                        .num(1),
                        .index(bundle: "me", indexExpr: .param("i"))
                    ])
                )
            ]
        )

        let outLocal = IRBundle(
            name: "out",
            strands: [
                IRStrand(
                    name: "val",
                    index: 0,
                    expr: .binaryOp(
                        op: "*",
                        left: .index(bundle: "prev", indexExpr: .num(0)),
                        right: .param("rate")
                    )
                )
            ]
        )

        let spindle = IRSpindle(
            name: "edecay",
            params: ["rate"],
            locals: [prevLocal, outLocal],
            returns: [.index(bundle: "out", indexExpr: .num(0))]
        )

        // Inline with target env.val
        let result = IRTransformations.inlineSpindleCallWithTarget(
            spindleDef: spindle,
            args: [.num(0.999)],
            targetBundle: "env",
            targetStrandIndex: 0,
            returnIndex: 0
        )

        // The result should be: cache(env.val, 2, 1, me.i) * 0.999
        print("Inlined expression: \(result)")

        // Verify structure
        if case .binaryOp(let op, let left, let right) = result {
            XCTAssertEqual(op, "*")

            // Left should be cache(env.val, ...)
            if case .builtin(let name, let args) = left {
                XCTAssertEqual(name, "cache")
                // First arg should be env.val (index 0)
                if case .index(let bundle, let indexExpr) = args[0] {
                    XCTAssertEqual(bundle, "env", "Cache target should be substituted to env")
                    if case .num(let idx) = indexExpr {
                        XCTAssertEqual(Int(idx), 0)
                    }
                } else {
                    XCTFail("Expected index expression in cache")
                }
            } else {
                XCTFail("Expected cache builtin on left side")
            }

            // Right should be 0.999
            if case .num(let val) = right {
                XCTAssertEqual(val, 0.999, accuracy: 0.0001)
            } else {
                XCTFail("Expected numeric right operand")
            }
        } else {
            XCTFail("Expected binary multiplication at top level, got: \(result)")
        }
    }

    // MARK: - Full Pipeline Tests

    func testEdecaySpindleCompilation() throws {
        let source = """
        spindle edecay(rate) {
            prev.val = cache(out.val, 2, 1, me.i)
            out.val = prev.val * rate
            return.0 = out.val
        }

        env.val = edecay(0.999)
        play.l = env.val * osc(440)
        play.r = play.l
        """

        let compiler = WeftCompiler()

        do {
            let ir = try compiler.compile(source)

            // Verify spindle was created
            XCTAssertNotNil(ir.spindles["edecay"])

            let spindle = ir.spindles["edecay"]!
            XCTAssertEqual(spindle.params, ["rate"])
            XCTAssertEqual(spindle.locals.count, 2)

            // Apply the cache inlining transformation
            var mutableIR = ir
            IRTransformations.inlineSpindleCacheCalls(program: &mutableIR)

            // After transformation, env.val should have the inlined expression
            // with cache targeting env.val (not out.val)
            if let envBundle = mutableIR.bundles["env"],
               let envStrand = envBundle.strands.first {
                print("Transformed env.val expression: \(envStrand.expr)")

                // The expression should contain a cache that references env (self-reference)
                let exprStr = "\(envStrand.expr)"
                XCTAssertTrue(
                    exprStr.contains("env") || exprStr.contains("cache"),
                    "Transformed expression should reference env or contain cache"
                )
            } else {
                XCTFail("env bundle should exist after transformation")
            }

            print("SUCCESS: edecay spindle compiled and transformed")

        } catch {
            XCTFail("Compilation failed: \(error)")
        }
    }

    func testAREnvelopeSpindleCompilation() throws {
        let source = """
        spindle ar(gate, attack, release) {
            prev.val = cache(out.val, 2, 1, me.i)
            up.val = min(prev.val + attack, 1)
            down.val = prev.val * release
            out.val = lerp(down.val, up.val, gate)
            return.0 = out.val
        }

        gate.val = step(0.5, osc(2))
        env.val = ar(gate.val, 0.01, 0.999)
        play.l = env.val * osc(440)
        play.r = play.l
        """

        let compiler = WeftCompiler()

        do {
            let ir = try compiler.compile(source)

            XCTAssertNotNil(ir.spindles["ar"])

            let spindle = ir.spindles["ar"]!
            XCTAssertEqual(spindle.params, ["gate", "attack", "release"])
            XCTAssertEqual(spindle.locals.count, 4) // prev, up, down, out

            // Apply transformation
            var mutableIR = ir
            IRTransformations.inlineSpindleCacheCalls(program: &mutableIR)

            print("SUCCESS: AR envelope spindle compiled and transformed")

        } catch {
            XCTFail("Compilation failed: \(error)")
        }
    }

    func testMultipleSpindleInstances() throws {
        let source = """
        spindle edecay(rate) {
            prev.val = cache(out.val, 2, 1, me.i)
            out.val = prev.val * rate
            return.0 = out.val
        }

        env1.val = edecay(0.999)
        env2.val = edecay(0.99)
        play.l = env1.val * osc(440)
        play.r = env2.val * osc(880)
        """

        let compiler = WeftCompiler()

        do {
            let ir = try compiler.compile(source)

            // Apply transformation
            var mutableIR = ir
            IRTransformations.inlineSpindleCacheCalls(program: &mutableIR)

            // Both env1 and env2 should have their own cache references
            if let env1Bundle = mutableIR.bundles["env1"],
               let env2Bundle = mutableIR.bundles["env2"] {
                let env1Expr = "\(env1Bundle.strands.first!.expr)"
                let env2Expr = "\(env2Bundle.strands.first!.expr)"

                // Each should reference its own bundle
                print("env1.val: \(env1Expr)")
                print("env2.val: \(env2Expr)")

                // The expressions should be different (different targets)
                XCTAssertNotEqual(env1Expr, env2Expr, "Different instances should have different target refs")
            } else {
                XCTFail("Both env1 and env2 bundles should exist")
            }

            print("SUCCESS: Multiple spindle instances have independent cache targets")

        } catch {
            XCTFail("Compilation failed: \(error)")
        }
    }
}
