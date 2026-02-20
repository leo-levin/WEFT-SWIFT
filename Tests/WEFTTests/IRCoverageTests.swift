// IRCoverageTests.swift - Comprehensive tests for IR.swift, IRAnnotations.swift,
// IRTransformations.swift, and IRParser.swift

import XCTest
@testable import WEFTLib

// MARK: - IR Tree Operation Tests

final class IRExprTreeTests: XCTestCase {

    // MARK: - anyNode

    func testAnyNodeShortCircuitsOnFirstMatch() {
        // Tree: (1 + sin(2))
        let expr = IRExpr.binaryOp(
            op: "+",
            left: .num(1),
            right: .builtin(name: "sin", args: [.num(2)])
        )
        var visitCount = 0
        let found = expr.anyNode { node in
            visitCount += 1
            if case .num(1) = node { return true }
            return false
        }
        XCTAssertTrue(found)
        // The predicate checks self first, so: root binaryOp (false), then left .num(1) (true).
        // Short-circuits before visiting right subtree.
        XCTAssertEqual(visitCount, 2, "Should short-circuit after finding .num(1)")
    }

    func testAnyNodeTraversesAllNodeTypes() {
        // Construct a tree that exercises every node kind
        let expr = IRExpr.remap(
            base: .extract(
                call: .call(spindle: "foo", args: [
                    .builtin(name: "sin", args: [.param("x")]),
                    .binaryOp(op: "+", left: .num(1), right: .num(2))
                ]),
                index: 0
            ),
            substitutions: [
                "me.x": .unaryOp(op: "-", operand: .index(bundle: "me", indexExpr: .param("y")))
            ]
        )

        // cacheRead is a separate leaf -- add it separately
        let cacheExpr = IRExpr.cacheRead(cacheId: "c1", tapIndex: 0, coordinates: [])

        // anyNode should find deeply nested param("x")
        XCTAssertTrue(expr.anyNode { if case .param("x") = $0 { return true }; return false })
        // anyNode should find the remap substitution's unaryOp
        XCTAssertTrue(expr.anyNode { if case .unaryOp = $0 { return true }; return false })
        // anyNode should not find cacheRead in this tree
        XCTAssertFalse(expr.anyNode { if case .cacheRead = $0 { return true }; return false })
        // cacheRead should find itself
        XCTAssertTrue(cacheExpr.anyNode { if case .cacheRead = $0 { return true }; return false })
    }

    // MARK: - usesBuiltin

    func testUsesBuiltinNestedInsideBinaryOp() {
        let expr = IRExpr.binaryOp(
            op: "*",
            left: .builtin(name: "sin", args: [.param("x")]),
            right: .builtin(name: "cos", args: [.param("y")])
        )
        XCTAssertTrue(expr.usesBuiltin("sin"))
        XCTAssertTrue(expr.usesBuiltin("cos"))
        XCTAssertFalse(expr.usesBuiltin("tan"))
    }

    // MARK: - containsCall

    func testContainsCallDeeplyNested() {
        let expr = IRExpr.binaryOp(
            op: "+",
            left: .num(1),
            right: .unaryOp(
                op: "-",
                operand: .extract(
                    call: .call(spindle: "deep", args: []),
                    index: 0
                )
            )
        )
        XCTAssertTrue(expr.containsCall())
    }

    // MARK: - forEachChild

    func testForEachChildRemapVisitsBaseAndSubstitutions() {
        let expr = IRExpr.remap(
            base: .param("a"),
            substitutions: ["me.x": .num(0.5), "me.y": .num(0.3)]
        )
        var visited: [IRExpr] = []
        expr.forEachChild { visited.append($0) }
        // base + 2 substitution values = 3
        XCTAssertEqual(visited.count, 3)
        XCTAssertTrue(visited.contains(.param("a")), "Should visit base")
    }

    // MARK: - mapChildren

    func testMapChildrenTransformsBinaryOpChildren() {
        let expr = IRExpr.binaryOp(op: "+", left: .num(1), right: .num(2))
        let doubled = expr.mapChildren { child in
            if case .num(let v) = child { return .num(v * 2) }
            return child
        }
        if case .binaryOp(_, let left, let right) = doubled {
            XCTAssertEqual(left, .num(2))
            XCTAssertEqual(right, .num(4))
        } else {
            XCTFail("Should still be binaryOp")
        }
    }

    func testMapChildrenTransformsRemapSubstitutions() {
        let expr = IRExpr.remap(
            base: .num(0),
            substitutions: ["me.x": .num(1)]
        )
        let result = expr.mapChildren { child in
            if case .num(let v) = child { return .num(v + 10) }
            return child
        }
        if case .remap(let base, let subs) = result {
            XCTAssertEqual(base, .num(10), "Base should be transformed")
            XCTAssertEqual(subs["me.x"], .num(11), "Substitution value should be transformed")
        } else {
            XCTFail("Should still be remap")
        }
    }

    // MARK: - allBuiltins

    func testAllBuiltinsCollectsNestedBuiltins() {
        let expr = IRExpr.binaryOp(
            op: "+",
            left: .builtin(name: "sin", args: [.num(1)]),
            right: .builtin(name: "cos", args: [
                .builtin(name: "abs", args: [.num(2)])
            ])
        )
        let builtins = expr.allBuiltins()
        XCTAssertEqual(builtins, ["sin", "cos", "abs"])
    }

    // MARK: - isHeavyExpression

    func testIsHeavyExpressionWithCall() {
        let expr = IRExpr.call(spindle: "foo", args: [.num(1)])
        XCTAssertTrue(expr.isHeavyExpression(), "Call makes expression heavy")
    }

    // MARK: - freeVars

    func testFreeVarsSimpleIndex() {
        let expr = IRExpr.index(bundle: "a", indexExpr: .param("r"))
        XCTAssertEqual(expr.freeVars(), ["a.r"])
    }

    func testFreeVarsNumericIndex() {
        let expr = IRExpr.index(bundle: "a", indexExpr: .num(0))
        XCTAssertEqual(expr.freeVars(), ["a.0"])
    }

    func testFreeVarsRemapRemovesSubstitutedKeys() {
        // a.r remapped with me.x -> 0.5 should remove "me.x" from free vars
        // but the base's vars remain
        let expr = IRExpr.remap(
            base: .index(bundle: "a", indexExpr: .param("r")),
            substitutions: ["a.r": .num(0.5)]
        )
        let vars = expr.freeVars()
        XCTAssertFalse(vars.contains("a.r"), "Remapped key should be removed")
    }

    func testFreeVarsRemapAddsSubstitutionExprVars() {
        let expr = IRExpr.remap(
            base: .index(bundle: "a", indexExpr: .param("r")),
            substitutions: ["a.r": .index(bundle: "b", indexExpr: .param("val"))]
        )
        let vars = expr.freeVars()
        XCTAssertTrue(vars.contains("b.val"), "Substitution expression vars should be included")
    }

    // MARK: - currentTickFreeVars

    func testCurrentTickFreeVarsTemporalRemapExcludesBase() {
        // a.r(me.t ~ me.t - 1) -- base refs are previous-tick, should be excluded
        let expr = IRExpr.remap(
            base: .index(bundle: "a", indexExpr: .param("r")),
            substitutions: [
                "me.t": .binaryOp(
                    op: "-",
                    left: .index(bundle: "me", indexExpr: .param("t")),
                    right: .num(1)
                )
            ]
        )
        let vars = expr.currentTickFreeVars()
        XCTAssertFalse(vars.contains("a.r"),
            "Base refs in temporal remap should be excluded from current-tick vars")
        XCTAssertTrue(vars.contains("me.t"),
            "Substitution expr vars should be included")
    }

    func testCurrentTickFreeVarsNonTemporalRemapIncludesBase() {
        // a.r(me.x ~ 0.5) -- not temporal, base vars included
        let expr = IRExpr.remap(
            base: .index(bundle: "a", indexExpr: .param("r")),
            substitutions: ["me.x": .num(0.5)]
        )
        let vars = expr.currentTickFreeVars()
        XCTAssertTrue(vars.contains("a.r"),
            "Base refs in non-temporal remap should be included")
    }

    // MARK: - collectBundleReferences

    func testCollectBundleReferencesSimple() {
        let expr = IRExpr.binaryOp(
            op: "+",
            left: .index(bundle: "a", indexExpr: .param("r")),
            right: .index(bundle: "b", indexExpr: .param("g"))
        )
        let refs = expr.collectBundleReferences()
        XCTAssertEqual(refs, ["a", "b"])
    }

    func testCollectBundleReferencesExcludeMe() {
        let expr = IRExpr.binaryOp(
            op: "+",
            left: .index(bundle: "me", indexExpr: .param("x")),
            right: .index(bundle: "img", indexExpr: .param("r"))
        )
        let refs = expr.collectBundleReferences(excludeMe: true)
        XCTAssertEqual(refs, ["img"])
        let refsWithMe = expr.collectBundleReferences(excludeMe: false)
        XCTAssertTrue(refsWithMe.contains("me"))
    }

    func testCollectBundleReferencesDeeplyNested() {
        let expr = IRExpr.builtin(name: "lerp", args: [
            .index(bundle: "a", indexExpr: .num(0)),
            .index(bundle: "b", indexExpr: .num(0)),
            .remap(
                base: .index(bundle: "c", indexExpr: .param("val")),
                substitutions: ["me.x": .index(bundle: "d", indexExpr: .param("v"))]
            )
        ])
        let refs = expr.collectBundleReferences(excludeMe: true)
        XCTAssertEqual(refs, ["a", "b", "c", "d"])
    }

    // MARK: - Edge Cases

}

// MARK: - IRAnnotations Tests

final class IRAnnotationsExtendedTests: XCTestCase {

    // MARK: - isPure checks ALL strands

    func testIsPureBundleCheckAllStrands() throws {
        // Bundle where first strand is pure but second is not (has cache)
        // This tests the bug where only the first strand was checked
        let json = """
        {
            "bundles": {
                "mixed": {
                    "name": "mixed",
                    "strands": [
                        {"name": "pure", "index": 0, "expr": {
                            "type": "binary", "op": "+",
                            "left": {"type": "index", "bundle": "me", "field": "x"},
                            "right": {"type": "num", "value": 1}
                        }},
                        {"name": "impure", "index": 1, "expr": {
                            "type": "builtin", "name": "cache", "args": [
                                {"type": "index", "bundle": "me", "field": "x"},
                                {"type": "num", "value": 2},
                                {"type": "num", "value": 1},
                                {"type": "index", "bundle": "me", "field": "t"}
                            ]
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

        let pass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = pass.annotate()

        // Individual strand checks
        let pureSignal = annotated.signals["mixed.pure"]!
        XCTAssertTrue(pureSignal.isPure, "First strand should be pure")

        let impureSignal = annotated.signals["mixed.impure"]!
        XCTAssertFalse(impureSignal.isPure, "Second strand should be impure (cache)")
        XCTAssertTrue(impureSignal.stateful)

        // Bundle-level isPure should be FALSE because one strand is impure
        XCTAssertFalse(annotated.isPure("mixed"),
            "Bundle should be impure when ANY strand is impure")
    }

    // MARK: - Hardware propagation through references

    func testHardwarePropagationThroughTransitiveReferences() throws {
        // Chain: A uses camera -> B references A -> C references B
        // C should inherit camera hardware
        let json = """
        {
            "bundles": {
                "cam": {
                    "name": "cam",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {
                            "type": "builtin", "name": "camera", "args": [
                                {"type": "index", "bundle": "me", "field": "x"},
                                {"type": "index", "bundle": "me", "field": "y"},
                                {"type": "num", "value": 0}
                            ]
                        }}
                    ]
                },
                "mid": {
                    "name": "mid",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "binary", "op": "*",
                            "left": {"type": "index", "bundle": "cam", "field": "r"},
                            "right": {"type": "num", "value": 0.5}
                        }}
                    ]
                },
                "out": {
                    "name": "out",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "binary", "op": "+",
                            "left": {"type": "index", "bundle": "mid", "field": "val"},
                            "right": {"type": "num", "value": 0.1}
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

        let pass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = pass.annotate()

        XCTAssertTrue(annotated.signals["cam.r"]!.hardware.contains(.camera))
        XCTAssertTrue(annotated.signals["mid.val"]!.hardware.contains(.camera),
            "mid should inherit camera from cam")
        XCTAssertTrue(annotated.signals["out.val"]!.hardware.contains(.camera),
            "out should transitively inherit camera from cam through mid")
    }

    func testCameraInOneStrandMakesWholeBundleRequireCamera() throws {
        // Bundle with 3 strands; only strand 1 uses camera
        let json = """
        {
            "bundles": {
                "img": {
                    "name": "img",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {"type": "num", "value": 0.5}},
                        {"name": "g", "index": 1, "expr": {
                            "type": "builtin", "name": "camera", "args": [
                                {"type": "index", "bundle": "me", "field": "x"},
                                {"type": "index", "bundle": "me", "field": "y"},
                                {"type": "num", "value": 1}
                            ]
                        }},
                        {"name": "b", "index": 2, "expr": {"type": "num", "value": 0.3}}
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

        let pass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = pass.annotate()

        // Only strand "g" has camera
        XCTAssertFalse(annotated.signals["img.r"]!.hardware.contains(.camera))
        XCTAssertTrue(annotated.signals["img.g"]!.hardware.contains(.camera))
        XCTAssertFalse(annotated.signals["img.b"]!.hardware.contains(.camera))

        // bundleHardware should union all strand hardware
        let bundleHw = annotated.bundleHardware("img")
        XCTAssertTrue(bundleHw.contains(.camera),
            "Bundle should require camera when any strand uses it")
    }

    // MARK: - Dimension analysis

    func testMicrophoneRequiresAudioDomain() throws {
        let json = """
        {
            "bundles": {
                "mic": {
                    "name": "mic",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "builtin", "name": "microphone", "args": [
                                {"type": "index", "bundle": "me", "field": "i"},
                                {"type": "num", "value": 0}
                            ]
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

        let pass = AnnotationPass(
            program: program,
            coordinateSpecs: AudioBackend.coordinateSpecs,
            primitiveSpecs: AudioBackend.primitiveSpecs
        )
        let annotated = pass.annotate()

        let micSignal = annotated.signals["mic.val"]!
        XCTAssertTrue(micSignal.hardware.contains(.microphone))
        // Microphone output domain is t:bound
        XCTAssertTrue(micSignal.domain.contains { $0.name == "t" && $0.access == .bound })
    }

    // MARK: - cacheRead annotations

    func testCacheReadIsStateful() throws {
        // cacheRead is stateful but has no hardware requirements
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "cacheRead", "cacheId": "c1", "tapIndex": 0
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

        let pass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = pass.annotate()

        let signal = annotated.signals["test.val"]!
        XCTAssertTrue(signal.stateful, "cacheRead should be stateful")
        XCTAssertTrue(signal.hardware.isEmpty, "cacheRead has no hardware")
        XCTAssertFalse(signal.isPure, "cacheRead is not pure (it's stateful)")
    }

    // MARK: - Unknown bundle returns empty

    func testIsPureUnknownBundleReturnsFalse() {
        // Empty annotated program with no signals
        let annotated = IRAnnotatedProgram(signals: [:], original: IRProgram())
        XCTAssertFalse(annotated.isPure("nonexistent"),
            "Unknown bundle should be conservatively impure")
    }

    // MARK: - Texture requires GPU hardware

    func testTextureRequiresGPU() throws {
        let json = """
        {
            "bundles": {
                "tex": {
                    "name": "tex",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "builtin", "name": "texture", "args": [
                                {"type": "num", "value": 0},
                                {"type": "index", "bundle": "me", "field": "x"},
                                {"type": "index", "bundle": "me", "field": "y"},
                                {"type": "num", "value": 0}
                            ]
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

        let pass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = pass.annotate()

        let texSignal = annotated.signals["tex.val"]!
        XCTAssertTrue(texSignal.hardware.contains(.gpu),
            "texture should require GPU hardware")
        XCTAssertTrue(texSignal.domain.contains { $0.name == "x" && $0.access == .free })
        XCTAssertTrue(texSignal.domain.contains { $0.name == "y" && $0.access == .free })
    }

    // MARK: - Domain merge: bound wins

    func testDomainMergeBoundWins() throws {
        // Expression using me.t from visual domain (bound) combined with
        // me.x (free) -- t should remain bound
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "binary", "op": "+",
                            "left": {"type": "index", "bundle": "me", "field": "x"},
                            "right": {"type": "index", "bundle": "me", "field": "t"}
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

        let pass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = pass.annotate()

        let signal = annotated.signals["test.val"]!
        let tDim = signal.domain.first { $0.name == "t" }
        XCTAssertNotNil(tDim)
        XCTAssertEqual(tDim?.access, .bound, "t should remain bound in visual domain")

        let xDim = signal.domain.first { $0.name == "x" }
        XCTAssertNotNil(xDim)
        XCTAssertEqual(xDim?.access, .free, "x should remain free")
    }

}

// MARK: - IRTransformations Edge Case Tests

final class IRTransformationsEdgeCaseTests: XCTestCase {

    // MARK: - substituteParams

    func testSubstituteParamsHandlesNestedSubstitution() {
        // Substituting in a builtin with nested params
        let expr = IRExpr.builtin(name: "sin", args: [
            .binaryOp(op: "*", left: .param("freq"), right: .param("t"))
        ])
        let result = IRTransformations.substituteParams(
            in: expr,
            substitutions: ["freq": .num(440), "t": .index(bundle: "me", indexExpr: .param("t"))]
        )
        if case .builtin(let name, let args) = result {
            XCTAssertEqual(name, "sin")
            if case .binaryOp(_, let left, let right) = args[0] {
                XCTAssertEqual(left, .num(440))
                XCTAssertEqual(right, .index(bundle: "me", indexExpr: .param("t")))
            } else {
                XCTFail("Expected binaryOp inside builtin")
            }
        } else {
            XCTFail("Expected builtin")
        }
    }

    func testSubstituteParamsIndexBundleRedirection() {
        // When substitution maps a bundle name to an index, the bundle is redirected
        let expr = IRExpr.index(bundle: "local", indexExpr: .param("v"))
        let result = IRTransformations.substituteParams(
            in: expr,
            substitutions: ["local": .index(bundle: "real", indexExpr: .num(0))]
        )
        if case .index(let bundle, _) = result {
            XCTAssertEqual(bundle, "real",
                "Bundle name should be redirected")
        } else {
            XCTFail("Expected index expression")
        }
    }

    // MARK: - buildSpindleSubstitutions

    func testBuildSpindleSubstitutionsIncludesLocals() {
        let spindle = IRSpindle(
            name: "test",
            params: ["a"],
            locals: [
                IRBundle(name: "mid", strands: [
                    IRStrand(name: "v", index: 0,
                        expr: .binaryOp(op: "*", left: .param("a"), right: .num(2)))
                ])
            ],
            returns: [.index(bundle: "mid", indexExpr: .num(0))]
        )

        let subs = IRTransformations.buildSpindleSubstitutions(
            spindleDef: spindle,
            args: [.num(5)]
        )

        // Should have param substitution
        XCTAssertEqual(subs["a"], .num(5))
        // Should have local substitutions (by both index and name)
        XCTAssertNotNil(subs["mid.0"], "Should have local substitution by index")
        XCTAssertNotNil(subs["mid.v"], "Should have local substitution by name")
        // The local's expression should have params substituted
        if case .binaryOp(_, let left, _) = subs["mid.0"]! {
            XCTAssertEqual(left, .num(5), "Local expr should have param substituted")
        } else {
            XCTFail("Expected binaryOp in local substitution")
        }
    }

    func testBuildSpindleSubstitutionsTooFewArgs() {
        // If fewer args than params, unmatched params should remain
        let spindle = IRSpindle(
            name: "test",
            params: ["a", "b", "c"],
            locals: [],
            returns: [.param("c")]
        )

        let subs = IRTransformations.buildSpindleSubstitutions(
            spindleDef: spindle,
            args: [.num(1), .num(2)]  // only 2 args for 3 params
        )

        XCTAssertEqual(subs["a"], .num(1))
        XCTAssertEqual(subs["b"], .num(2))
        XCTAssertNil(subs["c"], "Unmatched param should not have substitution")
    }

    // MARK: - applyRemap

    func testApplyRemapSubstitutesCoordinates() {
        let expr = IRExpr.index(bundle: "me", indexExpr: .param("x"))
        let result = IRTransformations.applyRemap(
            to: expr,
            substitutions: ["me.x": .num(0.5)]
        )
        XCTAssertEqual(result, .num(0.5))
    }

    func testApplyRemapRecursesIntoChildren() {
        let expr = IRExpr.binaryOp(
            op: "+",
            left: .index(bundle: "me", indexExpr: .param("x")),
            right: .index(bundle: "me", indexExpr: .param("y"))
        )
        let result = IRTransformations.applyRemap(
            to: expr,
            substitutions: ["me.x": .num(0.5)]
        )
        if case .binaryOp(_, let left, let right) = result {
            XCTAssertEqual(left, .num(0.5), "me.x should be substituted")
            XCTAssertEqual(right, .index(bundle: "me", indexExpr: .param("y")),
                "me.y should remain")
        } else {
            XCTFail("Expected binaryOp")
        }
    }

    // MARK: - spindleCanBeFunction

    func testPureSpindleCanBeFunction() {
        let spindle = IRSpindle(
            name: "add",
            params: ["a", "b"],
            locals: [],
            returns: [.binaryOp(op: "+", left: .param("a"), right: .param("b"))]
        )
        XCTAssertTrue(IRTransformations.spindleCanBeFunction(spindle))
    }

    func testCacheSpindleCannotBeFunction() {
        let spindle = IRSpindle(
            name: "stateful",
            params: [],
            locals: [
                IRBundle(name: "prev", strands: [
                    IRStrand(name: "v", index: 0, expr: .builtin(name: "cache", args: [
                        .num(0), .num(2), .num(1), .index(bundle: "me", indexExpr: .param("t"))
                    ]))
                ])
            ],
            returns: [.index(bundle: "prev", indexExpr: .num(0))]
        )
        XCTAssertFalse(IRTransformations.spindleCanBeFunction(spindle))
    }

    func testResourceSpindleCannotBeFunction() {
        let spindle = IRSpindle(
            name: "cam",
            params: [],
            locals: [],
            returns: [.builtin(name: "camera", args: [.num(0), .num(0), .num(0)])]
        )
        XCTAssertFalse(IRTransformations.spindleCanBeFunction(spindle))
    }

    // MARK: - collectLocalReferences

    func testCollectLocalReferencesFindsReferences() {
        let expr = IRExpr.binaryOp(
            op: "+",
            left: .index(bundle: "local1", indexExpr: .num(0)),
            right: .index(bundle: "local2", indexExpr: .num(0))
        )
        let refs = IRTransformations.collectLocalReferences(
            expr, localNames: ["local1", "local2", "local3"]
        )
        XCTAssertEqual(refs, ["local1", "local2"])
    }

    // MARK: - transitiveLocalDeps

    func testTransitiveLocalDepsFollowsChain() {
        // A depends on B, B depends on C
        let locals = [
            IRBundle(name: "a", strands: [
                IRStrand(name: "v", index: 0,
                    expr: .index(bundle: "b", indexExpr: .num(0)))
            ]),
            IRBundle(name: "b", strands: [
                IRStrand(name: "v", index: 0,
                    expr: .index(bundle: "c", indexExpr: .num(0)))
            ]),
            IRBundle(name: "c", strands: [
                IRStrand(name: "v", index: 0, expr: .num(42))
            ])
        ]

        let deps = IRTransformations.transitiveLocalDeps("a", locals: locals)
        XCTAssertTrue(deps.contains("b"), "A should depend on B")
        XCTAssertTrue(deps.contains("c"), "A should transitively depend on C")
    }

    func testTransitiveLocalDepsHandlesCycles() {
        // A depends on B, B depends on A (circular)
        let locals = [
            IRBundle(name: "a", strands: [
                IRStrand(name: "v", index: 0,
                    expr: .index(bundle: "b", indexExpr: .num(0)))
            ]),
            IRBundle(name: "b", strands: [
                IRStrand(name: "v", index: 0,
                    expr: .index(bundle: "a", indexExpr: .num(0)))
            ])
        ]

        // Should not infinite loop
        let deps = IRTransformations.transitiveLocalDeps("a", locals: locals)
        XCTAssertTrue(deps.contains("b"))
        // "a" won't be in deps because it's the starting node
    }

    // MARK: - inlineSpindleCallWithTarget no cycles

    func testInlineSpindleCallWithTargetNoCycles() {
        // Pure spindle with no cycles
        let spindle = IRSpindle(
            name: "double",
            params: ["x"],
            locals: [],
            returns: [.binaryOp(op: "*", left: .param("x"), right: .num(2))]
        )

        let result = IRTransformations.inlineSpindleCallWithTarget(
            spindleDef: spindle,
            args: [.num(5)],
            targetBundle: "env",
            targetStrandIndex: 0,
            returnIndex: 0
        )

        // Should just substitute params: 5 * 2
        XCTAssertEqual(result, .binaryOp(op: "*", left: .num(5), right: .num(2)))
    }

    func testInlineSpindleCallWithTargetOutOfBoundsReturn() {
        let spindle = IRSpindle(
            name: "test",
            params: [],
            locals: [],
            returns: [.num(1)]
        )

        let result = IRTransformations.inlineSpindleCallWithTarget(
            spindleDef: spindle,
            args: [],
            targetBundle: "env",
            targetStrandIndex: 0,
            returnIndex: 5  // out of bounds
        )

        // Should return .num(0) as fallback
        XCTAssertEqual(result, .num(0))
    }

    // MARK: - inlineExpression

    func testInlineExpressionResolvesIndex() throws {
        let program = IRProgram(
            bundles: [
                "a": IRBundle(name: "a", strands: [
                    IRStrand(name: "v", index: 0, expr: .num(42))
                ])
            ],
            spindles: [:],
            order: []
        )

        // index(bundle: "a", indexExpr: .param("v")) should resolve to .num(42)
        let expr = IRExpr.index(bundle: "a", indexExpr: .param("v"))
        let result = try IRTransformations.inlineExpression(expr, program: program)
        XCTAssertEqual(result, .num(42))
    }

    func testInlineExpressionResolvesByNumericIndex() throws {
        let program = IRProgram(
            bundles: [
                "a": IRBundle(name: "a", strands: [
                    IRStrand(name: "v", index: 0, expr: .num(42))
                ])
            ],
            spindles: [:],
            order: []
        )

        let expr = IRExpr.index(bundle: "a", indexExpr: .num(0))
        let result = try IRTransformations.inlineExpression(expr, program: program)
        XCTAssertEqual(result, .num(42))
    }

    func testInlineExpressionInlinesCall() throws {
        let program = IRProgram(
            bundles: [:],
            spindles: [
                "double": IRSpindle(
                    name: "double",
                    params: ["x"],
                    locals: [],
                    returns: [.binaryOp(op: "*", left: .param("x"), right: .num(2))]
                )
            ],
            order: []
        )

        let expr = IRExpr.call(spindle: "double", args: [.num(5)])
        let result = try IRTransformations.inlineExpression(expr, program: program)
        XCTAssertEqual(result, .binaryOp(op: "*", left: .num(5), right: .num(2)))
    }

    func testInlineExpressionInlinesExtract() throws {
        let program = IRProgram(
            bundles: [:],
            spindles: [
                "swap": IRSpindle(
                    name: "swap",
                    params: ["a", "b"],
                    locals: [],
                    returns: [.param("b"), .param("a")]
                )
            ],
            order: []
        )

        // extract(call("swap", [1, 2]), 0) should resolve to 2 (param "b")
        let expr = IRExpr.extract(
            call: .call(spindle: "swap", args: [.num(1), .num(2)]),
            index: 0
        )
        let result = try IRTransformations.inlineExpression(expr, program: program)
        XCTAssertEqual(result, .num(2), "extract index 0 should get first return (param b = arg 2)")
    }

    func testInlineExpressionRemap() throws {
        let program = IRProgram(
            bundles: [
                "a": IRBundle(name: "a", strands: [
                    IRStrand(name: "v", index: 0,
                        expr: .index(bundle: "me", indexExpr: .param("x")))
                ])
            ],
            spindles: [:],
            order: []
        )

        // remap(a.v, me.x -> 0.5) should resolve to 0.5
        let expr = IRExpr.remap(
            base: .index(bundle: "a", indexExpr: .param("v")),
            substitutions: ["me.x": .num(0.5)]
        )
        let result = try IRTransformations.inlineExpression(expr, program: program)
        XCTAssertEqual(result, .num(0.5))
    }
}

// MARK: - IRParser Extended Tests

final class IRParserExtendedTests: XCTestCase {

    // MARK: - Missing optional fields

    func testParseWithMissingResources() throws {
        // Old-format JSON without resources field -- should still parse
        let json = """
        {
            "bundles": {},
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        XCTAssertTrue(program.resources.isEmpty, "Missing resources should default to empty")
        XCTAssertTrue(program.textResources.isEmpty, "Missing textResources should default to empty")
    }

    func testParseWithMissingTextResources() throws {
        let json = """
        {
            "bundles": {},
            "spindles": {},
            "order": [],
            "resources": ["img.png"]
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        XCTAssertEqual(program.resources, ["img.png"])
        XCTAssertTrue(program.textResources.isEmpty)
    }

    // MARK: - Malformed JSON

    func testParseMalformedJSONThrows() {
        let parser = IRParser()
        XCTAssertThrowsError(try parser.parse(json: "not json at all")) { error in
            if let parseError = error as? IRParseError {
                if case .invalidJSON = parseError {
                    // Expected
                } else {
                    XCTFail("Expected invalidJSON error, got \(parseError)")
                }
            }
        }
    }

    func testParseMissingBundlesFieldThrows() {
        let json = """
        {
            "spindles": {},
            "order": []
        }
        """
        let parser = IRParser()
        XCTAssertThrowsError(try parser.parse(json: json))
    }

    func testParseUnknownExprTypeThrows() {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "v", "index": 0, "expr": {"type": "UNKNOWN_TYPE"}}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """
        let parser = IRParser()
        XCTAssertThrowsError(try parser.parse(json: json))
    }

    // MARK: - Parsing all expression types

    func testParseUnaryOp() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "v", "index": 0, "expr": {
                            "type": "unary", "op": "-",
                            "operand": {"type": "num", "value": 5.0}
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        if case .unaryOp(let op, let operand) = strand.expr {
            XCTAssertEqual(op, "-")
            XCTAssertEqual(operand, .num(5.0))
        } else {
            XCTFail("Expected unaryOp, got \(strand.expr)")
        }
    }

    func testParseCallExpr() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "v", "index": 0, "expr": {
                            "type": "call", "spindle": "circle",
                            "args": [{"type": "num", "value": 1}, {"type": "num", "value": 2}]
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        if case .call(let spindle, let args) = strand.expr {
            XCTAssertEqual(spindle, "circle")
            XCTAssertEqual(args.count, 2)
        } else {
            XCTFail("Expected call, got \(strand.expr)")
        }
    }

    func testParseExtractExpr() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "v", "index": 0, "expr": {
                            "type": "extract",
                            "call": {"type": "call", "spindle": "swap", "args": [{"type": "num", "value": 1}, {"type": "num", "value": 2}]},
                            "index": 1
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        if case .extract(let call, let index) = strand.expr {
            XCTAssertEqual(index, 1)
            if case .call(let spindle, _) = call {
                XCTAssertEqual(spindle, "swap")
            } else {
                XCTFail("Expected call inside extract")
            }
        } else {
            XCTFail("Expected extract, got \(strand.expr)")
        }
    }

    func testParseCacheReadExpr() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "v", "index": 0, "expr": {
                            "type": "cacheRead", "cacheId": "env_val_0", "tapIndex": 1
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        if case .cacheRead(let cacheId, let tapIndex, _) = strand.expr {
            XCTAssertEqual(cacheId, "env_val_0")
            XCTAssertEqual(tapIndex, 1)
        } else {
            XCTFail("Expected cacheRead, got \(strand.expr)")
        }
    }

    func testParseRemapExpr() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "v", "index": 0, "expr": {
                            "type": "remap",
                            "base": {"type": "index", "bundle": "a", "field": "r"},
                            "substitutions": {
                                "me.x": {"type": "num", "value": 0.5}
                            }
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        if case .remap(let base, let subs) = strand.expr {
            if case .index(let bundle, _) = base {
                XCTAssertEqual(bundle, "a")
            } else {
                XCTFail("Expected index base")
            }
            XCTAssertEqual(subs["me.x"], .num(0.5))
        } else {
            XCTFail("Expected remap, got \(strand.expr)")
        }
    }

    // MARK: - Legacy format parsing

    func testParseLegacyCameraFormat() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {
                            "type": "camera",
                            "u": {"type": "index", "bundle": "me", "field": "x"},
                            "v": {"type": "index", "bundle": "me", "field": "y"},
                            "channel": 0
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        // Legacy camera should be converted to builtin
        if case .builtin(let name, let args) = strand.expr {
            XCTAssertEqual(name, "camera")
            XCTAssertEqual(args.count, 3) // u, v, channel
        } else {
            XCTFail("Expected builtin(camera), got \(strand.expr)")
        }
    }

    func testParseLegacyTextureFormat() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {
                            "type": "texture",
                            "resourceId": 0,
                            "u": {"type": "index", "bundle": "me", "field": "x"},
                            "v": {"type": "index", "bundle": "me", "field": "y"},
                            "channel": 1
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        if case .builtin(let name, let args) = strand.expr {
            XCTAssertEqual(name, "texture")
            XCTAssertEqual(args.count, 4) // resourceId, u, v, channel
            XCTAssertEqual(args[0], .num(0))  // resourceId
            XCTAssertEqual(args[3], .num(1))  // channel
        } else {
            XCTFail("Expected builtin(texture), got \(strand.expr)")
        }
    }

    func testParseLegacyMicrophoneFormat() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "microphone",
                            "offset": {"type": "num", "value": 0},
                            "channel": 0
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        if case .builtin(let name, let args) = strand.expr {
            XCTAssertEqual(name, "microphone")
            XCTAssertEqual(args.count, 2) // offset, channel
        } else {
            XCTFail("Expected builtin(microphone), got \(strand.expr)")
        }
    }

    // MARK: - Index fallback parsing

    func testParseIndexWithNumericFallback() throws {
        let json = """
        {
            "bundles": {
                "test": {
                    "name": "test",
                    "strands": [
                        {"name": "v", "index": 0, "expr": {
                            "type": "index", "bundle": "a", "index": 2
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        let strand = program.bundles["test"]!.strands[0]
        if case .index(let bundle, let indexExpr) = strand.expr {
            XCTAssertEqual(bundle, "a")
            XCTAssertEqual(indexExpr, .num(2))
        } else {
            XCTFail("Expected index with numeric fallback, got \(strand.expr)")
        }
    }

    // MARK: - Spindle parsing

    func testParseSpindleDefinition() throws {
        let json = """
        {
            "bundles": {},
            "spindles": {
                "circle": {
                    "name": "circle",
                    "params": ["cx", "cy", "radius"],
                    "locals": [
                        {
                            "name": "d",
                            "strands": [
                                {"name": "v", "index": 0, "expr": {
                                    "type": "builtin", "name": "sqrt", "args": [
                                        {"type": "num", "value": 1}
                                    ]
                                }}
                            ]
                        }
                    ],
                    "returns": [
                        {"type": "builtin", "name": "step", "args": [
                            {"type": "param", "name": "radius"},
                            {"type": "index", "bundle": "d", "field": "v"}
                        ]}
                    ]
                }
            },
            "order": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        XCTAssertNotNil(program.spindles["circle"])

        let spindle = program.spindles["circle"]!
        XCTAssertEqual(spindle.name, "circle")
        XCTAssertEqual(spindle.params, ["cx", "cy", "radius"])
        XCTAssertEqual(spindle.locals.count, 1)
        XCTAssertEqual(spindle.locals[0].name, "d")
        XCTAssertEqual(spindle.returns.count, 1)

        if case .builtin(let name, _) = spindle.returns[0] {
            XCTAssertEqual(name, "step")
        } else {
            XCTFail("Expected builtin return")
        }
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = IRProgram(
            bundles: [
                "display": IRBundle(name: "display", strands: [
                    IRStrand(name: "r", index: 0,
                        expr: .binaryOp(op: "+",
                            left: .index(bundle: "me", indexExpr: .param("x")),
                            right: .builtin(name: "sin", args: [
                                .index(bundle: "me", indexExpr: .param("t"))
                            ])
                        )),
                    IRStrand(name: "g", index: 1,
                        expr: .extract(
                            call: .call(spindle: "foo", args: [.num(1)]),
                            index: 0
                        )),
                    IRStrand(name: "b", index: 2,
                        expr: .remap(
                            base: .param("x"),
                            substitutions: ["me.x": .num(0.5)]
                        ))
                ])
            ],
            spindles: [
                "foo": IRSpindle(
                    name: "foo",
                    params: ["a"],
                    locals: [],
                    returns: [.param("a")]
                )
            ],
            order: [IRProgram.OrderEntry(bundle: "display", strands: ["r", "g", "b"])],
            resources: ["img.png"],
            textResources: ["hello.txt"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let parser = IRParser()
        let decoded = try parser.parse(data: data)

        XCTAssertEqual(decoded, original, "Round-trip through JSON should preserve all data")
    }

    // MARK: - Order parsing

    func testParseOrderEntries() throws {
        let json = """
        {
            "bundles": {
                "a": {"name": "a", "strands": [{"name": "v", "index": 0, "expr": {"type": "num", "value": 1}}]},
                "b": {"name": "b", "strands": [{"name": "v", "index": 0, "expr": {"type": "num", "value": 2}}]}
            },
            "spindles": {},
            "order": [
                {"bundle": "a", "strands": ["v"]},
                {"bundle": "b"}
            ]
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)
        XCTAssertEqual(program.order.count, 2)
        XCTAssertEqual(program.order[0].bundle, "a")
        XCTAssertEqual(program.order[0].strands, ["v"])
        XCTAssertEqual(program.order[1].bundle, "b")
        XCTAssertNil(program.order[1].strands)
    }

}

// MARK: - IRHardware Codable Tests

final class IRHardwareCodableTests: XCTestCase {

    func testHardwareCodableRoundTrip() throws {
        let cases: [IRHardware] = [.camera, .microphone, .speaker, .gpu, .custom("lidar")]
        let encoder = JSONEncoder()

        for hw in cases {
            let data = try encoder.encode(hw)
            let decoded = try JSONDecoder().decode(IRHardware.self, from: data)
            XCTAssertEqual(decoded, hw, "Round-trip failed for \(hw)")
        }
    }

    func testHardwareUnknownTypeThrows() {
        let json = """
        {"type": "unknown_hw"}
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(IRHardware.self, from: data))
    }
}

