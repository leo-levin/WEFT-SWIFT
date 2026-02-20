// CodeGenTests.swift - Comprehensive tests for Metal and Audio code generation

import XCTest
@testable import WEFTLib

// MARK: - Metal Code Generation Tests

final class MetalCodeGenTests: XCTestCase {

    // MARK: - Helpers

    /// Generate Metal shader code from bundles and spindles
    private func generateMetal(
        bundles: [String: IRBundle],
        spindles: [String: IRSpindle] = [:],
        cacheDescriptors: [CacheNodeDescriptor] = [],
        crossDomainInputs: [String: [String]] = [String: [String]](),
        order: [IRProgram.OrderEntry] = []
    ) throws -> String {
        let program = IRProgram(
            bundles: bundles,
            spindles: spindles,
            order: order,
            resources: []
        )
        let swatch = Swatch(backend: "visual", bundles: Set(bundles.keys), isSink: true)
        let codegen = MetalCodeGen(
            program: program,
            swatch: swatch,
            cacheDescriptors: cacheDescriptors,
            crossDomainInputs: crossDomainInputs
        )
        return try codegen.generate()
    }

    /// Create a simple display-only program with a single expression for each channel
    private func displayBundle(r: IRExpr, g: IRExpr = .num(0), b: IRExpr = .num(0)) -> [String: IRBundle] {
        return ["display": IRBundle(name: "display", strands: [
            IRStrand(name: "r", index: 0, expr: r),
            IRStrand(name: "g", index: 1, expr: g),
            IRStrand(name: "b", index: 2, expr: b)
        ])]
    }

    // MARK: - select() Builtin Tests

    func testSelectGeneratesTernaryChainNotFunctionCall() throws {
        // select(index, b0, b1, b2) should produce nested ternary, NOT a function call
        let expr = IRExpr.builtin(name: "select", args: [
            .index(bundle: "me", indexExpr: .param("x")),
            .num(1), .num(2), .num(3)
        ])
        let shader = try generateMetal(bundles: displayBundle(r: expr))

        // Should contain ternary operator patterns
        XCTAssertTrue(shader.contains("?"), "select should generate ternary operators")
        XCTAssertTrue(shader.contains("<"), "select with 3+ branches should use < comparisons")
        // Should NOT contain select( as a function call
        XCTAssertFalse(shader.contains("select("), "select should NOT be emitted as a function call")
    }

    func testSelectTwoBranches() throws {
        // select(index, a, b) -> (index != 0.0 ? b : a)
        let expr = IRExpr.builtin(name: "select", args: [
            .num(0), .num(10), .num(20)
        ])
        let shader = try generateMetal(bundles: displayBundle(r: expr))

        XCTAssertTrue(shader.contains("!= 0.0"), "Two-branch select should check != 0.0")
        XCTAssertTrue(shader.contains("10.0"), "Should contain branch 0 value")
        XCTAssertTrue(shader.contains("20.0"), "Should contain branch 1 value")
    }

    func testSelectSingleBranch() throws {
        // select(index, only_value) -> just the value
        let expr = IRExpr.builtin(name: "select", args: [.num(0), .num(42)])
        let shader = try generateMetal(bundles: displayBundle(r: expr))

        XCTAssertTrue(shader.contains("42.0"), "Single-branch select should emit the value directly")
    }

    func testSelectThreePlusBranchesGeneratesNestedTernary() throws {
        // select(idx, a, b, c) -> nested ternary from right to left
        let expr = IRExpr.builtin(name: "select", args: [
            .index(bundle: "me", indexExpr: .param("x")),
            .num(100), .num(200), .num(300)
        ])
        let shader = try generateMetal(bundles: displayBundle(r: expr))

        // Should have two ternary levels for 3 branches
        let questionCount = shader.filter { $0 == "?" }.count
        // At minimum there should be 2 ternary operators for 3 branches
        XCTAssertGreaterThanOrEqual(questionCount, 2,
            "3-branch select should produce at least 2 ternary operators")
    }

    // MARK: - noise() Builtin Tests

    func testNoiseGeneratesHashFormula() throws {
        let expr = IRExpr.builtin(name: "noise", args: [.num(1.5), .num(2.5)])
        let shader = try generateMetal(bundles: displayBundle(r: expr))

        // Should contain the hash-based noise formula components
        XCTAssertTrue(shader.contains("fract(sin(dot(float2("), "noise should use fract(sin(dot(...))) pattern")
        XCTAssertTrue(shader.contains("12.9898"), "noise should use hash constant 12.9898")
        XCTAssertTrue(shader.contains("78.233"), "noise should use hash constant 78.233")
        XCTAssertTrue(shader.contains("43758.5453"), "noise should use hash constant 43758.5453")
    }

    // MARK: - Cache Expression Tests

    func testCacheGeneratesBufferReadsAndWrites() throws {
        let valueExpr = IRExpr.index(bundle: "me", indexExpr: .param("x"))
        let signalExpr = IRExpr.index(bundle: "me", indexExpr: .param("t"))
        let cacheDescriptor = CacheNodeDescriptor(
            id: "test_cache_0",
            bundleName: "a",
            strandIndex: 0,
            historySize: 2,
            tapIndex: 1,
            valueExpr: valueExpr,
            signalExpr: signalExpr,
            storage: .perCoordinate,
            backendId: "visual",
            historyBufferIndex: 0,
            signalBufferIndex: 1,
            hasSelfReference: false,
            spatialDimensions: ["x", "y"]
        )

        let program = IRProgram(
            bundles: [
                "a": IRBundle(name: "a", strands: [
                    IRStrand(name: "val", index: 0, expr: .builtin(name: "cache", args: [
                        valueExpr, .num(2), .num(1), signalExpr
                    ]))
                ]),
                "display": IRBundle(name: "display", strands: [
                    IRStrand(name: "r", index: 0, expr: .index(bundle: "a", indexExpr: .param("val"))),
                    IRStrand(name: "g", index: 1, expr: .num(0)),
                    IRStrand(name: "b", index: 2, expr: .num(0))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "visual", bundles: Set(program.bundles.keys), isSink: true)
        let codegen = MetalCodeGen(program: program, swatch: swatch, cacheDescriptors: [cacheDescriptor])
        let shader = try codegen.generate()

        // Should have cache helper variables
        XCTAssertTrue(shader.contains("cache0_value"), "Should declare cache0_value")
        XCTAssertTrue(shader.contains("cache0_signal_val"), "Should declare cache0_signal_val")
        XCTAssertTrue(shader.contains("cache0_history"), "Should reference cache0_history buffer")
        XCTAssertTrue(shader.contains("cache0_signal"), "Should reference cache0_signal buffer")
        XCTAssertTrue(shader.contains("cache0_result"), "Should declare cache0_result")
        // Should have tick logic
        XCTAssertTrue(shader.contains("cache0_shouldTick"), "Should have shouldTick flag")
        XCTAssertTrue(shader.contains("isnan("), "Should check for NaN in signal comparison")
        // Should have pixel index calculation
        XCTAssertTrue(shader.contains("pixelIndex"), "Should calculate pixelIndex for buffer access")
    }

    // MARK: - Cross-Domain Buffer Access Tests

    func testCrossDomainBufferAccess() throws {
        // Cross-domain: audio_data bundle exists in program but NOT in the swatch
        // The swatch only contains "display", while "audio_data" is in another domain
        let program = IRProgram(
            bundles: [
                "audio_data": IRBundle(name: "audio_data", strands: [
                    IRStrand(name: "level", index: 0, expr: .num(0)),
                    IRStrand(name: "peak", index: 1, expr: .num(0))
                ]),
                "display": IRBundle(name: "display", strands: [
                    IRStrand(name: "r", index: 0, expr: .index(bundle: "audio_data", indexExpr: .param("level"))),
                    IRStrand(name: "g", index: 1, expr: .num(0)),
                    IRStrand(name: "b", index: 2, expr: .num(0))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        // Only "display" is in the visual swatch; "audio_data" is NOT
        let swatch = Swatch(backend: "visual", bundles: ["display"], isSink: true)
        let crossDomainInputs = ["audio_data": ["level", "peak"]]
        let codegen = MetalCodeGen(
            program: program,
            swatch: swatch,
            crossDomainInputs: crossDomainInputs
        )
        let shader = try codegen.generate()

        // Should access crossDomainData buffer with correct index
        XCTAssertTrue(shader.contains("crossDomainData["), "Should read from crossDomainData buffer")
        XCTAssertTrue(shader.contains("device float* crossDomainData"), "Should declare crossDomainData buffer param")
    }

    func testCrossDomainSlotMapOrdering() throws {
        let crossDomainInputs = ["alpha": ["x", "y"], "beta": ["val"]]
        let program = IRProgram(bundles: [
            "display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .num(0)),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])
        ], spindles: [:], order: [], resources: [])
        let swatch = Swatch(backend: "visual", bundles: ["display"], isSink: true)
        let codegen = MetalCodeGen(
            program: program,
            swatch: swatch,
            crossDomainInputs: crossDomainInputs
        )

        // Slot map should be sorted by key, then by strand order
        XCTAssertEqual(codegen.crossDomainSlotMap["alpha.x"], 0)
        XCTAssertEqual(codegen.crossDomainSlotMap["alpha.y"], 1)
        XCTAssertEqual(codegen.crossDomainSlotMap["beta.val"], 2)
        XCTAssertEqual(codegen.crossDomainSlotCount, 3)
    }

    // MARK: - Display Output Tests

    func testDisplayOutputWritesFloat4() throws {
        let shader = try generateMetal(bundles: displayBundle(
            r: .index(bundle: "me", indexExpr: .param("x")),
            g: .index(bundle: "me", indexExpr: .param("y")),
            b: .index(bundle: "me", indexExpr: .param("t"))
        ))

        // Should write output as float4 with alpha=1
        XCTAssertTrue(shader.contains("output.write(float4(r, g, b, 1.0), gid)"),
            "Display kernel should write float4(r,g,b,1.0) to output texture")
    }

    func testDisplayKernelHasCorrectSignature() throws {
        let shader = try generateMetal(bundles: displayBundle(r: .num(1)))

        XCTAssertTrue(shader.contains("kernel void displayKernel("), "Should generate displayKernel")
        XCTAssertTrue(shader.contains("texture2d<float, access::write> output [[texture(0)]]"),
            "Output texture should be at index 0")
        XCTAssertTrue(shader.contains("constant Uniforms& uniforms [[buffer(0)]]"),
            "Uniforms should be at buffer 0")
        XCTAssertTrue(shader.contains("uint2 gid [[thread_position_in_grid]]"),
            "Should have thread position")
    }

    // MARK: - Binary Operator Code Generation

    func testBinaryOpCodeGeneration() throws {
        let testCases: [(String, String)] = [
            ("+", "(1.0 + 2.0)"),
            ("-", "(1.0 - 2.0)"),
            ("*", "(1.0 * 2.0)"),
            ("/", "(1.0 / 2.0)"),
            ("%", "fmod(1.0, 2.0)"),
            ("^", "pow(1.0, 2.0)"),
            ("<", "(1.0 < 2.0 ? 1.0 : 0.0)"),
            (">", "(1.0 > 2.0 ? 1.0 : 0.0)"),
            ("<=", "(1.0 <= 2.0 ? 1.0 : 0.0)"),
            (">=", "(1.0 >= 2.0 ? 1.0 : 0.0)"),
            ("==", "(1.0 == 2.0 ? 1.0 : 0.0)"),
            ("!=", "(1.0 != 2.0 ? 1.0 : 0.0)"),
        ]

        for (op, expected) in testCases {
            let expr = IRExpr.binaryOp(op: op, left: .num(1), right: .num(2))
            let shader = try generateMetal(bundles: displayBundle(r: expr))
            XCTAssertTrue(shader.contains(expected),
                "Binary op '\(op)' should generate '\(expected)', shader contains:\n\(shader)")
        }
    }

    func testLogicalAndCodeGeneration() throws {
        let expr = IRExpr.binaryOp(op: "&&", left: .num(1), right: .num(0))
        let shader = try generateMetal(bundles: displayBundle(r: expr))
        XCTAssertTrue(shader.contains("!= 0.0 && "), "AND should compare both operands to 0.0")
    }

    func testLogicalOrCodeGeneration() throws {
        let expr = IRExpr.binaryOp(op: "||", left: .num(0), right: .num(1))
        let shader = try generateMetal(bundles: displayBundle(r: expr))
        XCTAssertTrue(shader.contains("!= 0.0 ||"), "OR should compare both operands to 0.0")
    }

    // MARK: - Unary Operator Code Generation

    func testUnaryNegationCodeGeneration() throws {
        let expr = IRExpr.unaryOp(op: "-", operand: .num(5))
        let shader = try generateMetal(bundles: displayBundle(r: expr))
        XCTAssertTrue(shader.contains("(-5.0)"), "Negation should wrap in parens")
    }

    func testUnaryNotCodeGeneration() throws {
        let expr = IRExpr.unaryOp(op: "!", operand: .num(1))
        let shader = try generateMetal(bundles: displayBundle(r: expr))
        XCTAssertTrue(shader.contains("== 0.0 ? 1.0 : 0.0"), "NOT should use == 0.0 check")
    }

    // MARK: - Bundle Inlining

    func testBundleReferenceInlinesExpression() throws {
        let bundles: [String: IRBundle] = [
            "a": IRBundle(name: "a", strands: [
                IRStrand(name: "val", index: 0, expr: .binaryOp(op: "+",
                    left: .index(bundle: "me", indexExpr: .param("x")),
                    right: .index(bundle: "me", indexExpr: .param("y"))))
            ]),
            "display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .index(bundle: "a", indexExpr: .param("val"))),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])
        ]
        let shader = try generateMetal(bundles: bundles)

        // Bundle "a" should be inlined into display
        XCTAssertTrue(shader.contains("(x + y)"), "Bundle reference should inline the expression")
    }

    // MARK: - Nested Expression Tests

    func testNestedBuiltinExpressions() throws {
        // sin(cos(x) + abs(y))
        let expr = IRExpr.builtin(name: "sin", args: [
            .binaryOp(op: "+",
                left: .builtin(name: "cos", args: [.index(bundle: "me", indexExpr: .param("x"))]),
                right: .builtin(name: "abs", args: [.index(bundle: "me", indexExpr: .param("y"))]))
        ])
        let shader = try generateMetal(bundles: displayBundle(r: expr))

        XCTAssertTrue(shader.contains("sin((cos(x) + abs(y)))"),
            "Nested expression should be properly parenthesized, got:\n\(shader)")
    }

    // MARK: - Error Handling

    func testUnknownBinaryOpThrows() throws {
        let expr = IRExpr.binaryOp(op: "??", left: .num(1), right: .num(2))
        XCTAssertThrowsError(try generateMetal(bundles: displayBundle(r: expr))) { error in
            XCTAssertTrue("\(error)".contains("Unknown binary operator"),
                "Should throw error about unknown binary operator")
        }
    }

    func testUnknownUnaryOpThrows() throws {
        let expr = IRExpr.unaryOp(op: "~", operand: .num(1))
        XCTAssertThrowsError(try generateMetal(bundles: displayBundle(r: expr))) { error in
            XCTAssertTrue("\(error)".contains("Unknown unary operator"),
                "Should throw error about unknown unary operator")
        }
    }

    func testUnknownBuiltinThrows() throws {
        let expr = IRExpr.builtin(name: "nonexistent", args: [.num(1)])
        XCTAssertThrowsError(try generateMetal(bundles: displayBundle(r: expr))) { error in
            XCTAssertTrue("\(error)".contains("Unknown builtin"),
                "Should throw error about unknown builtin")
        }
    }

    func testCircularBundleReferenceThrows() throws {
        // a.val references b.val, b.val references a.val -> circular
        let bundles: [String: IRBundle] = [
            "a": IRBundle(name: "a", strands: [
                IRStrand(name: "val", index: 0, expr: .index(bundle: "b", indexExpr: .param("val")))
            ]),
            "b": IRBundle(name: "b", strands: [
                IRStrand(name: "val", index: 0, expr: .index(bundle: "a", indexExpr: .param("val")))
            ]),
            "display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .index(bundle: "a", indexExpr: .param("val"))),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])
        ]
        XCTAssertThrowsError(try generateMetal(bundles: bundles)) { error in
            XCTAssertTrue("\(error)".contains("Circular reference") || "\(error)".contains("too deeply"),
                "Should detect circular reference, got: \(error)")
        }
    }

    // MARK: - Builtin Function Code Generation

    func testLerpAndMixGenerateMixCall() throws {
        // Both lerp and mix should map to Metal's mix()
        let lerpExpr = IRExpr.builtin(name: "lerp", args: [.num(0), .num(10), .num(0.5)])
        let mixExpr = IRExpr.builtin(name: "mix", args: [.num(0), .num(10), .num(0.5)])

        let lerpShader = try generateMetal(bundles: displayBundle(r: lerpExpr))
        let mixShader = try generateMetal(bundles: displayBundle(r: mixExpr))

        XCTAssertTrue(lerpShader.contains("mix(0.0, 10.0, 0.5"), "lerp should generate Metal mix()")
        XCTAssertTrue(mixShader.contains("mix(0.0, 10.0, 0.5"), "mix should generate Metal mix()")
    }

    // MARK: - Multi-Bundle Dependency Tests

    func testMultiBundleChainedDependencies() throws {
        // a -> b -> display (chain of dependencies)
        let bundles: [String: IRBundle] = [
            "a": IRBundle(name: "a", strands: [
                IRStrand(name: "val", index: 0, expr: .index(bundle: "me", indexExpr: .param("x")))
            ]),
            "b": IRBundle(name: "b", strands: [
                IRStrand(name: "val", index: 0, expr: .binaryOp(op: "*",
                    left: .index(bundle: "a", indexExpr: .param("val")),
                    right: .num(2)))
            ]),
            "display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .index(bundle: "b", indexExpr: .param("val"))),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])
        ]
        let shader = try generateMetal(bundles: bundles)

        // Should fully inline: display.r = a.val * 2 = me.x * 2
        XCTAssertTrue(shader.contains("(x * 2.0)"), "Chained dependencies should fully inline")
    }

    // MARK: - Name Sanitization

    func testNameSanitizationForDollarPrefix() throws {
        let bundles: [String: IRBundle] = [
            "$temp": IRBundle(name: "$temp", strands: [
                IRStrand(name: "val", index: 0, expr: .num(0.5))
            ]),
            "display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: .index(bundle: "$temp", indexExpr: .param("val"))),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])
        ]
        // Should not throw - $ gets sanitized to _
        let shader = try generateMetal(bundles: bundles)
        XCTAssertFalse(shader.contains("$"), "Dollar signs should be sanitized out of Metal code")
    }

    // MARK: - Mouse/Key Builtin Tests

    func testMouseBuiltinGeneratesUniformAccess() throws {
        let exprX = IRExpr.builtin(name: "mouse", args: [.num(0)])
        let exprY = IRExpr.builtin(name: "mouse", args: [.num(1)])
        let exprDown = IRExpr.builtin(name: "mouse", args: [.num(2)])

        let shaderX = try generateMetal(bundles: displayBundle(r: exprX))
        let shaderY = try generateMetal(bundles: displayBundle(r: exprY))
        let shaderDown = try generateMetal(bundles: displayBundle(r: exprDown))

        XCTAssertTrue(shaderX.contains("uniforms.mouseX"), "mouse(0) should access mouseX")
        XCTAssertTrue(shaderY.contains("uniforms.mouseY"), "mouse(1) should access mouseY")
        XCTAssertTrue(shaderDown.contains("uniforms.mouseDown"), "mouse(2) should access mouseDown")
    }

    func testKeyBuiltinGeneratesBufferAccess() throws {
        let expr = IRExpr.builtin(name: "key", args: [.num(32)])
        let shader = try generateMetal(bundles: displayBundle(r: expr))

        XCTAssertTrue(shader.contains("keyStates["), "key() should access keyStates buffer")
        XCTAssertTrue(shader.contains("clamp(int("), "key() should clamp the index")
        XCTAssertTrue(shader.contains("device float* keyStates"), "Should declare keyStates buffer")
    }
}


// MARK: - Audio Code Generation Tests

final class AudioCodeGenTests: XCTestCase {

    // MARK: - Helpers

    /// Create an audio program with a play bundle and evaluate it
    private func evaluateAudio(
        expr: IRExpr,
        sampleIndex: Int = 0,
        time: Double = 0.5,
        sampleRate: Double = 44100
    ) throws -> Float {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: expr)
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        let (left, _) = renderFunc(sampleIndex, time, sampleRate)
        return left
    }

    /// Create an audio program with both channels and evaluate it
    private func evaluateAudioStereo(
        left: IRExpr,
        right: IRExpr,
        sampleIndex: Int = 0,
        time: Double = 0.5,
        sampleRate: Double = 44100
    ) throws -> (Float, Float) {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: left),
                    IRStrand(name: "right", index: 1, expr: right)
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        return renderFunc(sampleIndex, time, sampleRate)
    }

    // MARK: - select() Builtin Tests

    func testSelectEvaluatesCorrectBranch() throws {
        // select(0, 10, 20, 30) -> 10
        let r0 = try evaluateAudio(expr: .builtin(name: "select", args: [.num(0), .num(10), .num(20), .num(30)]))
        XCTAssertEqual(r0, 10.0, accuracy: 0.001)

        // select(1, 10, 20, 30) -> 20
        let r1 = try evaluateAudio(expr: .builtin(name: "select", args: [.num(1), .num(10), .num(20), .num(30)]))
        XCTAssertEqual(r1, 20.0, accuracy: 0.001)

        // select(2, 10, 20, 30) -> 30
        let r2 = try evaluateAudio(expr: .builtin(name: "select", args: [.num(2), .num(10), .num(20), .num(30)]))
        XCTAssertEqual(r2, 30.0, accuracy: 0.001)
    }

    func testSelectClampsOutOfRangeIndex() throws {
        // select(5, 10, 20, 30) -> 30 (clamped to last branch)
        let r = try evaluateAudio(expr: .builtin(name: "select", args: [.num(5), .num(10), .num(20), .num(30)]))
        XCTAssertEqual(r, 30.0, accuracy: 0.001, "Out-of-range index should clamp to last branch")

        // select(-1, 10, 20, 30) -> 10 (clamped to first branch)
        let rNeg = try evaluateAudio(expr: .builtin(name: "select", args: [.num(-1), .num(10), .num(20), .num(30)]))
        XCTAssertEqual(rNeg, 10.0, accuracy: 0.001, "Negative index should clamp to first branch")
    }

    func testSelectWithDynamicIndex() throws {
        // Use me.t as index: with t=0.5, floor(0.5) = 0, so should pick branch 0
        let expr = IRExpr.builtin(name: "select", args: [
            .builtin(name: "floor", args: [.index(bundle: "me", indexExpr: .param("t"))]),
            .num(100), .num(200), .num(300)
        ])
        let result = try evaluateAudio(expr: expr, time: 0.5)
        XCTAssertEqual(result, 100.0, accuracy: 0.001, "floor(0.5) = 0, should select branch 0")
    }

    // MARK: - Scope Function Generation Tests

    func testScopeFunctionProducesPerStrandEvaluators() throws {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .num(0))
                ]),
                "scope": IRBundle(name: "scope", strands: [
                    IRStrand(name: "wave", index: 0, expr: .builtin(name: "sin", args: [
                        .index(bundle: "me", indexExpr: .param("t"))
                    ])),
                    IRStrand(name: "level", index: 1, expr: .num(0.5))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play", "scope"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        guard let (scopeFn, strandNames) = try codegen.generateScopeFunction() else {
            XCTFail("Should generate scope function when scope bundle exists")
            return
        }

        XCTAssertEqual(strandNames, ["wave", "level"], "Should return strand names in order")

        let values = scopeFn(0, 1.0, 44100)
        XCTAssertEqual(values.count, 2, "Should produce one value per strand")
        XCTAssertEqual(values[0], sinf(1.0), accuracy: 0.001, "wave = sin(t) at t=1.0")
        XCTAssertEqual(values[1], 0.5, accuracy: 0.001, "level = 0.5")
    }

    func testNoScopeBundleReturnsNil() throws {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .num(0))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        let result = try codegen.generateScopeFunction()
        XCTAssertNil(result, "Should return nil when no scope bundle exists")
    }

    // MARK: - Cross-Domain Output Evaluator Tests

    func testOutputEvaluatorsProduceCorrectValues() throws {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .num(0))
                ]),
                "level": IRBundle(name: "level", strands: [
                    IRStrand(name: "val", index: 0, expr: .binaryOp(op: "*",
                        left: .num(0.5),
                        right: .index(bundle: "me", indexExpr: .param("t"))))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play", "level"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        let evaluators = try codegen.generateOutputEvaluators(outputBundles: ["level"])
        XCTAssertEqual(evaluators.count, 1)

        let (bundleName, strandEvals) = evaluators[0]
        XCTAssertEqual(bundleName, "level")
        XCTAssertEqual(strandEvals.count, 1)

        let (strandName, eval) = strandEvals[0]
        XCTAssertEqual(strandName, "val")

        let ctx = AudioContext(sampleIndex: 0, time: 2.0, sampleRate: 44100)
        let value = eval(ctx)
        XCTAssertEqual(value, 1.0, accuracy: 0.001, "0.5 * t at t=2.0 should be 1.0")
    }

    // MARK: - Math Edge Cases

    func testDivisionByZero() throws {
        let result = try evaluateAudio(expr: .binaryOp(op: "/", left: .num(1), right: .num(0)))
        XCTAssertTrue(result.isInfinite, "1/0 should produce infinity")
    }

    func testNegativeSqrt() throws {
        let result = try evaluateAudio(expr: .builtin(name: "sqrt", args: [.num(-1)]))
        XCTAssertTrue(result.isNaN, "sqrt(-1) should produce NaN")
    }

    func testModuloWithZeroDivisor() throws {
        let result = try evaluateAudio(expr: .builtin(name: "mod", args: [.num(5), .num(0)]))
        XCTAssertTrue(result.isNaN, "mod(5, 0) should produce NaN")
    }

    func testFractNegativeNumber() throws {
        let result = try evaluateAudio(expr: .builtin(name: "fract", args: [.num(-1.3)]))
        // fract(-1.3) = -1.3 - floor(-1.3) = -1.3 - (-2) = 0.7
        XCTAssertEqual(result, 0.7, accuracy: 0.001, "fract(-1.3) should be 0.7")
    }

    // MARK: - Coordinate Access

    func testMeCoordinateAccess() throws {
        // me.i should return sampleIndex
        let iResult = try evaluateAudio(
            expr: .index(bundle: "me", indexExpr: .param("i")),
            sampleIndex: 42
        )
        XCTAssertEqual(iResult, 42.0, accuracy: 0.001)

        // me.t should return time
        let tResult = try evaluateAudio(
            expr: .index(bundle: "me", indexExpr: .param("t")),
            time: 1.5
        )
        XCTAssertEqual(tResult, 1.5, accuracy: 0.001)

        // me.sampleRate should return sampleRate
        let srResult = try evaluateAudio(
            expr: .index(bundle: "me", indexExpr: .param("sampleRate")),
            sampleRate: 48000
        )
        XCTAssertEqual(srResult, 48000.0, accuracy: 0.001)
    }

    // MARK: - Stereo Output

    func testMonoOutputDuplicatesLeftToRight() throws {
        // When only one strand (left), right should copy left
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .num(0.42))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        let (left, right) = renderFunc(0, 0.0, 44100)

        XCTAssertEqual(left, 0.42, accuracy: 0.001)
        XCTAssertEqual(right, 0.42, accuracy: 0.001, "Mono output should duplicate left to right")
    }

    // MARK: - Nested Expression Evaluation

    func testNestedExpressionEvaluation() throws {
        // sin(cos(0) + abs(-0.5)) = sin(1.0 + 0.5) = sin(1.5)
        let expr = IRExpr.builtin(name: "sin", args: [
            .binaryOp(op: "+",
                left: .builtin(name: "cos", args: [.num(0)]),
                right: .builtin(name: "abs", args: [.num(-0.5)]))
        ])
        let result = try evaluateAudio(expr: expr)
        let expected = sinf(cosf(0) + abs(Float(-0.5)))
        XCTAssertEqual(result, expected, accuracy: 0.001)
    }

    func testDeeplyNestedExpression() throws {
        // ((((1 + 2) * 3) - 4) / 5) = ((3*3)-4)/5 = (9-4)/5 = 5/5 = 1
        let expr = IRExpr.binaryOp(op: "/",
            left: .binaryOp(op: "-",
                left: .binaryOp(op: "*",
                    left: .binaryOp(op: "+", left: .num(1), right: .num(2)),
                    right: .num(3)),
                right: .num(4)),
            right: .num(5))
        let result = try evaluateAudio(expr: expr)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    // MARK: - Spindle Inlining in Audio

    func testSpindleInliningAudio() throws {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .call(spindle: "double", args: [.num(5)]))
                ])
            ],
            spindles: [
                "double": IRSpindle(
                    name: "double",
                    params: ["x"],
                    locals: [],
                    returns: [.binaryOp(op: "*", left: .param("x"), right: .num(2))]
                )
            ],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        let (left, _) = renderFunc(0, 0.0, 44100)
        XCTAssertEqual(left, 10.0, accuracy: 0.001, "double(5) should be 10")
    }

    func testMultiReturnSpindleExtractAudio() throws {
        // swap(a, b) returns [b, a]
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr:
                        .extract(call: .call(spindle: "swap", args: [.num(3), .num(7)]), index: 0)),
                    IRStrand(name: "right", index: 1, expr:
                        .extract(call: .call(spindle: "swap", args: [.num(3), .num(7)]), index: 1))
                ])
            ],
            spindles: [
                "swap": IRSpindle(
                    name: "swap",
                    params: ["a", "b"],
                    locals: [],
                    returns: [.param("b"), .param("a")]
                )
            ],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        let (left, right) = renderFunc(0, 0.0, 44100)

        XCTAssertEqual(left, 7.0, accuracy: 0.001, "swap(3,7).0 should be 7 (b)")
        XCTAssertEqual(right, 3.0, accuracy: 0.001, "swap(3,7).1 should be 3 (a)")
    }

    // MARK: - Noise Determinism

    func testNoiseDeterminism() throws {
        let expr = IRExpr.builtin(name: "noise", args: [.num(1.5), .num(2.5)])

        let result1 = try evaluateAudio(expr: expr)
        let result2 = try evaluateAudio(expr: expr)

        XCTAssertEqual(result1, result2, accuracy: 0.001, "noise() should be deterministic for same inputs")
        XCTAssertGreaterThanOrEqual(result1, 0.0, "noise() should be >= 0")
        XCTAssertLessThan(result1, 1.0, "noise() should be < 1")
    }

    func testNoiseDifferentInputsProduceDifferentValues() throws {
        let result1 = try evaluateAudio(expr: .builtin(name: "noise", args: [.num(1.0), .num(2.0)]))
        let result2 = try evaluateAudio(expr: .builtin(name: "noise", args: [.num(3.0), .num(4.0)]))

        XCTAssertNotEqual(result1, result2, "Different noise inputs should produce different values")
    }

    // MARK: - sample() Builtin Tests

    func testSampleBuiltinAccessesLoadedSamples() throws {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    // sample(resourceId=0, offset=me.i, channel=0)
                    IRStrand(name: "left", index: 0, expr: .builtin(name: "sample", args: [
                        .num(0),
                        .index(bundle: "me", indexExpr: .param("i")),
                        .num(0)
                    ]))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        // Create a simple sample buffer with known data
        let sampleData: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        codegen.loadedSamples[0] = AudioSampleBuffer(
            samples: sampleData,
            channels: 2,
            sampleRate: 44100,
            frameCount: 3  // 3 frames of stereo
        )

        let renderFunc = try codegen.generateRenderFunction()

        // Sample at frame 0, channel 0: should read samples[0] = 0.1
        let (left0, _) = renderFunc(0, 0.0, 44100)
        XCTAssertEqual(left0, 0.1, accuracy: 0.001, "sample(0, 0, 0) should read first frame left channel")

        // Sample at frame 1, channel 0: should read samples[2] = 0.3
        let (left1, _) = renderFunc(1, 0.0, 44100)
        XCTAssertEqual(left1, 0.3, accuracy: 0.001, "sample(0, 1, 0) should read second frame left channel")
    }

    func testSampleBuiltinWithMissingSampleReturnsZero() throws {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .builtin(name: "sample", args: [
                        .num(99),  // non-existent resource ID
                        .num(0),
                        .num(0)
                    ]))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        // Do NOT load any samples
        let renderFunc = try codegen.generateRenderFunction()
        let (left, _) = renderFunc(0, 0.0, 44100)

        XCTAssertEqual(left, 0.0, accuracy: 0.001, "Missing sample should return 0")
    }

    // MARK: - No Play Bundle (Silent) Tests

    func testNoPlayBundleReturnsSilence() throws {
        let program = IRProgram(
            bundles: [
                "display": IRBundle(name: "display", strands: [
                    IRStrand(name: "r", index: 0, expr: .num(1)),
                    IRStrand(name: "g", index: 1, expr: .num(0)),
                    IRStrand(name: "b", index: 2, expr: .num(0))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["display"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        let (left, right) = renderFunc(0, 0.0, 44100)

        XCTAssertEqual(left, 0.0, accuracy: 0.001, "No play bundle should produce silence")
        XCTAssertEqual(right, 0.0, accuracy: 0.001, "No play bundle should produce silence")
    }

    // MARK: - Error Handling

    func testUnknownBuiltinThrowsAudio() throws {
        let expr = IRExpr.builtin(name: "nonexistent_func", args: [.num(1)])
        XCTAssertThrowsError(try evaluateAudio(expr: expr)) { error in
            XCTAssertTrue("\(error)".contains("Unknown builtin"),
                "Should throw error about unknown builtin")
        }
    }

    func testUnknownBinaryOpThrowsAudio() throws {
        let expr = IRExpr.binaryOp(op: "???", left: .num(1), right: .num(2))
        XCTAssertThrowsError(try evaluateAudio(expr: expr)) { error in
            XCTAssertTrue("\(error)".contains("Unknown binary operator"),
                "Should throw error about unknown binary op")
        }
    }

    func testCircularBundleReferenceThrowsAudio() throws {
        let program = IRProgram(
            bundles: [
                "a": IRBundle(name: "a", strands: [
                    IRStrand(name: "val", index: 0, expr: .index(bundle: "b", indexExpr: .param("val")))
                ]),
                "b": IRBundle(name: "b", strands: [
                    IRStrand(name: "val", index: 0, expr: .index(bundle: "a", indexExpr: .param("val")))
                ]),
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .index(bundle: "a", indexExpr: .param("val")))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: Set(program.bundles.keys), isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        XCTAssertThrowsError(try codegen.generateRenderFunction()) { error in
            XCTAssertTrue("\(error)".contains("Circular reference") || "\(error)".contains("too deeply"),
                "Should detect circular reference, got: \(error)")
        }
    }

    // MARK: - Layout Scope Function Tests

    func testLayoutScopeFunctionsGenerateEvaluators() throws {
        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .num(0))
                ]),
                "envelope": IRBundle(name: "envelope", strands: [
                    IRStrand(name: "val", index: 0, expr: .binaryOp(op: "*",
                        left: .num(0.5),
                        right: .index(bundle: "me", indexExpr: .param("t"))))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play", "envelope"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        let results = try codegen.generateLayoutScopeFunctions(bundles: ["envelope"])
        XCTAssertEqual(results.count, 1)

        let (name, fn, strandNames) = results[0]
        XCTAssertEqual(name, "envelope")
        XCTAssertEqual(strandNames, ["val"])

        let values = fn(0, 3.0, 44100)
        XCTAssertEqual(values[0], 1.5, accuracy: 0.001, "0.5 * t at t=3.0 = 1.5")
    }
}


// MARK: - Backend Parity: select() Behavior Tests

final class SelectParityTests: XCTestCase {

    /// Verify Metal and Audio agree on select() behavior at string/numeric level
    func testSelectMetalGeneratesTernaryAudioUsesSwitch() throws {
        // Metal: verify the shader string pattern
        let metalExpr = IRExpr.builtin(name: "select", args: [
            .index(bundle: "me", indexExpr: .param("x")),
            .num(10), .num(20), .num(30)
        ])
        let metalProgram = IRProgram(
            bundles: ["display": IRBundle(name: "display", strands: [
                IRStrand(name: "r", index: 0, expr: metalExpr),
                IRStrand(name: "g", index: 1, expr: .num(0)),
                IRStrand(name: "b", index: 2, expr: .num(0))
            ])],
            spindles: [:], order: [], resources: []
        )
        let metalSwatch = Swatch(backend: "visual", bundles: ["display"], isSink: true)
        let metalCodegen = MetalCodeGen(program: metalProgram, swatch: metalSwatch)
        let shader = try metalCodegen.generate()

        // Metal should NOT call select() as a function
        XCTAssertFalse(shader.contains("select("),
            "Metal should use ternary chains, not function calls")

        // Audio: verify numeric results match expected
        let audioProgram = IRProgram(
            bundles: ["play": IRBundle(name: "play", strands: [
                IRStrand(name: "left", index: 0, expr: .builtin(name: "select", args: [
                    .num(0), .num(10), .num(20), .num(30)
                ]))
            ])],
            spindles: [:], order: [], resources: []
        )
        let audioSwatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let audioCodegen = AudioCodeGen(program: audioProgram, swatch: audioSwatch)
        let renderFunc = try audioCodegen.generateRenderFunction()
        let (left, _) = renderFunc(0, 0.0, 44100)
        XCTAssertEqual(left, 10.0, accuracy: 0.001, "select(0, 10, 20, 30) should be 10")
    }
}


// MARK: - Complex Program Code Generation Tests

final class ComplexProgramCodeGenTests: XCTestCase {

    func testMultiBundleProgramMetalCodeGen() throws {
        // A program with 3 bundles: position -> color -> display
        let program = IRProgram(
            bundles: [
                "pos": IRBundle(name: "pos", strands: [
                    IRStrand(name: "cx", index: 0, expr: .num(0.5)),
                    IRStrand(name: "cy", index: 1, expr: .num(0.5))
                ]),
                "color": IRBundle(name: "color", strands: [
                    IRStrand(name: "val", index: 0, expr: .builtin(name: "sqrt", args: [
                        .binaryOp(op: "+",
                            left: .binaryOp(op: "^",
                                left: .binaryOp(op: "-",
                                    left: .index(bundle: "me", indexExpr: .param("x")),
                                    right: .index(bundle: "pos", indexExpr: .param("cx"))),
                                right: .num(2)),
                            right: .binaryOp(op: "^",
                                left: .binaryOp(op: "-",
                                    left: .index(bundle: "me", indexExpr: .param("y")),
                                    right: .index(bundle: "pos", indexExpr: .param("cy"))),
                                right: .num(2)))
                    ]))
                ]),
                "display": IRBundle(name: "display", strands: [
                    IRStrand(name: "r", index: 0, expr: .index(bundle: "color", indexExpr: .param("val"))),
                    IRStrand(name: "g", index: 1, expr: .index(bundle: "color", indexExpr: .param("val"))),
                    IRStrand(name: "b", index: 2, expr: .index(bundle: "color", indexExpr: .param("val")))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "visual", bundles: Set(program.bundles.keys), isSink: true)
        let codegen = MetalCodeGen(program: program, swatch: swatch)
        let shader = try codegen.generate()

        // Should compile without errors
        XCTAssertTrue(shader.contains("displayKernel"), "Should generate display kernel")
        XCTAssertTrue(shader.contains("sqrt("), "Should contain sqrt from color bundle")
        XCTAssertTrue(shader.contains("pow("), "Should contain pow from ^ operator")
    }

    func testMultiBundleProgramAudioCodeGen() throws {
        // A program with intermediate bundles feeding play
        let program = IRProgram(
            bundles: [
                "freq": IRBundle(name: "freq", strands: [
                    IRStrand(name: "val", index: 0, expr: .num(440))
                ]),
                "osc": IRBundle(name: "osc", strands: [
                    IRStrand(name: "val", index: 0, expr: .builtin(name: "sin", args: [
                        .binaryOp(op: "*",
                            left: .binaryOp(op: "*",
                                left: .num(6.283185),  // 2*pi
                                right: .index(bundle: "freq", indexExpr: .param("val"))),
                            right: .index(bundle: "me", indexExpr: .param("t")))
                    ]))
                ]),
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .binaryOp(op: "*",
                        left: .index(bundle: "osc", indexExpr: .param("val")),
                        right: .num(0.5)))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: Set(program.bundles.keys), isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()

        // At t=0, sin(2*pi*440*0) = 0
        let (left0, _) = renderFunc(0, 0.0, 44100)
        XCTAssertEqual(left0, 0.0, accuracy: 0.01, "At t=0, sine oscillator should be 0")

        // At t=1/(4*440), sin(2*pi*440*t) = sin(pi/2) = 1, output = 0.5
        let quarterPeriod = 1.0 / (4.0 * 440.0)
        let (leftQuarter, _) = renderFunc(0, quarterPeriod, 44100)
        XCTAssertEqual(leftQuarter, 0.5, accuracy: 0.01,
            "At quarter period, oscillator should be 1.0, output = 0.5")
    }

    func testSpindleWithLocalsAudioEvaluation() throws {
        // Spindle with local variables: smooth(a) = { t0.v = max(0,a); return t0.v * t0.v }
        let spindle = IRSpindle(
            name: "smooth",
            params: ["a"],
            locals: [
                IRBundle(name: "t0", strands: [
                    IRStrand(name: "v", index: 0,
                        expr: .builtin(name: "max", args: [.num(0), .param("a")]))
                ])
            ],
            returns: [.binaryOp(op: "*",
                left: .index(bundle: "t0", indexExpr: .param("v")),
                right: .index(bundle: "t0", indexExpr: .param("v")))]
        )

        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .call(spindle: "smooth", args: [.num(3)]))
                ])
            ],
            spindles: ["smooth": spindle],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        let (left, _) = renderFunc(0, 0.0, 44100)

        // smooth(3) = max(0,3) * max(0,3) = 3 * 3 = 9
        XCTAssertEqual(left, 9.0, accuracy: 0.001, "smooth(3) should be 9")
    }

    func testSpindleWithLocalsNegativeInput() throws {
        let spindle = IRSpindle(
            name: "smooth",
            params: ["a"],
            locals: [
                IRBundle(name: "t0", strands: [
                    IRStrand(name: "v", index: 0,
                        expr: .builtin(name: "max", args: [.num(0), .param("a")]))
                ])
            ],
            returns: [.binaryOp(op: "*",
                left: .index(bundle: "t0", indexExpr: .param("v")),
                right: .index(bundle: "t0", indexExpr: .param("v")))]
        )

        let program = IRProgram(
            bundles: [
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .call(spindle: "smooth", args: [.num(-5)]))
                ])
            ],
            spindles: ["smooth": spindle],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        let (left, _) = renderFunc(0, 0.0, 44100)

        // smooth(-5) = max(0,-5) * max(0,-5) = 0 * 0 = 0
        XCTAssertEqual(left, 0.0, accuracy: 0.001, "smooth(-5) should be 0")
    }
}


// MARK: - Remap Expression Tests (Metal)

final class RemapCodeGenTests: XCTestCase {

    func testRemapSubstitutesCoordinates() throws {
        // remap base is a bundle ref, substitutions change me.x and me.y
        let program = IRProgram(
            bundles: [
                "grad": IRBundle(name: "grad", strands: [
                    IRStrand(name: "val", index: 0, expr: .index(bundle: "me", indexExpr: .param("x")))
                ]),
                "display": IRBundle(name: "display", strands: [
                    IRStrand(name: "r", index: 0, expr: .remap(
                        base: .index(bundle: "grad", indexExpr: .param("val")),
                        substitutions: [
                            "me.x": .binaryOp(op: "-", left: .num(1), right: .index(bundle: "me", indexExpr: .param("x")))
                        ]
                    )),
                    IRStrand(name: "g", index: 1, expr: .num(0)),
                    IRStrand(name: "b", index: 2, expr: .num(0))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "visual", bundles: Set(program.bundles.keys), isSink: true)
        let codegen = MetalCodeGen(program: program, swatch: swatch)
        let shader = try codegen.generate()

        // The remap should substitute me.x with (1 - x), so the expression becomes (1-x)
        XCTAssertTrue(shader.contains("(1.0 - x)"), "Remap should substitute x coordinate")
    }

    func testRemapAudioEvaluation() throws {
        // Same remap but evaluated in audio context
        let program = IRProgram(
            bundles: [
                "sig": IRBundle(name: "sig", strands: [
                    IRStrand(name: "val", index: 0, expr: .index(bundle: "me", indexExpr: .param("t")))
                ]),
                "play": IRBundle(name: "play", strands: [
                    IRStrand(name: "left", index: 0, expr: .remap(
                        base: .index(bundle: "sig", indexExpr: .param("val")),
                        substitutions: [
                            "me.t": .binaryOp(op: "*", left: .index(bundle: "me", indexExpr: .param("t")), right: .num(2))
                        ]
                    ))
                ])
            ],
            spindles: [:],
            order: [],
            resources: []
        )
        let swatch = Swatch(backend: "audio", bundles: Set(program.bundles.keys), isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()

        // sig.val = me.t, with remap me.t -> me.t*2
        // At t=1.5: remapped t = 1.5 * 2 = 3.0, result = 3.0
        let (left, _) = renderFunc(0, 1.5, 44100)
        XCTAssertEqual(left, 3.0, accuracy: 0.001, "Remap should double the time coordinate")
    }
}
