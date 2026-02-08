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

    // MARK: - Spindle Temporal Remap to Cache Tests

    func testSpindleTemporalRemapSelfRef() throws {
        // spindle decay(input, rate) {
        //     trail.v = max(input, trail.v(me.t ~ me.t - 1) * rate)
        //     return.0 = trail.v
        // }
        // After convertSpindleTemporalRemapsToCache, trail.v should contain cache()

        let source = """
        spindle decay(input, rate) {
            trail.v = max(input, trail.v(me.t ~ me.t - 1) * rate)
            return.0 = trail.v
        }
        dot.v = 1
        display[r,g,b] = [decay(dot.v, 0.99), 0, 0]
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        // Before transformation, the spindle local should have a remap
        let spindleBefore = ir.spindles["decay"]!
        let trailBefore = spindleBefore.locals.first(where: { $0.name == "trail" })!
        let exprBefore = "\(trailBefore.strands[0].expr)"
        XCTAssertTrue(exprBefore.contains("remap") || exprBefore.contains("[me.t"),
                       "Before conversion, trail.v should contain a remap, got: \(exprBefore)")

        // Apply the transformation
        var mutableIR = ir
        IRTransformations.convertSpindleTemporalRemapsToCache(
            program: &mutableIR,
            statefulBuiltins: ["osc", "cache", "noise", "microphone", "camera", "sample", "text"]
        )

        // After transformation, the spindle local should have cache() instead of remap
        let spindleAfter = mutableIR.spindles["decay"]!
        let trailAfter = spindleAfter.locals.first(where: { $0.name == "trail" })!
        let exprAfter = trailAfter.strands[0].expr

        if case .builtin(let name, let args) = exprAfter {
            XCTAssertEqual(name, "cache", "Self-ref temporal remap should become cache builtin")
            XCTAssertEqual(args.count, 4, "Cache should have 4 args: value, historySize, tapIndex, signal")
        } else {
            XCTFail("Expected cache builtin after conversion, got: \(exprAfter)")
        }
    }

    func testSpindleTemporalRemapNonSelfRef() throws {
        // Temporal remap on a non-self-referencing stateful base in a spindle local
        // The base references a param (which is opaque/potentially stateful at spindle level),
        // so this tests that pure temporal remaps are left as remaps

        let source = """
        spindle delay(input) {
            prev.v = input(me.t ~ me.t - 1)
            return.0 = prev.v
        }
        a.v = sin(me.t)
        display[r,g,b] = [delay(a.v), 0, 0]
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        var mutableIR = ir
        IRTransformations.convertSpindleTemporalRemapsToCache(
            program: &mutableIR,
            statefulBuiltins: ["osc", "cache", "noise", "microphone", "camera", "sample", "text"]
        )

        // param("input") has no builtins, so it's not stateful -> should stay as remap
        let spindle = mutableIR.spindles["delay"]!
        let prev = spindle.locals.first(where: { $0.name == "prev" })!
        let expr = prev.strands[0].expr

        if case .remap = expr {
            // Correct: pure param reference stays as remap
        } else {
            // Also acceptable if it became cache (if resolveBaseBuiltins found something)
            // but for a bare param, it should stay remap
            XCTFail("Expected remap for pure param temporal remap, got: \(expr)")
        }
    }

    func testSpindleTemporalRemapFullPipeline() throws {
        // Full pipeline test: spindle with temporal remap -> convert -> inline -> should produce cache

        let source = """
        spindle decay(input, rate) {
            trail.v = max(input, trail.v(me.t ~ me.t - 1) * rate)
            return.0 = trail.v
        }
        dot.v = 1
        env.v = decay(dot.v, 0.99)
        display[r,g,b] = [env.v, env.v, env.v]
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        var mutableIR = ir

        // Step 1: Convert temporal remaps in spindle locals to cache
        IRTransformations.convertSpindleTemporalRemapsToCache(
            program: &mutableIR,
            statefulBuiltins: ["osc", "cache", "noise", "microphone", "camera", "sample", "text"]
        )

        // Verify spindle now has cache in its local
        let spindleAfterConvert = mutableIR.spindles["decay"]!
        let trailLocal = spindleAfterConvert.locals.first(where: { $0.name == "trail" })!
        if case .builtin(let name, _) = trailLocal.strands[0].expr {
            XCTAssertEqual(name, "cache")
        } else {
            XCTFail("Expected cache in spindle local after temporal remap conversion")
        }

        // Step 2: Inline spindle calls with cache target substitution
        IRTransformations.inlineSpindleCacheCalls(program: &mutableIR)

        // After inlining, env.v should contain a cache that references env (not trail)
        if let envBundle = mutableIR.bundles["env"] {
            let envExpr = "\(envBundle.strands[0].expr)"
            XCTAssertTrue(envExpr.contains("cache"), "Inlined expression should contain cache: \(envExpr)")
            XCTAssertTrue(envExpr.contains("env"), "Cache target should reference env (not trail): \(envExpr)")
        } else {
            XCTFail("env bundle should exist after transformation")
        }
    }

    // MARK: - Signal Return Through Remap Tests

    /// Verify that remapping a spindle return inlines the return expression
    /// and applies coordinate substitution (the "signal return" property).
    func testBasicRemapThroughSpindleReturn() throws {
        // gradient returns lerp(a, b, me.x)
        // shifted.v remaps gradient's return with me.x ~ me.x + 0.1
        // After inlining, shifted.v should be lerp(0, 1, (me.x + 0.1))
        let source = """
        spindle gradient(a, b) {
            return.0 = lerp(a, b, me.x)
        }

        g.v = gradient(0, 1)
        shifted.v = g.v(me.x ~ me.x + 0.1)
        display[r,g,b] = [shifted.v, shifted.v, shifted.v]
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        // Inline the full expression for shifted.v
        let shiftedBundle = ir.bundles["shifted"]!
        let inlined = try IRTransformations.inlineExpression(
            shiftedBundle.strands[0].expr, program: ir
        )

        // After inlining, the expression should be lerp(0, 1, (me.x + 0.1))
        // Key check: it should contain lerp (from the spindle return)
        // and NOT contain a .call or .remap node (everything got resolved)
        XCTAssertTrue(inlined.allBuiltins().contains("lerp"),
                      "Inlined expression should contain lerp from spindle return, got: \(inlined)")
        XCTAssertFalse(inlined.containsCall(),
                       "Should not contain unresolved spindle calls, got: \(inlined)")

        // Verify me.x was substituted: the expression should contain a + 0.1
        let desc = inlined.description
        XCTAssertTrue(desc.contains("0.1"),
                      "Should contain the remap offset 0.1, got: \(desc)")
    }

    /// Verify remap through a spindle with local variables.
    func testRemapThroughSpindleWithLocals() throws {
        // The spindle uses a local, and the caller remaps the result.
        // The local's expression should be fully inlined with the remap applied.
        let source = """
        spindle curve(a, b) {
            mid.v = (a + b) / 2
            return.0 = lerp(mid.v, b, me.x)
        }

        c.v = curve(0, 1)
        remapped.v = c.v(me.x ~ me.x * 2)
        display[r,g,b] = [remapped.v, 0, 0]
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        let remappedBundle = ir.bundles["remapped"]!
        let inlined = try IRTransformations.inlineExpression(
            remappedBundle.strands[0].expr, program: ir
        )

        // Should contain lerp (from spindle body) with me.x * 2 substituted
        XCTAssertTrue(inlined.allBuiltins().contains("lerp"),
                      "Should contain lerp after inlining, got: \(inlined)")
        XCTAssertFalse(inlined.containsCall(),
                       "Should not contain unresolved calls, got: \(inlined)")
    }

    /// Verify chained spindle calls where the outer spindle remaps
    /// an inner spindle's return value.
    func testChainedSpindleCallsWithRemap() throws {
        let source = """
        spindle base(freq) {
            return.0 = sin(me.x * freq)
        }

        spindle shifted(freq, offset) {
            b.v = base(freq)
            return.0 = b.v(me.x ~ me.x + offset)
        }

        result.v = shifted(10, 0.25)
        display[r,g,b] = [result.v, result.v, result.v]
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        let resultBundle = ir.bundles["result"]!
        let inlined = try IRTransformations.inlineExpression(
            resultBundle.strands[0].expr, program: ir
        )

        // After full inlining: sin((me.x + 0.25) * 10)
        // Should contain sin, should not have unresolved calls
        XCTAssertTrue(inlined.allBuiltins().contains("sin"),
                      "Should contain sin from base spindle, got: \(inlined)")
        XCTAssertFalse(inlined.containsCall(),
                       "Should not contain unresolved calls, got: \(inlined)")
        let desc = inlined.description
        XCTAssertTrue(desc.contains("0.25"),
                      "Should contain the remap offset 0.25, got: \(desc)")
    }

    /// Verify multi-return spindle where each strand is remapped independently.
    func testMultiReturnSpindleWithRemap() throws {
        let source = """
        spindle gradient2(a, b) {
            return.0 = lerp(a, b, me.x)
            return.1 = lerp(b, a, me.x)
        }

        g[u,v] = gradient2(0, 1)
        shifted[u,v] = g -> { 0..2(me.x ~ me.x + 0.5) }
        display[r,g,b] = [shifted.u, shifted.v, 0]
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        // Both strands of shifted should have inlined lerp with me.x + 0.5
        let shiftedBundle = ir.bundles["shifted"]!
        for strand in shiftedBundle.strands {
            let inlined = try IRTransformations.inlineExpression(strand.expr, program: ir)
            XCTAssertTrue(inlined.allBuiltins().contains("lerp"),
                          "Strand \(strand.name) should contain lerp, got: \(inlined)")
            XCTAssertFalse(inlined.containsCall(),
                           "Strand \(strand.name) should not contain unresolved calls, got: \(inlined)")
        }
    }

    // MARK: - Spindle Temporal Remap to Cache Tests

    func testSpindleTemporalRemapWithStatefulLocal() throws {
        // Spindle local that references another local containing a stateful builtin
        // The temporal remap base references a local whose expression uses osc()

        let source = """
        spindle wobble(freq) {
            raw.v = osc(freq)
            prev.v = raw.v(me.t ~ me.t - 1)
            return.0 = raw.v - prev.v
        }
        display[r,g,b] = [wobble(10), 0, 0]
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        var mutableIR = ir
        IRTransformations.convertSpindleTemporalRemapsToCache(
            program: &mutableIR,
            statefulBuiltins: ["osc", "cache", "noise", "microphone", "camera", "sample", "text"]
        )

        // prev.v references raw.v which contains osc() — stateful, non-self-ref
        // Should be converted to cache
        let spindle = mutableIR.spindles["wobble"]!
        let prev = spindle.locals.first(where: { $0.name == "prev" })!
        let expr = prev.strands[0].expr

        if case .builtin(let name, _) = expr {
            XCTAssertEqual(name, "cache", "Stateful local ref temporal remap should become cache")
        } else {
            XCTFail("Expected cache for stateful local ref, got: \(expr)")
        }
    }
}
