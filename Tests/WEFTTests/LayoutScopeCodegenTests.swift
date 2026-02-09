// LayoutScopeCodegenTests.swift - Tests for layout preview scope codegen

import XCTest
@testable import WEFTLib

final class LayoutScopeCodegenTests: XCTestCase {

    // MARK: - Helper

    /// Create a minimal IR program with display + one intermediate bundle
    private func makeProgram(
        intermediates: [String: [(name: String, expr: IRExpr)]],
        display: [(name: String, expr: IRExpr)]
    ) -> (IRProgram, Swatch) {
        var bundles: [String: IRBundle] = [:]

        for (bundleName, strands) in intermediates {
            let irStrands = strands.enumerated().map { (i, s) in
                IRStrand(name: s.name, index: i, expr: s.expr)
            }
            bundles[bundleName] = IRBundle(name: bundleName, strands: irStrands)
        }

        let displayStrands = display.enumerated().map { (i, s) in
            IRStrand(name: s.name, index: i, expr: s.expr)
        }
        bundles["display"] = IRBundle(name: "display", strands: displayStrands)

        let program = IRProgram(
            bundles: bundles,
            spindles: [:],
            order: [],
            resources: []
        )

        let allBundleNames = Set(bundles.keys)
        let swatch = Swatch(backend: "visual", bundles: allBundleNames, isSink: true)

        return (program, swatch)
    }

    // MARK: - Tests

    func testScopeVariablesPresent() throws {
        // Bundle "a" with one strand val = me.x + me.y
        // display references a.val
        let aExpr: IRExpr = .binaryOp(op: "+", left: .index(bundle: "me", indexExpr: .param("x")), right: .index(bundle: "me", indexExpr: .param("y")))
        let (program, swatch) = makeProgram(
            intermediates: ["a": [(name: "val", expr: aExpr)]],
            display: [(name: "r", expr: .index(bundle: "a", indexExpr: .param("val"))),
                      (name: "g", expr: .num(0)),
                      (name: "b", expr: .num(0))]
        )

        let codegen = MetalCodeGen(program: program, swatch: swatch, scopedBundles: ["a"])
        let shader = try codegen.generate()

        // Scope variable assignment should be present
        XCTAssertTrue(shader.contains("float scope_a_val ="), "Scope variable assignment for a.val should be present")
        // Scope texture write should be present
        XCTAssertTrue(shader.contains("scopeTex0.write("), "Scope texture write should be present")
    }

    func testCSEReferencesVariable() throws {
        // Bundle "a" with one strand val = sin(me.x)
        // display references a.val -> should use scope_a_val instead of re-inlining
        let aExpr: IRExpr = .builtin(name: "sin", args: [.index(bundle: "me", indexExpr: .param("x"))])
        let (program, swatch) = makeProgram(
            intermediates: ["a": [(name: "val", expr: aExpr)]],
            display: [(name: "r", expr: .index(bundle: "a", indexExpr: .param("val"))),
                      (name: "g", expr: .num(0)),
                      (name: "b", expr: .num(0))]
        )

        let codegen = MetalCodeGen(program: program, swatch: swatch, scopedBundles: ["a"])
        let shader = try codegen.generate()

        // The display color expression should reference the scope variable, not re-inline sin(x)
        // Check that "float r = scope_a_val" appears (CSE)
        XCTAssertTrue(shader.contains("float r = scope_a_val"), "Display should reference scope variable via CSE, got:\n\(shader)")
    }

    func testWithoutScopedBundlesRegression() throws {
        // Same program but no scoped bundles -> shader should NOT contain scope vars
        let aExpr: IRExpr = .binaryOp(op: "+", left: .index(bundle: "me", indexExpr: .param("x")), right: .index(bundle: "me", indexExpr: .param("y")))
        let (program, swatch) = makeProgram(
            intermediates: ["a": [(name: "val", expr: aExpr)]],
            display: [(name: "r", expr: .index(bundle: "a", indexExpr: .param("val"))),
                      (name: "g", expr: .num(0)),
                      (name: "b", expr: .num(0))]
        )

        let codegen = MetalCodeGen(program: program, swatch: swatch)
        let shader = try codegen.generate()

        // No scope variables or textures should be present
        XCTAssertFalse(shader.contains("scope_"), "No scope variables should be present without scoped bundles")
        XCTAssertFalse(shader.contains("scopeTex"), "No scope textures should be present without scoped bundles")
    }

    func testTopologicalOrdering() throws {
        // Bundle "b" depends on "a": b.val = a.val * 2
        // Both are scoped. "a" should appear before "b" in the preamble.
        let aExpr: IRExpr = .index(bundle: "me", indexExpr: .param("x"))
        let bExpr: IRExpr = .binaryOp(op: "*", left: .index(bundle: "a", indexExpr: .param("val")), right: .num(2))
        let (program, swatch) = makeProgram(
            intermediates: [
                "a": [(name: "val", expr: aExpr)],
                "b": [(name: "val", expr: bExpr)]
            ],
            display: [(name: "r", expr: .index(bundle: "b", indexExpr: .param("val"))),
                      (name: "g", expr: .num(0)),
                      (name: "b", expr: .num(0))]
        )

        // Pass in topological order: a before b
        let codegen = MetalCodeGen(program: program, swatch: swatch, scopedBundles: ["a", "b"])
        let shader = try codegen.generate()

        // "a" vars should appear before "b" vars
        guard let aPos = shader.range(of: "scope_a_val")?.lowerBound,
              let bPos = shader.range(of: "scope_b_val")?.lowerBound else {
            XCTFail("Both scope_a_val and scope_b_val should be in shader")
            return
        }
        XCTAssertTrue(aPos < bPos, "scope_a_val should appear before scope_b_val (topological order)")

        // b's expression should use the CSE variable for a
        XCTAssertTrue(shader.contains("float scope_b_val = (scope_a_val * 2.0)"),
                     "scope_b_val should reference scope_a_val via CSE")
    }

    func testNameSanitization() throws {
        // Bundle name with $ prefix (common in desugared IR)
        let expr: IRExpr = .index(bundle: "me", indexExpr: .param("x"))
        let (program, swatch) = makeProgram(
            intermediates: ["$foo": [(name: "val", expr: expr)]],
            display: [(name: "r", expr: .index(bundle: "$foo", indexExpr: .param("val"))),
                      (name: "g", expr: .num(0)),
                      (name: "b", expr: .num(0))]
        )

        let codegen = MetalCodeGen(program: program, swatch: swatch, scopedBundles: ["$foo"])
        let shader = try codegen.generate()

        // $ should be replaced with _ in Metal variable names
        XCTAssertTrue(shader.contains("scope__foo_val"), "$ should be sanitized to _ in Metal variable names")
        XCTAssertFalse(shader.contains("scope_$"), "Raw $ should not appear in Metal variable names")
    }

    func testScopeTextureCount() throws {
        let aExpr: IRExpr = .index(bundle: "me", indexExpr: .param("x"))
        let bExpr: IRExpr = .index(bundle: "me", indexExpr: .param("y"))
        let (program, swatch) = makeProgram(
            intermediates: [
                "a": [(name: "val", expr: aExpr)],
                "b": [(name: "val", expr: bExpr)]
            ],
            display: [(name: "r", expr: .index(bundle: "a", indexExpr: .param("val"))),
                      (name: "g", expr: .index(bundle: "b", indexExpr: .param("val"))),
                      (name: "b", expr: .num(0))]
        )

        let codegen = MetalCodeGen(program: program, swatch: swatch, scopedBundles: ["a", "b"])
        _ = try codegen.generate()

        XCTAssertEqual(codegen.scopeTextureCount, 2)
        XCTAssertEqual(codegen.scopedBundleNames, ["a", "b"])
    }

    func testScopeTextureParams() throws {
        let aExpr: IRExpr = .index(bundle: "me", indexExpr: .param("x"))
        let (program, swatch) = makeProgram(
            intermediates: ["a": [(name: "val", expr: aExpr)]],
            display: [(name: "r", expr: .index(bundle: "a", indexExpr: .param("val"))),
                      (name: "g", expr: .num(0)),
                      (name: "b", expr: .num(0))]
        )

        let codegen = MetalCodeGen(program: program, swatch: swatch, scopedBundles: ["a"])
        let shader = try codegen.generate()

        // Should have scope texture parameter at index 50
        XCTAssertTrue(shader.contains("texture2d<float, access::write> scopeTex0 [[texture(50)]]"),
                     "Scope texture parameter should be at texture index 50")
    }

    func testMultiStrandScope() throws {
        // Bundle with 3 strands (like an RGB intermediate)
        let (program, swatch) = makeProgram(
            intermediates: ["color": [
                (name: "r", expr: .index(bundle: "me", indexExpr: .param("x"))),
                (name: "g", expr: .index(bundle: "me", indexExpr: .param("y"))),
                (name: "b", expr: .index(bundle: "me", indexExpr: .param("t")))
            ]],
            display: [(name: "r", expr: .index(bundle: "color", indexExpr: .param("r"))),
                      (name: "g", expr: .index(bundle: "color", indexExpr: .param("g"))),
                      (name: "b", expr: .index(bundle: "color", indexExpr: .param("b")))]
        )

        let codegen = MetalCodeGen(program: program, swatch: swatch, scopedBundles: ["color"])
        let shader = try codegen.generate()

        // All three strand vars should be present
        XCTAssertTrue(shader.contains("scope_color_r"))
        XCTAssertTrue(shader.contains("scope_color_g"))
        XCTAssertTrue(shader.contains("scope_color_b"))

        // Texture write should pack all three channels
        XCTAssertTrue(shader.contains("scopeTex0.write(float4(scope_color_r, scope_color_g, scope_color_b, 1.0"), "Should pack 3 strands into rgb channels with alpha=1")
    }

    func testDisplayBundleNotScoped() throws {
        // If "display" is in scopedBundles, it should be filtered out
        let (program, swatch) = makeProgram(
            intermediates: [:],
            display: [(name: "r", expr: .index(bundle: "me", indexExpr: .param("x"))),
                      (name: "g", expr: .num(0)),
                      (name: "b", expr: .num(0))]
        )

        let codegen = MetalCodeGen(program: program, swatch: swatch, scopedBundles: ["display"])
        let shader = try codegen.generate()

        // display should not be scoped (it IS the output)
        XCTAssertEqual(codegen.scopeTextureCount, 0)
        XCTAssertFalse(shader.contains("scopeTex"), "display bundle should not be scoped")
    }
}
