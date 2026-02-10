// SpindleFunctionGenTests.swift - Tests for Metal function generation from pure spindles

import XCTest
@testable import WEFTLib

final class SpindleFunctionGenTests: XCTestCase {

    // MARK: - spindleContainsCache Tests

    func testPureSpindleHasNoCache() {
        let spindle = IRSpindle(
            name: "circle",
            params: ["cx", "cy", "radius"],
            locals: [],
            returns: [
                .builtin(name: "step", args: [
                    .param("radius"),
                    .builtin(name: "sqrt", args: [
                        .binaryOp(op: "+",
                            left: .binaryOp(op: "^",
                                left: .binaryOp(op: "-", left: .index(bundle: "me", indexExpr: .param("x")), right: .param("cx")),
                                right: .num(2)),
                            right: .binaryOp(op: "^",
                                left: .binaryOp(op: "-", left: .index(bundle: "me", indexExpr: .param("y")), right: .param("cy")),
                                right: .num(2)))
                    ])
                ])
            ]
        )
        XCTAssertFalse(IRTransformations.spindleContainsCache(spindle))
        XCTAssertTrue(IRTransformations.spindleCanBeFunction(spindle))
    }

    func testCacheSpindleDetected() {
        let spindle = IRSpindle(
            name: "edecay",
            params: ["rate"],
            locals: [
                IRBundle(name: "prev", strands: [
                    IRStrand(name: "val", index: 0, expr: .builtin(name: "cache", args: [
                        .index(bundle: "out", indexExpr: .num(0)),
                        .num(2), .num(1),
                        .index(bundle: "me", indexExpr: .param("i"))
                    ]))
                ]),
                IRBundle(name: "out", strands: [
                    IRStrand(name: "val", index: 0, expr: .binaryOp(op: "*",
                        left: .index(bundle: "prev", indexExpr: .num(0)),
                        right: .param("rate")))
                ])
            ],
            returns: [.index(bundle: "out", indexExpr: .num(0))]
        )
        XCTAssertTrue(IRTransformations.spindleContainsCache(spindle))
        XCTAssertFalse(IRTransformations.spindleCanBeFunction(spindle))
    }

    func testResourceSpindleDetected() {
        let spindle = IRSpindle(
            name: "cam",
            params: ["ch"],
            locals: [],
            returns: [
                .builtin(name: "camera", args: [
                    .index(bundle: "me", indexExpr: .param("x")),
                    .index(bundle: "me", indexExpr: .param("y")),
                    .param("ch")
                ])
            ]
        )
        XCTAssertFalse(IRTransformations.spindleContainsCache(spindle))
        XCTAssertTrue(IRTransformations.spindleUsesResources(spindle))
        XCTAssertFalse(IRTransformations.spindleCanBeFunction(spindle))
    }

    // MARK: - Metal Function Output Tests

    /// Helper: create program with spindles and a display bundle, generate Metal code
    private func generateMetal(
        spindles: [String: IRSpindle],
        bundles: [String: IRBundle]
    ) throws -> String {
        let program = IRProgram(
            bundles: bundles,
            spindles: spindles,
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "visual", bundles: Set(bundles.keys), isSink: true)
        let codegen = MetalCodeGen(program: program, swatch: swatch)
        return try codegen.generate()
    }

    func testSingleReturnSpindleGeneratesFunction() throws {
        let circleSpindle = IRSpindle(
            name: "circle",
            params: ["cx", "cy", "radius"],
            locals: [],
            returns: [
                .builtin(name: "step", args: [
                    .param("radius"),
                    .builtin(name: "sqrt", args: [
                        .binaryOp(op: "+",
                            left: .binaryOp(op: "^",
                                left: .binaryOp(op: "-", left: .index(bundle: "me", indexExpr: .param("x")), right: .param("cx")),
                                right: .num(2)),
                            right: .binaryOp(op: "^",
                                left: .binaryOp(op: "-", left: .index(bundle: "me", indexExpr: .param("y")), right: .param("cy")),
                                right: .num(2)))
                    ])
                ])
            ]
        )

        let shader = try generateMetal(
            spindles: ["circle": circleSpindle],
            bundles: ["display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .call(spindle: "circle", args: [.num(0.5), .num(0.5), .num(0.3)])),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])]
        )

        // Should contain function declaration
        XCTAssertTrue(shader.contains("float weft_circle("), "Should generate Metal function for circle spindle")
        // Should contain coordinate params
        XCTAssertTrue(shader.contains("float x, float y, float t, float w, float h)"), "Function should have coordinate params")
        // Should contain function call in display kernel
        XCTAssertTrue(shader.contains("weft_circle("), "Display kernel should call the function")
        // Should NOT contain the struct (single return)
        XCTAssertFalse(shader.contains("weft_circle_result"), "Single-return spindle should not generate struct")
    }

    func testMultiReturnSpindleGeneratesStruct() throws {
        let swapSpindle = IRSpindle(
            name: "swap",
            params: ["a", "b"],
            locals: [],
            returns: [.param("b"), .param("a")]
        )

        let shader = try generateMetal(
            spindles: ["swap": swapSpindle],
            bundles: ["display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0,
                    expr: .extract(call: .call(spindle: "swap", args: [.num(1), .num(0)]), index: 0)),
                IRStrand(name: "g", index: 1,
                    expr: .extract(call: .call(spindle: "swap", args: [.num(1), .num(0)]), index: 1)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])]
        )

        // Should generate result struct
        XCTAssertTrue(shader.contains("struct weft_swap_result"), "Multi-return spindle should generate result struct")
        XCTAssertTrue(shader.contains("float _0;"), "Struct should have _0 field")
        XCTAssertTrue(shader.contains("float _1;"), "Struct should have _1 field")
        // Should generate function
        XCTAssertTrue(shader.contains("weft_swap_result weft_swap("), "Should generate function with struct return type")
        // Extract should use field access
        XCTAssertTrue(shader.contains("._0"), "Extract index 0 should use ._0")
        XCTAssertTrue(shader.contains("._1"), "Extract index 1 should use ._1")
    }

    func testSpindleWithLocalsGeneratesLocalVars() throws {
        let spindle = IRSpindle(
            name: "foo",
            params: ["a"],
            locals: [
                IRBundle(name: "mid", strands: [
                    IRStrand(name: "v", index: 0,
                        expr: .binaryOp(op: "*", left: .param("a"), right: .num(0.5)))
                ])
            ],
            returns: [
                .binaryOp(op: "+",
                    left: .index(bundle: "mid", indexExpr: .num(0)),
                    right: .num(1))
            ]
        )

        let shader = try generateMetal(
            spindles: ["foo": spindle],
            bundles: ["display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .call(spindle: "foo", args: [.num(0.5)])),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])]
        )

        // Should declare local variable
        XCTAssertTrue(shader.contains("float lv0 ="), "Should declare local variable for spindle local")
        // Return should reference local var
        XCTAssertTrue(shader.contains("return (lv0 + 1.0)"), "Return should reference local variable")
    }

    func testNestedSpindleCallsOrderedCorrectly() throws {
        // Spindle A calls spindle B — B should be declared before A
        let innerSpindle = IRSpindle(
            name: "inner",
            params: ["x"],
            locals: [],
            returns: [.binaryOp(op: "*", left: .param("x"), right: .num(2))]
        )

        let outerSpindle = IRSpindle(
            name: "outer",
            params: ["x"],
            locals: [],
            returns: [.call(spindle: "inner", args: [.param("x")])]
        )

        let shader = try generateMetal(
            spindles: ["inner": innerSpindle, "outer": outerSpindle],
            bundles: ["display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .call(spindle: "outer", args: [.num(1)])),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])]
        )

        // inner should appear before outer in the shader
        guard let innerPos = shader.range(of: "float weft_inner(")?.lowerBound,
              let outerPos = shader.range(of: "float weft_outer(")?.lowerBound else {
            XCTFail("Both weft_inner and weft_outer should be in shader")
            return
        }
        XCTAssertTrue(innerPos < outerPos, "Inner spindle function should be declared before outer (topological order)")
    }

    func testParamNameCollisionFiltered() throws {
        // Spindle with params named x, y, z — x and y collide with coords
        let spindle = IRSpindle(
            name: "perlin3",
            params: ["x", "y", "z"],
            locals: [],
            returns: [.binaryOp(op: "+", left: .param("x"), right: .param("y"))]
        )

        let shader = try generateMetal(
            spindles: ["perlin3": spindle],
            bundles: ["display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .call(spindle: "perlin3", args: [.num(1), .num(2), .num(3)])),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])]
        )

        // Should NOT have duplicate x/y params
        XCTAssertTrue(shader.contains("float weft_perlin3(float x, float y, float z, float t, float w, float h)"),
            "Colliding coord params should be filtered out, got:\n\(shader)")
        // Call site should only pass non-colliding coords
        XCTAssertTrue(shader.contains("weft_perlin3(1.0, 2.0, 3.0, t, w, h)"),
            "Call site should skip colliding coords")
    }

    func testSingleReturnExtractNoStructAccess() throws {
        // Single-return spindle called via .extract — should NOT emit ._0
        let spindle = IRSpindle(
            name: "double",
            params: ["a"],
            locals: [],
            returns: [.binaryOp(op: "*", left: .param("a"), right: .num(2))]
        )

        let shader = try generateMetal(
            spindles: ["double": spindle],
            bundles: ["display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0,
                    expr: .extract(call: .call(spindle: "double", args: [.num(5)]), index: 0)),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])]
        )

        // Should NOT contain ._0 (single-return returns float, not struct)
        XCTAssertFalse(shader.contains("._0"), "Single-return spindle should not use struct field access")
        XCTAssertTrue(shader.contains("weft_double(5.0, x, y, t, w, h)"),
            "Should call function without struct access")
    }

    func testSequentialAssignmentInLocals() throws {
        // Spindle with sequential assignment: t0.v assigned twice
        // t0.v = max(0, a)
        // t0.v = t0.v * t0.v  (references previous value)
        let spindle = IRSpindle(
            name: "smooth",
            params: ["a"],
            locals: [
                IRBundle(name: "t0", strands: [
                    IRStrand(name: "v", index: 0,
                        expr: .builtin(name: "max", args: [.num(0), .param("a")])),
                    IRStrand(name: "v", index: 1,
                        expr: .binaryOp(op: "*",
                            left: .index(bundle: "t0", indexExpr: .param("v")),
                            right: .index(bundle: "t0", indexExpr: .param("v"))))
                ])
            ],
            returns: [.index(bundle: "t0", indexExpr: .param("v"))]
        )

        let shader = try generateMetal(
            spindles: ["smooth": spindle],
            bundles: ["display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .call(spindle: "smooth", args: [.num(0.5)])),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])]
        )

        // Each strand should get a unique variable name (sequential counter)
        XCTAssertTrue(shader.contains("float lv0 = max(0.0, a)"),
            "First assignment should be lv0")
        // Second assignment should reference the first variable
        XCTAssertTrue(shader.contains("float lv1 = (lv0 * lv0)"),
            "Second assignment should reference lv0, got:\n\(shader)")
        // Return should reference the final variable
        XCTAssertTrue(shader.contains("return lv1"),
            "Return should use final variable")
    }

    func testCacheSpindleStillInlines() throws {
        // Cache-containing spindle should NOT generate a Metal function —
        // it should be inlined at the IR level
        let cacheSpindle = IRSpindle(
            name: "edecay",
            params: ["rate"],
            locals: [
                IRBundle(name: "prev", strands: [
                    IRStrand(name: "val", index: 0, expr: .builtin(name: "cache", args: [
                        .index(bundle: "out", indexExpr: .num(0)),
                        .num(2), .num(1),
                        .index(bundle: "me", indexExpr: .param("i"))
                    ]))
                ]),
                IRBundle(name: "out", strands: [
                    IRStrand(name: "val", index: 0, expr: .binaryOp(op: "*",
                        left: .index(bundle: "prev", indexExpr: .num(0)),
                        right: .param("rate")))
                ])
            ],
            returns: [.index(bundle: "out", indexExpr: .num(0))]
        )

        // The display bundle would normally reference a .call to edecay,
        // but after inlineSpindleCacheCalls the .call is expanded.
        // Here we just verify the classification is correct.
        XCTAssertFalse(IRTransformations.spindleCanBeFunction(cacheSpindle),
            "Cache spindle should not be emittable as Metal function")
    }

    // MARK: - Selective Inlining Tests

    func testInlineSpindleCacheCallsPreservesPureCalls() throws {
        let pureSpindle = IRSpindle(
            name: "double",
            params: ["x"],
            locals: [],
            returns: [.binaryOp(op: "*", left: .param("x"), right: .num(2))]
        )

        var program = IRProgram(
            bundles: [
                "a": IRBundle(name: "a", strands: [
                    IRStrand(name: "v", index: 0, expr: .call(spindle: "double", args: [
                        .index(bundle: "me", indexExpr: .param("x"))
                    ]))
                ]),
                "display": IRBundle(name: "display", strands: [
                    IRStrand(name: "r", index: 0, expr: .index(bundle: "a", indexExpr: .num(0))),
                    IRStrand(name: "g", index: 1, expr: .num(0)),
                    IRStrand(name: "b", index: 2, expr: .num(0))
                ])
            ],
            spindles: ["double": pureSpindle],
            order: [],
            resources: []
        )

        IRTransformations.inlineSpindleCacheCalls(program: &program)

        // Pure spindle call should survive inlining
        let aExpr = program.bundles["a"]!.strands[0].expr
        if case .call(let name, _) = aExpr {
            XCTAssertEqual(name, "double", "Pure spindle .call should be preserved")
        } else {
            XCTFail("Expected .call to be preserved, got: \(aExpr)")
        }
    }

    func testInlineSpindleCacheCallsInlinesCacheSpindle() throws {
        let cacheSpindle = IRSpindle(
            name: "edecay",
            params: ["rate"],
            locals: [
                IRBundle(name: "prev", strands: [
                    IRStrand(name: "val", index: 0, expr: .builtin(name: "cache", args: [
                        .index(bundle: "out", indexExpr: .num(0)),
                        .num(2), .num(1),
                        .index(bundle: "me", indexExpr: .param("i"))
                    ]))
                ]),
                IRBundle(name: "out", strands: [
                    IRStrand(name: "val", index: 0, expr: .binaryOp(op: "*",
                        left: .index(bundle: "prev", indexExpr: .num(0)),
                        right: .param("rate")))
                ])
            ],
            returns: [.index(bundle: "out", indexExpr: .num(0))]
        )

        var program = IRProgram(
            bundles: [
                "env": IRBundle(name: "env", strands: [
                    IRStrand(name: "val", index: 0, expr: .call(spindle: "edecay", args: [.num(0.999)]))
                ]),
                "display": IRBundle(name: "display", strands: [
                    IRStrand(name: "r", index: 0, expr: .index(bundle: "env", indexExpr: .num(0))),
                    IRStrand(name: "g", index: 1, expr: .num(0)),
                    IRStrand(name: "b", index: 2, expr: .num(0))
                ])
            ],
            spindles: ["edecay": cacheSpindle],
            order: [],
            resources: []
        )

        IRTransformations.inlineSpindleCacheCalls(program: &program)

        // Cache spindle call should be inlined (no .call remaining)
        let envExpr = program.bundles["env"]!.strands[0].expr
        XCTAssertFalse(envExpr.containsCall(),
            "Cache spindle .call should be fully inlined, got: \(envExpr)")
    }

    // MARK: - Full Pipeline (Compile + Generate) Tests

    func testPureSpindleEndToEnd() throws {
        let source = """
        spindle circle(cx, cy, radius) {
            d.v = sqrt((me.x - cx)^2 + (me.y - cy)^2)
            return.0 = step(radius, d.v)
        }
        dot.v = circle(0.5, 0.5, 0.3)
        display[r,g,b] = [dot.v, dot.v, dot.v]
        """

        let compiler = WeftCompiler()
        var ir = try compiler.compile(source)

        // Apply the inlining pass
        IRTransformations.inlineSpindleCacheCalls(program: &ir)

        // The .call should survive for the pure spindle (may be wrapped in .extract)
        let dotExpr = ir.bundles["dot"]!.strands[0].expr
        switch dotExpr {
        case .call(let name, _):
            XCTAssertEqual(name, "circle")
        case .extract(let callExpr, _):
            if case .call(let name, _) = callExpr {
                XCTAssertEqual(name, "circle")
            } else {
                XCTFail("Expected .extract(.call(circle, ...), ...) to survive, got: \(dotExpr)")
            }
        default:
            XCTFail("Expected .call or .extract to survive inlining, got: \(dotExpr)")
        }

        // Generate Metal code
        let swatch = Swatch(backend: "visual", bundles: Set(ir.bundles.keys), isSink: true)
        let codegen = MetalCodeGen(program: ir, swatch: swatch)
        let shader = try codegen.generate()

        // Should have function declaration and call
        XCTAssertTrue(shader.contains("float weft_circle("), "Should generate Metal function")
        XCTAssertTrue(shader.contains("weft_circle("), "Should call the function")
    }
}
