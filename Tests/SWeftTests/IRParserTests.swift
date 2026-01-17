// IRParserTests.swift - Tests for IR parsing

import XCTest
@testable import SWeftLib

final class IRParserTests: XCTestCase {

    func testParseSimpleGradient() throws {
        let json = """
        {
            "bundles": {
                "display": {
                    "name": "display",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {"type": "index", "bundle": "me", "field": "x"}},
                        {"name": "g", "index": 1, "expr": {"type": "index", "bundle": "me", "field": "y"}},
                        {"name": "b", "index": 2, "expr": {"type": "num", "value": 0.5}}
                    ]
                }
            },
            "spindles": {},
            "order": [{"bundle": "display"}],
            "resources": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)

        XCTAssertEqual(program.bundles.count, 1)
        XCTAssertNotNil(program.bundles["display"])

        let display = program.bundles["display"]!
        XCTAssertEqual(display.strands.count, 3)
        XCTAssertEqual(display.strands[0].name, "r")
        XCTAssertEqual(display.strands[1].name, "g")
        XCTAssertEqual(display.strands[2].name, "b")
    }

    func testParseBinaryOp() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "a", "index": 0, "expr": {
                            "type": "binary",
                            "op": "+",
                            "left": {"type": "num", "value": 1.0},
                            "right": {"type": "num", "value": 2.0}
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": [],
            "resources": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)

        let strand = program.bundles["test"]!.strands[0]
        if case .binaryOp(let op, let left, let right) = strand.expr {
            XCTAssertEqual(op, "+")
            if case .num(let l) = left {
                XCTAssertEqual(l, 1.0)
            } else {
                XCTFail("Expected num for left")
            }
            if case .num(let r) = right {
                XCTAssertEqual(r, 2.0)
            } else {
                XCTFail("Expected num for right")
            }
        } else {
            XCTFail("Expected binary op")
        }
    }

    func testParseBuiltin() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "a", "index": 0, "expr": {
                            "type": "builtin",
                            "name": "sin",
                            "args": [{"type": "num", "value": 3.14159}]
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": [],
            "resources": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)

        let strand = program.bundles["test"]!.strands[0]
        if case .builtin(let name, let args) = strand.expr {
            XCTAssertEqual(name, "sin")
            XCTAssertEqual(args.count, 1)
        } else {
            XCTFail("Expected builtin")
        }
    }
}
