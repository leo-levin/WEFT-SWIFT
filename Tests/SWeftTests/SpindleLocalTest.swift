// SpindleLocalTest.swift - Test spindle local variable resolution

import XCTest
@testable import SWeftLib

final class SpindleLocalTest: XCTestCase {

    func testSpindleWithLocals() throws {
        let source = """
        spindle motion_displace(chan, thresh) {
            prev.x = cache(chan, 2, 1, me.t)
            diff.y = chan - prev.x
            return.0 = lerp(0.5, diff.y + 0.5, step(thresh, abs(diff.y)))
        }

        input[r,g,b] = camera(1-me.x, me.y)
        result[r,g,b] = input -> { motion_displace(0..3, 0.07) }

        display[r,g,b] = result
        """

        let compiler = WeftCompiler()

        do {
            let ir = try compiler.compile(source)

            // Verify spindle was created
            XCTAssertNotNil(ir.spindles["motion_displace"])

            let spindle = ir.spindles["motion_displace"]!
            XCTAssertEqual(spindle.params, ["chan", "thresh"])

            // Should have 2 locals: prev and diff
            XCTAssertEqual(spindle.locals.count, 2)

            let localNames = spindle.locals.map { $0.name }
            XCTAssertTrue(localNames.contains("prev"))
            XCTAssertTrue(localNames.contains("diff"))

            // Should have 1 return
            XCTAssertEqual(spindle.returns.count, 1)

            print("SUCCESS: Spindle compiled correctly")
            print("  Locals: \(localNames)")

        } catch {
            XCTFail("Compilation failed: \(error)")
        }
    }

    func testSimpleSpindleLocals() throws {
        let source = """
        spindle test(a) {
            local.x = a + 1
            local2.y = local.x * 2
            return.0 = local2.y
        }

        out.v = test(5)
        """

        let compiler = WeftCompiler()
        let ir = try compiler.compile(source)

        XCTAssertNotNil(ir.spindles["test"])
        let spindle = ir.spindles["test"]!

        XCTAssertEqual(spindle.locals.count, 2)
        print("Simple spindle locals: \(spindle.locals.map { $0.name })")
    }
}
