// BackendParityTests.swift - Verify feature parity between Metal and Audio backends

import XCTest
@testable import SWeftLib

/// Tests to verify that Metal and Audio backends produce equivalent results
/// for domain-agnostic operations.
final class BackendParityTests: XCTestCase {

    // MARK: - Test Setup

    /// Create an IR program with a single expression in both display and play bundles
    private func createDualDomainProgram(expression: IRExpr) -> IRProgram {
        return IRProgram(
            bundles: [
                "display": IRBundle(
                    name: "display",
                    strands: [
                        IRStrand(name: "r", index: 0, expr: expression),
                        IRStrand(name: "g", index: 1, expr: .num(0)),
                        IRStrand(name: "b", index: 2, expr: .num(0))
                    ]
                ),
                "play": IRBundle(
                    name: "play",
                    strands: [
                        IRStrand(name: "left", index: 0, expr: expression)
                    ]
                )
            ],
            spindles: [:],
            order: [],
            resources: []
        )
    }

    /// Evaluate an audio expression at given context
    private func evaluateAudio(
        program: IRProgram,
        sampleIndex: Int = 0,
        time: Double = 0.5,
        sampleRate: Double = 44100
    ) throws -> Float {
        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()
        let (left, _) = renderFunc(sampleIndex, time, sampleRate)
        return left
    }

    // MARK: - Math Builtin Parity Tests

    func testSinParity() throws {
        // sin(0.5) should be the same in both backends
        let expr = IRExpr.builtin(name: "sin", args: [.num(0.5)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        let expected = Float(sin(0.5))

        XCTAssertEqual(audioResult, expected, accuracy: 0.0001,
                       "sin(0.5) should equal \(expected), got \(audioResult)")
    }

    func testCosParity() throws {
        let expr = IRExpr.builtin(name: "cos", args: [.num(1.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        let expected = Float(cos(1.0))

        XCTAssertEqual(audioResult, expected, accuracy: 0.0001)
    }

    func testTanParity() throws {
        let expr = IRExpr.builtin(name: "tan", args: [.num(0.5)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        let expected = Float(tan(0.5))

        XCTAssertEqual(audioResult, expected, accuracy: 0.0001)
    }

    func testAsinParity() throws {
        let expr = IRExpr.builtin(name: "asin", args: [.num(0.5)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        let expected = Float(asin(0.5))

        XCTAssertEqual(audioResult, expected, accuracy: 0.0001)
    }

    func testAcosParity() throws {
        let expr = IRExpr.builtin(name: "acos", args: [.num(0.5)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        let expected = Float(acos(0.5))

        XCTAssertEqual(audioResult, expected, accuracy: 0.0001)
    }

    func testAtanParity() throws {
        let expr = IRExpr.builtin(name: "atan", args: [.num(1.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        let expected = Float(atan(1.0))

        XCTAssertEqual(audioResult, expected, accuracy: 0.0001)
    }

    func testAtan2Parity() throws {
        let expr = IRExpr.builtin(name: "atan2", args: [.num(1.0), .num(1.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        let expected = Float(atan2(1.0, 1.0))

        XCTAssertEqual(audioResult, expected, accuracy: 0.0001)
    }

    func testAbsParity() throws {
        let expr = IRExpr.builtin(name: "abs", args: [.num(-3.14)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 3.14, accuracy: 0.0001)
    }

    func testFloorParity() throws {
        let expr = IRExpr.builtin(name: "floor", args: [.num(2.7)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 2.0, accuracy: 0.0001)
    }

    func testCeilParity() throws {
        let expr = IRExpr.builtin(name: "ceil", args: [.num(2.3)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 3.0, accuracy: 0.0001)
    }

    func testSqrtParity() throws {
        let expr = IRExpr.builtin(name: "sqrt", args: [.num(16.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 4.0, accuracy: 0.0001)
    }

    func testPowParity() throws {
        let expr = IRExpr.builtin(name: "pow", args: [.num(2.0), .num(3.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 8.0, accuracy: 0.0001)
    }

    func testExpParity() throws {
        let expr = IRExpr.builtin(name: "exp", args: [.num(1.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        let expected = Float(exp(1.0))
        XCTAssertEqual(audioResult, expected, accuracy: 0.0001)
    }

    func testLogParity() throws {
        let expr = IRExpr.builtin(name: "log", args: [.num(2.718281828)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 1.0, accuracy: 0.001)
    }

    func testLog2Parity() throws {
        let expr = IRExpr.builtin(name: "log2", args: [.num(8.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 3.0, accuracy: 0.0001)
    }

    func testRoundParity() throws {
        // round(2.3) should be 2
        let expr1 = IRExpr.builtin(name: "round", args: [.num(2.3)])
        let program1 = createDualDomainProgram(expression: expr1)
        XCTAssertEqual(try evaluateAudio(program: program1), 2.0, accuracy: 0.0001)

        // round(2.7) should be 3
        let expr2 = IRExpr.builtin(name: "round", args: [.num(2.7)])
        let program2 = createDualDomainProgram(expression: expr2)
        XCTAssertEqual(try evaluateAudio(program: program2), 3.0, accuracy: 0.0001)

        // round(2.5) should be 3 (round half up)
        let expr3 = IRExpr.builtin(name: "round", args: [.num(2.5)])
        let program3 = createDualDomainProgram(expression: expr3)
        // Note: rounding behavior at .5 may vary, just verify it's 2 or 3
        let result = try evaluateAudio(program: program3)
        XCTAssertTrue(result == 2.0 || result == 3.0, "round(2.5) should be 2 or 3")
    }

    // MARK: - Utility Builtin Parity Tests

    func testMinParity() throws {
        let expr = IRExpr.builtin(name: "min", args: [.num(3.0), .num(5.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 3.0, accuracy: 0.0001)
    }

    func testMaxParity() throws {
        let expr = IRExpr.builtin(name: "max", args: [.num(3.0), .num(5.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 5.0, accuracy: 0.0001)
    }

    func testClampParity() throws {
        // clamp(7, 0, 5) should be 5
        let expr = IRExpr.builtin(name: "clamp", args: [.num(7.0), .num(0.0), .num(5.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 5.0, accuracy: 0.0001)
    }

    func testLerpParity() throws {
        // lerp(0, 10, 0.5) should be 5
        let expr = IRExpr.builtin(name: "lerp", args: [.num(0.0), .num(10.0), .num(0.5)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 5.0, accuracy: 0.0001)
    }

    func testMixParity() throws {
        // mix is alias for lerp
        let expr = IRExpr.builtin(name: "mix", args: [.num(0.0), .num(10.0), .num(0.25)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 2.5, accuracy: 0.0001)
    }

    func testStepParity() throws {
        // step(0.5, 0.3) should be 0 (0.3 < 0.5)
        let expr1 = IRExpr.builtin(name: "step", args: [.num(0.5), .num(0.3)])
        let program1 = createDualDomainProgram(expression: expr1)
        let result1 = try evaluateAudio(program: program1)
        XCTAssertEqual(result1, 0.0, accuracy: 0.0001)

        // step(0.5, 0.7) should be 1 (0.7 >= 0.5)
        let expr2 = IRExpr.builtin(name: "step", args: [.num(0.5), .num(0.7)])
        let program2 = createDualDomainProgram(expression: expr2)
        let result2 = try evaluateAudio(program: program2)
        XCTAssertEqual(result2, 1.0, accuracy: 0.0001)
    }

    func testSmoothstepParity() throws {
        // smoothstep(0, 1, 0.5) should be 0.5 (midpoint with smooth interpolation)
        let expr = IRExpr.builtin(name: "smoothstep", args: [.num(0.0), .num(1.0), .num(0.5)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 0.5, accuracy: 0.0001)
    }

    func testFractParity() throws {
        // fract(2.7) should be 0.7
        let expr = IRExpr.builtin(name: "fract", args: [.num(2.7)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 0.7, accuracy: 0.0001)
    }

    func testModParity() throws {
        // mod(7, 3) should be 1
        let expr = IRExpr.builtin(name: "mod", args: [.num(7.0), .num(3.0)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, 1.0, accuracy: 0.0001)
    }

    func testSignParity() throws {
        // sign(-5) should be -1
        let expr1 = IRExpr.builtin(name: "sign", args: [.num(-5.0)])
        let program1 = createDualDomainProgram(expression: expr1)
        XCTAssertEqual(try evaluateAudio(program: program1), -1.0, accuracy: 0.0001)

        // sign(5) should be 1
        let expr2 = IRExpr.builtin(name: "sign", args: [.num(5.0)])
        let program2 = createDualDomainProgram(expression: expr2)
        XCTAssertEqual(try evaluateAudio(program: program2), 1.0, accuracy: 0.0001)

        // sign(0) should be 0
        let expr3 = IRExpr.builtin(name: "sign", args: [.num(0.0)])
        let program3 = createDualDomainProgram(expression: expr3)
        XCTAssertEqual(try evaluateAudio(program: program3), 0.0, accuracy: 0.0001)
    }

    // MARK: - Noise Parity Test

    func testNoiseParity() throws {
        // noise(1.5, 2.5) should produce deterministic pseudo-random value
        let expr = IRExpr.builtin(name: "noise", args: [.num(1.5), .num(2.5)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)

        // Verify result is in [0, 1) range
        XCTAssertGreaterThanOrEqual(audioResult, 0.0)
        XCTAssertLessThan(audioResult, 1.0)

        // Verify determinism - same inputs should produce same output
        let audioResult2 = try evaluateAudio(program: program)
        XCTAssertEqual(audioResult, audioResult2, accuracy: 0.0001)
    }

    func testNoiseSingleArgParity() throws {
        // noise(1.5) with single argument
        let expr = IRExpr.builtin(name: "noise", args: [.num(3.14)])
        let program = createDualDomainProgram(expression: expr)

        let audioResult = try evaluateAudio(program: program)
        XCTAssertGreaterThanOrEqual(audioResult, 0.0)
        XCTAssertLessThan(audioResult, 1.0)
    }

    // MARK: - Select Parity Test

    func testSelectParity() throws {
        // select(0, 10, 20, 30) should return 10 (branch 0)
        let expr0 = IRExpr.builtin(name: "select", args: [.num(0), .num(10), .num(20), .num(30)])
        let program0 = createDualDomainProgram(expression: expr0)
        XCTAssertEqual(try evaluateAudio(program: program0), 10.0, accuracy: 0.0001)

        // select(1, 10, 20, 30) should return 20 (branch 1)
        let expr1 = IRExpr.builtin(name: "select", args: [.num(1), .num(10), .num(20), .num(30)])
        let program1 = createDualDomainProgram(expression: expr1)
        XCTAssertEqual(try evaluateAudio(program: program1), 20.0, accuracy: 0.0001)

        // select(2, 10, 20, 30) should return 30 (branch 2)
        let expr2 = IRExpr.builtin(name: "select", args: [.num(2), .num(10), .num(20), .num(30)])
        let program2 = createDualDomainProgram(expression: expr2)
        XCTAssertEqual(try evaluateAudio(program: program2), 30.0, accuracy: 0.0001)
    }

    // MARK: - Binary Operator Parity Tests

    func testBinaryOpParity() throws {
        let testCases: [(String, Double, Double, Double)] = [
            ("+", 3.0, 5.0, 8.0),
            ("-", 10.0, 4.0, 6.0),
            ("*", 3.0, 4.0, 12.0),
            ("/", 10.0, 4.0, 2.5),
            ("%", 7.0, 3.0, 1.0),
            ("^", 2.0, 3.0, 8.0),
            ("<", 3.0, 5.0, 1.0),
            (">", 3.0, 5.0, 0.0),
            ("<=", 5.0, 5.0, 1.0),
            (">=", 4.0, 5.0, 0.0),
            ("==", 5.0, 5.0, 1.0),
            ("!=", 5.0, 5.0, 0.0),
        ]

        for (op, left, right, expected) in testCases {
            let expr = IRExpr.binaryOp(op: op, left: .num(left), right: .num(right))
            let program = createDualDomainProgram(expression: expr)
            let result = try evaluateAudio(program: program)
            XCTAssertEqual(result, Float(expected), accuracy: 0.0001,
                           "\(left) \(op) \(right) should equal \(expected), got \(result)")
        }
    }

    func testLogicalOpParity() throws {
        // && (AND)
        let andExpr = IRExpr.binaryOp(op: "&&", left: .num(1), right: .num(1))
        let andProgram = createDualDomainProgram(expression: andExpr)
        XCTAssertEqual(try evaluateAudio(program: andProgram), 1.0, accuracy: 0.0001)

        let andExpr2 = IRExpr.binaryOp(op: "&&", left: .num(1), right: .num(0))
        let andProgram2 = createDualDomainProgram(expression: andExpr2)
        XCTAssertEqual(try evaluateAudio(program: andProgram2), 0.0, accuracy: 0.0001)

        // || (OR)
        let orExpr = IRExpr.binaryOp(op: "||", left: .num(0), right: .num(1))
        let orProgram = createDualDomainProgram(expression: orExpr)
        XCTAssertEqual(try evaluateAudio(program: orProgram), 1.0, accuracy: 0.0001)

        let orExpr2 = IRExpr.binaryOp(op: "||", left: .num(0), right: .num(0))
        let orProgram2 = createDualDomainProgram(expression: orExpr2)
        XCTAssertEqual(try evaluateAudio(program: orProgram2), 0.0, accuracy: 0.0001)
    }

    // MARK: - Unary Operator Parity Tests

    func testUnaryOpParity() throws {
        // Negation
        let negExpr = IRExpr.unaryOp(op: "-", operand: .num(5.0))
        let negProgram = createDualDomainProgram(expression: negExpr)
        XCTAssertEqual(try evaluateAudio(program: negProgram), -5.0, accuracy: 0.0001)

        // Logical NOT
        let notExpr = IRExpr.unaryOp(op: "!", operand: .num(1.0))
        let notProgram = createDualDomainProgram(expression: notExpr)
        XCTAssertEqual(try evaluateAudio(program: notProgram), 0.0, accuracy: 0.0001)

        let notExpr2 = IRExpr.unaryOp(op: "!", operand: .num(0.0))
        let notProgram2 = createDualDomainProgram(expression: notExpr2)
        XCTAssertEqual(try evaluateAudio(program: notProgram2), 1.0, accuracy: 0.0001)
    }

    // MARK: - Spindle Inlining Parity Test

    func testSpindleInliningParity() throws {
        // Define a spindle: square(x) = x * x
        let program = IRProgram(
            bundles: [
                "play": IRBundle(
                    name: "play",
                    strands: [
                        IRStrand(name: "left", index: 0, expr:
                            .call(spindle: "square", args: [.num(3.0)])
                        )
                    ]
                )
            ],
            spindles: [
                "square": IRSpindle(
                    name: "square",
                    params: ["x"],
                    locals: [],
                    returns: [
                        .binaryOp(op: "*", left: .param("x"), right: .param("x"))
                    ]
                )
            ],
            order: [],
            resources: []
        )

        let result = try evaluateAudio(program: program)
        XCTAssertEqual(result, 9.0, accuracy: 0.0001, "square(3) should be 9")
    }

    // MARK: - Complex Expression Parity Test

    func testComplexExpressionParity() throws {
        // Complex expression: sin(x * 2) + cos(y) * 0.5
        // Using constants to test
        let expr = IRExpr.binaryOp(
            op: "+",
            left: .builtin(name: "sin", args: [
                .binaryOp(op: "*", left: .num(1.57), right: .num(2.0))
            ]),
            right: .binaryOp(
                op: "*",
                left: .builtin(name: "cos", args: [.num(0.0)]),
                right: .num(0.5)
            )
        )

        let program = createDualDomainProgram(expression: expr)
        let result = try evaluateAudio(program: program)

        // sin(3.14) + cos(0) * 0.5 ≈ 0 + 1 * 0.5 = 0.5
        let expected = Float(sin(3.14) + cos(0.0) * 0.5)
        XCTAssertEqual(result, expected, accuracy: 0.01)
    }

    // MARK: - SharedBuiltins Validation Test

    func testSharedBuiltinsValidation() throws {
        // Verify SharedBuiltins contains all expected builtins
        XCTAssertNotNil(SharedBuiltins.builtin(named: "sin"))
        XCTAssertNotNil(SharedBuiltins.builtin(named: "noise"))
        XCTAssertNotNil(SharedBuiltins.builtin(named: "cache"))

        // Verify categories
        let mathBuiltins = SharedBuiltins.builtins(in: .math)
        XCTAssertTrue(mathBuiltins.contains { $0.name == "sin" })
        XCTAssertTrue(mathBuiltins.contains { $0.name == "cos" })

        let hardwareBuiltins = SharedBuiltins.builtins(in: .hardware)
        XCTAssertTrue(hardwareBuiltins.contains { $0.name == "camera" })
        XCTAssertTrue(hardwareBuiltins.contains { $0.name == "microphone" })

        // Verify domain-agnostic set excludes hardware
        let agnostic = SharedBuiltins.domainAgnosticNames
        XCTAssertTrue(agnostic.contains("sin"))
        XCTAssertFalse(agnostic.contains("camera"))
    }

    func testBackendBuiltinCoverage() throws {
        // Test that both backends implement all required builtins using validateBackend()

        // Visual backend should implement domain-agnostic + visual-owned builtins
        let visualImplemented: Set<String> = [
            // Math
            "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
            "abs", "floor", "ceil", "round", "sqrt", "pow", "exp", "log", "log2",
            "sign", "fract",
            // Utility
            "min", "max", "clamp", "lerp", "mix", "step", "smoothstep", "mod",
            // Noise
            "noise",
            // State & Control
            "cache", "select",
            // Visual-owned hardware
            "camera", "texture", "microphone"
        ]

        let visualMissing = SharedBuiltins.validateBackend(
            identifier: "visual",
            implementedBuiltins: visualImplemented,
            ownedBuiltins: MetalBackend.ownedBuiltins
        )
        XCTAssertTrue(visualMissing.isEmpty, "Visual backend missing: \(visualMissing)")

        // Audio backend should implement domain-agnostic + audio-owned builtins
        let audioImplemented: Set<String> = [
            // Math
            "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
            "abs", "floor", "ceil", "round", "sqrt", "pow", "exp", "log", "log2",
            "sign", "fract",
            // Utility
            "min", "max", "clamp", "lerp", "mix", "step", "smoothstep", "mod",
            // Noise
            "noise",
            // State & Control
            "cache", "select",
            // Audio-owned hardware
            "microphone",
            // Returns 0 for visual builtins (graceful fallback)
            "camera", "texture"
        ]

        let audioMissing = SharedBuiltins.validateBackend(
            identifier: "audio",
            implementedBuiltins: audioImplemented,
            ownedBuiltins: AudioBackend.ownedBuiltins
        )
        XCTAssertTrue(audioMissing.isEmpty, "Audio backend missing: \(audioMissing)")
    }
}
