// ParserTests.swift - Tests for the Swift WEFT parser

import XCTest
@testable import SWeftLib

final class ParserTests: XCTestCase {

    // MARK: - Tokenizer Tests

    func testTokenizeSimple() throws {
        let source = "display[r, g, b] = me.x"
        let tokenizer = WeftTokenizer(source: source)
        let tokens = try tokenizer.tokenize()

        // Should have: identifier, [, identifier, comma, identifier, comma, identifier, ], =, identifier, ., identifier, eof
        XCTAssertEqual(tokens.count, 13)
        XCTAssertEqual(tokens[0].token, .identifier("display"))
        XCTAssertEqual(tokens[1].token, .leftBracket)
        XCTAssertEqual(tokens[2].token, .identifier("r"))
        XCTAssertEqual(tokens[11].token, .identifier("x"))
        XCTAssertEqual(tokens[12].token, .eof)
    }

    func testTokenizeRange() throws {
        let source = "0..3"
        let tokenizer = WeftTokenizer(source: source)
        let tokens = try tokenizer.tokenize()

        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[0].token, .number(0))
        XCTAssertEqual(tokens[1].token, .dotDot)
        XCTAssertEqual(tokens[2].token, .number(3))
    }

    func testTokenizeOperators() throws {
        let source = "+ - * / ^ % == != < > <= >= && || !"
        let tokenizer = WeftTokenizer(source: source)
        let tokens = try tokenizer.tokenize()

        let expected: [Token] = [
            .plus, .minus, .star, .slash, .caret, .percent,
            .equalEqual, .bangEqual, .less, .greater, .lessEqual, .greaterEqual,
            .ampAmp, .pipePipe, .bang, .eof
        ]

        XCTAssertEqual(tokens.count, expected.count)
        for (i, token) in tokens.enumerated() {
            XCTAssertEqual(token.token, expected[i], "Token at index \(i) mismatch")
        }
    }

    func testTokenizeString() throws {
        let source = "\"hello world\""
        let tokenizer = WeftTokenizer(source: source)
        let tokens = try tokenizer.tokenize()

        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].token, .string("hello world"))
    }

    func testTokenizeArrow() throws {
        let source = "a -> {b}"
        let tokenizer = WeftTokenizer(source: source)
        let tokens = try tokenizer.tokenize()

        XCTAssertEqual(tokens.count, 6)
        XCTAssertEqual(tokens[1].token, .arrow)
        XCTAssertEqual(tokens[2].token, .leftBrace)
        XCTAssertEqual(tokens[4].token, .rightBrace)
    }

    // MARK: - Parser Tests

    func testParseBundleDecl() throws {
        let source = "display[r, g, b] = me.x"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        XCTAssertEqual(program.statements.count, 1)

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        XCTAssertEqual(decl.name, "display")
        XCTAssertEqual(decl.outputs.count, 3)
        XCTAssertEqual(decl.outputs[0], .name("r"))
        XCTAssertEqual(decl.outputs[1], .name("g"))
        XCTAssertEqual(decl.outputs[2], .name("b"))

        guard case .strandAccess(let access) = decl.expr else {
            XCTFail("Expected strand access")
            return
        }

        XCTAssertEqual(access.bundle, .named("me"))
        XCTAssertEqual(access.accessor, .name("x"))
    }

    func testParseBundleDeclShorthand() throws {
        let source = "brightness.val = 0.5"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        XCTAssertEqual(program.statements.count, 1)

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        XCTAssertEqual(decl.name, "brightness")
        XCTAssertEqual(decl.outputs, [.name("val")])
    }

    func testParseSpindleDef() throws {
        let source = """
        spindle add(a, b) {
            return.0 = a + b
        }
        """
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        XCTAssertEqual(program.statements.count, 1)

        guard case .spindleDef(let def) = program.statements[0] else {
            XCTFail("Expected spindle definition")
            return
        }

        XCTAssertEqual(def.name, "add")
        XCTAssertEqual(def.params, ["a", "b"])
        XCTAssertEqual(def.body.count, 1)

        guard case .returnAssign(let ret) = def.body[0] else {
            XCTFail("Expected return assign")
            return
        }

        XCTAssertEqual(ret.index, 0)
    }

    func testParseBinaryOp() throws {
        let source = "a.v = 1 + 2 * 3"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        // Should be (1 + (2 * 3)) due to precedence
        guard case .binaryOp(let op) = decl.expr else {
            XCTFail("Expected binary op")
            return
        }

        XCTAssertEqual(op.op, .add)

        guard case .number(1) = op.left else {
            XCTFail("Expected number 1")
            return
        }

        guard case .binaryOp(let inner) = op.right else {
            XCTFail("Expected inner binary op")
            return
        }

        XCTAssertEqual(inner.op, .multiply)
    }

    func testParseSpindleCall() throws {
        let source = "a.v = sin(me.x)"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .spindleCall(let call) = decl.expr else {
            XCTFail("Expected spindle call")
            return
        }

        XCTAssertEqual(call.name, "sin")
        XCTAssertEqual(call.args.count, 1)
    }

    func testParseChainExpr() throws {
        let source = "img[r,g,b] = camera(me.x, me.y) -> {.0, .1, .2}"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .chainExpr(let chain) = decl.expr else {
            XCTFail("Expected chain expression")
            return
        }

        XCTAssertEqual(chain.patterns.count, 1)
        XCTAssertEqual(chain.patterns[0].outputs.count, 3)
    }

    func testParseRangeExpr() throws {
        let source = "a[0,1,2] = [1,2,3] -> {0..3 * 0.5}"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .chainExpr(let chain) = decl.expr else {
            XCTFail("Expected chain expression")
            return
        }

        // The pattern output should contain a binary op with a range
        let output = chain.patterns[0].outputs[0]
        guard case .binaryOp(let op) = output.value else {
            XCTFail("Expected binary op in pattern")
            return
        }

        guard case .rangeExpr(let range) = op.left else {
            XCTFail("Expected range expression")
            return
        }

        XCTAssertEqual(range.start, 0)
        XCTAssertEqual(range.end, 3)
    }

    func testParseUnaryOp() throws {
        let source = "a.v = -b.v"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .unaryOp(let op) = decl.expr else {
            XCTFail("Expected unary op")
            return
        }

        XCTAssertEqual(op.op, .negate)
    }

    func testParseBundleLit() throws {
        let source = "a[r,g,b] = [1, 2, 3]"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .bundleLit(let elements) = decl.expr else {
            XCTFail("Expected bundle literal")
            return
        }

        XCTAssertEqual(elements.count, 3)
    }

    func testParseComplexProgram() throws {
        let source = """
        // Animated gradient
        display[r, g, b] = me.x

        // Circle generator
        spindle circle(cx, cy, radius) {
            return.0 = step(radius, sqrt((me.x - cx)^2 + (me.y - cy)^2))
        }

        // Using the circle
        mask.v = circle(0.5, 0.5, 0.3)
        """

        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        XCTAssertEqual(program.statements.count, 3)

        guard case .bundleDecl = program.statements[0] else {
            XCTFail("Expected bundle declaration at index 0")
            return
        }

        guard case .spindleDef(let def) = program.statements[1] else {
            XCTFail("Expected spindle definition at index 1")
            return
        }
        XCTAssertEqual(def.name, "circle")
        XCTAssertEqual(def.params, ["cx", "cy", "radius"])

        guard case .bundleDecl(let maskDecl) = program.statements[2] else {
            XCTFail("Expected bundle declaration at index 2")
            return
        }
        XCTAssertEqual(maskDecl.name, "mask")
    }

    func testParseIndexedStrandAccess() throws {
        let source = "a.v = b.0"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .strandAccess(let access) = decl.expr else {
            XCTFail("Expected strand access")
            return
        }

        XCTAssertEqual(access.bundle, .named("b"))
        XCTAssertEqual(access.accessor, .index(0))
    }

    func testParseBareStrandAccess() throws {
        let source = "a[r,g,b] = [1,2,3] -> {.0, .1, .2}"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .chainExpr(let chain) = decl.expr else {
            XCTFail("Expected chain expression")
            return
        }

        // First output should be .0 (bare strand access)
        guard case .strandAccess(let access) = chain.patterns[0].outputs[0].value else {
            XCTFail("Expected strand access")
            return
        }

        XCTAssertNil(access.bundle)
        XCTAssertEqual(access.accessor, .index(0))
    }

    func testParseExponentiation() throws {
        let source = "a.v = 2^3^4"  // Should be 2^(3^4) - right associative
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .binaryOp(let op) = decl.expr else {
            XCTFail("Expected binary op")
            return
        }

        XCTAssertEqual(op.op, .power)

        // Left should be 2
        guard case .number(2) = op.left else {
            XCTFail("Expected number 2")
            return
        }

        // Right should be 3^4
        guard case .binaryOp(let inner) = op.right else {
            XCTFail("Expected inner binary op for right associativity")
            return
        }

        XCTAssertEqual(inner.op, .power)
    }

    // MARK: - Lowering Tests

    func testLowerSimpleBundleDecl() throws {
        let source = "display[r, g, b] = [me.x, me.y, 0.5]"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        XCTAssertEqual(ir.bundles.count, 1)
        XCTAssertNotNil(ir.bundles["display"])

        let display = ir.bundles["display"]!
        XCTAssertEqual(display.strands.count, 3)
        XCTAssertEqual(display.strands[0].name, "r")
        XCTAssertEqual(display.strands[1].name, "g")
        XCTAssertEqual(display.strands[2].name, "b")

        // Check expressions
        if case .index(let bundle, _) = display.strands[0].expr {
            XCTAssertEqual(bundle, "me")
        } else {
            XCTFail("Expected index expression for strand r")
        }

        if case .num(0.5) = display.strands[2].expr {
            // OK
        } else {
            XCTFail("Expected num(0.5) for strand b")
        }
    }

    func testLowerSpindleDef() throws {
        let source = """
        spindle add(a, b) {
            return.0 = a + b
        }
        """
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        XCTAssertEqual(ir.spindles.count, 1)
        XCTAssertNotNil(ir.spindles["add"])

        let add = ir.spindles["add"]!
        XCTAssertEqual(add.params, ["a", "b"])
        XCTAssertEqual(add.returns.count, 1)

        // Check the return expression is a + b
        if case .binaryOp(let op, let left, let right) = add.returns[0] {
            XCTAssertEqual(op, "+")
            if case .param(let name) = left {
                XCTAssertEqual(name, "a")
            } else {
                XCTFail("Expected param 'a'")
            }
            if case .param(let name) = right {
                XCTAssertEqual(name, "b")
            } else {
                XCTFail("Expected param 'b'")
            }
        } else {
            XCTFail("Expected binary op expression")
        }
    }

    func testLowerSpindleCall() throws {
        let source = "a.v = sin(me.x)"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        let a = ir.bundles["a"]!
        if case .builtin(let name, let args) = a.strands[0].expr {
            XCTAssertEqual(name, "sin")
            XCTAssertEqual(args.count, 1)
        } else {
            XCTFail("Expected builtin call")
        }
    }

    func testLowerChainExpr() throws {
        let source = "a[r,g,b] = [1, 2, 3] -> {.0 * 0.5, .1 * 0.5, .2 * 0.5}"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        let a = ir.bundles["a"]!
        XCTAssertEqual(a.strands.count, 3)

        // Each strand should be (input * 0.5)
        for strand in a.strands {
            if case .binaryOp(let op, _, let right) = strand.expr {
                XCTAssertEqual(op, "*")
                if case .num(0.5) = right {
                    // OK
                } else {
                    XCTFail("Expected 0.5")
                }
            } else {
                XCTFail("Expected binary op")
            }
        }
    }

    func testLowerRangeExpr() throws {
        let source = "a[r,g,b] = [1, 2, 3] -> {0..3 * 0.5}"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        let a = ir.bundles["a"]!
        XCTAssertEqual(a.strands.count, 3)

        // Range should expand to 3 outputs, each (input * 0.5)
        for (i, strand) in a.strands.enumerated() {
            if case .binaryOp(let op, let left, let right) = strand.expr {
                XCTAssertEqual(op, "*")
                if case .num(0.5) = right {
                    // OK
                } else {
                    XCTFail("Expected 0.5")
                }
                // Left should reference the i-th input
                if case .num(let n) = left {
                    XCTAssertEqual(Int(n), i + 1)
                } else {
                    XCTFail("Expected num for input reference at index \(i)")
                }
            } else {
                XCTFail("Expected binary op for strand \(i)")
            }
        }
    }

    func testLowerCamera() throws {
        let source = "img[r,g,b] = camera(me.x, me.y)"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        let img = ir.bundles["img"]!
        XCTAssertEqual(img.strands.count, 3)

        // Each strand should be camera(u, v, channel)
        for (i, strand) in img.strands.enumerated() {
            if case .builtin(let name, let args) = strand.expr {
                XCTAssertEqual(name, "camera")
                XCTAssertEqual(args.count, 3)
                if case .num(let channel) = args[2] {
                    XCTAssertEqual(Int(channel), i)
                } else {
                    XCTFail("Expected channel number")
                }
            } else {
                XCTFail("Expected builtin call")
            }
        }
    }

    func testLowerCompleteProgram() throws {
        let source = """
        // Gradient display
        display[r, g, b] = [me.x, me.y, fract(me.t)]
        """
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        // Should match gradient.json structure
        XCTAssertEqual(ir.bundles.count, 1)
        XCTAssertNotNil(ir.bundles["display"])

        let display = ir.bundles["display"]!
        XCTAssertEqual(display.strands.count, 3)

        // r = me.x
        if case .index(let bundle, let indexExpr) = display.strands[0].expr {
            XCTAssertEqual(bundle, "me")
            if case .param(let field) = indexExpr {
                XCTAssertEqual(field, "x")
            }
        }

        // b = fract(me.t)
        if case .builtin(let name, _) = display.strands[2].expr {
            XCTAssertEqual(name, "fract")
        }
    }

    func testTopologicalSort() throws {
        let source = """
        a.v = 1
        b.v = a.v + 1
        c.v = b.v + 1
        """
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        // Order should be a, b, c
        XCTAssertEqual(ir.order.count, 3)
        XCTAssertEqual(ir.order[0].bundle, "a")
        XCTAssertEqual(ir.order[1].bundle, "b")
        XCTAssertEqual(ir.order[2].bundle, "c")
    }

    // MARK: - Inferred Width Bundle Tests

    func testParseInferredWidthBundle() throws {
        let source = "nums = [1, 2, 3]"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        XCTAssertEqual(program.statements.count, 1)

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        XCTAssertEqual(decl.name, "nums")
        XCTAssertEqual(decl.outputs, [])  // Empty outputs signals inference

        guard case .bundleLit(let elements) = decl.expr else {
            XCTFail("Expected bundle literal")
            return
        }
        XCTAssertEqual(elements.count, 3)
    }

    func testLowerInferredWidthBundleLiteral() throws {
        let source = """
        nums = [1, 2, 3]
        result.v = nums.0 + nums.1 + nums.2
        """
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        // Verify nums has 3 strands named "0", "1", "2"
        let nums = ir.bundles["nums"]!
        XCTAssertEqual(nums.strands.count, 3)
        XCTAssertEqual(nums.strands[0].name, "0")
        XCTAssertEqual(nums.strands[1].name, "1")
        XCTAssertEqual(nums.strands[2].name, "2")

        // Verify values
        if case .num(1) = nums.strands[0].expr {} else {
            XCTFail("Expected num(1) for strand 0")
        }
        if case .num(2) = nums.strands[1].expr {} else {
            XCTFail("Expected num(2) for strand 1")
        }
        if case .num(3) = nums.strands[2].expr {} else {
            XCTFail("Expected num(3) for strand 2")
        }
    }

    func testLowerInferredWidthSingleValue() throws {
        let source = "x = 42"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        // Verify x has 1 strand named "0"
        let x = ir.bundles["x"]!
        XCTAssertEqual(x.strands.count, 1)
        XCTAssertEqual(x.strands[0].name, "0")

        if case .num(42) = x.strands[0].expr {} else {
            XCTFail("Expected num(42)")
        }
    }

    func testLowerInferredWidthResourceBuiltin() throws {
        let source = "snd = sample(\"test.wav\")"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        // Verify snd has 2 strands (stereo audio)
        let snd = ir.bundles["snd"]!
        XCTAssertEqual(snd.strands.count, 2)
        XCTAssertEqual(snd.strands[0].name, "0")
        XCTAssertEqual(snd.strands[1].name, "1")
    }

    func testLowerInferredWidthCamera() throws {
        let source = "img = camera(me.x, me.y)"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        let lowering = WeftLowering()
        let ir = try lowering.lower(program)

        // Verify img has 3 strands (RGB)
        let img = ir.bundles["img"]!
        XCTAssertEqual(img.strands.count, 3)
        XCTAssertEqual(img.strands[0].name, "0")
        XCTAssertEqual(img.strands[1].name, "1")
        XCTAssertEqual(img.strands[2].name, "2")
    }

    // MARK: - Tag Expression Tests

    func testTokenizeDollarIdentifier() throws {
        let source = "$speed"
        let tokenizer = WeftTokenizer(source: source)
        let tokens = try tokenizer.tokenize()

        XCTAssertEqual(tokens.count, 2)  // $speed + eof
        XCTAssertEqual(tokens[0].token, .identifier("$speed"))
        XCTAssertEqual(tokens[0].text, "$speed")
    }

    func testTokenizeDollarIdentifierInContext() throws {
        let source = "foo * $speed + bar"
        let tokenizer = WeftTokenizer(source: source)
        let tokens = try tokenizer.tokenize()

        // foo, *, $speed, +, bar, eof
        XCTAssertEqual(tokens.count, 6)
        XCTAssertEqual(tokens[0].token, .identifier("foo"))
        XCTAssertEqual(tokens[1].token, .star)
        XCTAssertEqual(tokens[2].token, .identifier("$speed"))
        XCTAssertEqual(tokens[3].token, .plus)
        XCTAssertEqual(tokens[4].token, .identifier("bar"))
    }

    func testParseTagDefinition() throws {
        let source = "bar[x] = $speed(12)"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .tagExpr(let tag) = decl.expr else {
            XCTFail("Expected tag expression, got \(decl.expr)")
            return
        }

        XCTAssertEqual(tag.name, "$speed")
        guard case .number(12) = tag.expr else {
            XCTFail("Expected number 12 inside tag")
            return
        }
    }

    func testParseBareTagReference() throws {
        let source = "bar[x] = $speed"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .identifier(let name) = decl.expr else {
            XCTFail("Expected identifier, got \(decl.expr)")
            return
        }

        XCTAssertEqual(name, "$speed")
    }

    func testParseTagInRemap() throws {
        let source = "a.v = b.v($speed ~ 20)"
        let parser = try WeftParser(source: source)
        let program = try parser.parse()

        guard case .bundleDecl(let decl) = program.statements[0] else {
            XCTFail("Expected bundle declaration")
            return
        }

        guard case .remapExpr(let remap) = decl.expr else {
            XCTFail("Expected remap expression, got \(decl.expr)")
            return
        }

        XCTAssertEqual(remap.remappings.count, 1)
        // $speed shorthand should desugar to $speed.0
        XCTAssertEqual(remap.remappings[0].domain.bundle, .named("$speed"))
        XCTAssertEqual(remap.remappings[0].domain.accessor, .index(0))
    }

    func testDesugarTagExpressions() throws {
        let source = """
        a.v = 1.0
        bar[x] = a.v * $speed(12) + $speed
        """
        let parser = try WeftParser(source: source)
        let ast = try parser.parse()

        let desugar = WeftDesugar()
        let desugared = desugar.desugar(ast)

        // Should have 3 statements: synthetic $speed bundle + 2 originals
        XCTAssertEqual(desugared.statements.count, 3)

        // First statement should be synthetic $speed[0] = 12
        guard case .bundleDecl(let syntheticDecl) = desugared.statements[0] else {
            XCTFail("Expected synthetic bundle declaration")
            return
        }
        XCTAssertEqual(syntheticDecl.name, "$speed")
        XCTAssertEqual(syntheticDecl.outputs, [.index(0)])
        guard case .number(12) = syntheticDecl.expr else {
            XCTFail("Expected number 12 in synthetic bundle")
            return
        }

        // Third statement (bar) should have tag references rewritten to strand access
        guard case .bundleDecl(let barDecl) = desugared.statements[2] else {
            XCTFail("Expected bar bundle declaration")
            return
        }
        XCTAssertEqual(barDecl.name, "bar")

        // The expression should be a.v * $speed.0 + $speed.0
        // (binaryOp: add of (binaryOp: mul of a.v, $speed.0) and $speed.0)
        guard case .binaryOp(let addOp) = barDecl.expr else {
            XCTFail("Expected binary op at top level, got \(barDecl.expr)")
            return
        }
        XCTAssertEqual(addOp.op, .add)

        // Right side should be $speed.0
        guard case .strandAccess(let rightAccess) = addOp.right else {
            XCTFail("Expected strand access for bare $speed, got \(addOp.right)")
            return
        }
        XCTAssertEqual(rightAccess.bundle, .named("$speed"))
        XCTAssertEqual(rightAccess.accessor, .index(0))
    }

    func testEndToEndTagCompilation() throws {
        let source = """
        a.v = 1.0
        bar[x] = a.v * $speed(12) + $speed
        display[r,g,b] = [bar.x, bar.x, bar.x]
        """
        let parser = try WeftParser(source: source)
        let ast = try parser.parse()

        let desugar = WeftDesugar()
        let desugared = desugar.desugar(ast)

        let lowering = WeftLowering()
        let ir = try lowering.lower(desugared)

        // Should have bundles: $speed, a, bar, display
        XCTAssertNotNil(ir.bundles["$speed"])
        XCTAssertNotNil(ir.bundles["a"])
        XCTAssertNotNil(ir.bundles["bar"])
        XCTAssertNotNil(ir.bundles["display"])

        // $speed should have 1 strand with value 12
        let speed = ir.bundles["$speed"]!
        XCTAssertEqual(speed.strands.count, 1)
        if case .num(12) = speed.strands[0].expr {
            // OK
        } else {
            XCTFail("Expected num(12) for $speed strand, got \(speed.strands[0].expr)")
        }

        // bar should reference $speed
        let bar = ir.bundles["bar"]!
        XCTAssertEqual(bar.strands.count, 1)
    }

    func testEndToEndTagViaCompiler() throws {
        let compiler = WeftCompiler()
        let source = """
        bar[x] = sin(me.x * $freq(5.0)) * $amp(0.5)
        display[r,g,b] = [bar.x, bar.x, bar.x]
        """
        let ir = try compiler.compile(source)

        // Should have $amp, $freq, bar, display bundles
        XCTAssertNotNil(ir.bundles["$amp"])
        XCTAssertNotNil(ir.bundles["$freq"])
        XCTAssertNotNil(ir.bundles["bar"])
        XCTAssertNotNil(ir.bundles["display"])

        // $freq should have value 5.0
        let freq = ir.bundles["$freq"]!
        XCTAssertEqual(freq.strands.count, 1)
        if case .num(5.0) = freq.strands[0].expr {} else {
            XCTFail("Expected num(5.0) for $freq")
        }

        // $amp should have value 0.5
        let amp = ir.bundles["$amp"]!
        XCTAssertEqual(amp.strands.count, 1)
        if case .num(0.5) = amp.strands[0].expr {} else {
            XCTFail("Expected num(0.5) for $amp")
        }
    }
}
