import XCTest
@testable import WEFTLib

final class PartitionerScopeTests: XCTestCase {
    func testScopeBundlePartitionedToAudioSwatch() throws {
        // Program with play + scope bundles
        let program = IRProgram(bundles: [
            "osc": IRBundle(name: "osc", strands: [
                IRStrand(name: "val", index: 0, expr: .builtin(name: "sin", args: [
                    .binaryOp(op: "*", left: .index(bundle: "me", indexExpr: .param("i")), right: .num(0.01))
                ]))
            ]),
            "play": IRBundle(name: "play", strands: [
                IRStrand(name: "0", index: 0, expr: .index(bundle: "osc", indexExpr: .param("val")))
            ]),
            "scope": IRBundle(name: "scope", strands: [
                IRStrand(name: "osc", index: 0, expr: .index(bundle: "osc", indexExpr: .param("val")))
            ])
        ])

        let graph = DependencyGraph()
        graph.build(from: program)

        let allCoordinateSpecs = MetalBackend.coordinateSpecs
            .merging(AudioBackend.coordinateSpecs) { (visual, _) in visual }
        let allPrimitiveSpecs = MetalBackend.primitiveSpecs
            .merging(AudioBackend.primitiveSpecs) { (visual, _) in visual }

        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: allCoordinateSpecs,
            primitiveSpecs: allPrimitiveSpecs
        )
        let annotations = annotationPass.annotate()

        let partitioner = Partitioner(program: program, graph: graph, annotations: annotations)
        let swatchGraph = partitioner.partition()

        // Both "play" and "scope" should be in the audio swatch
        let audioSwatch = swatchGraph.swatches.first { $0.backend == "audio" }
        XCTAssertNotNil(audioSwatch)
        XCTAssertTrue(audioSwatch!.bundles.contains("play"))
        XCTAssertTrue(audioSwatch!.bundles.contains("scope"))
        XCTAssertTrue(audioSwatch!.isSink)
    }

    func testScopeWithoutPlayStillCreatesSwatch() throws {
        // Program with scope but no play
        let program = IRProgram(bundles: [
            "osc": IRBundle(name: "osc", strands: [
                IRStrand(name: "val", index: 0, expr: .builtin(name: "sin", args: [
                    .binaryOp(op: "*", left: .index(bundle: "me", indexExpr: .param("i")), right: .num(0.01))
                ]))
            ]),
            "scope": IRBundle(name: "scope", strands: [
                IRStrand(name: "osc", index: 0, expr: .index(bundle: "osc", indexExpr: .param("val")))
            ])
        ])

        let graph = DependencyGraph()
        graph.build(from: program)

        let allCoordinateSpecs = MetalBackend.coordinateSpecs
            .merging(AudioBackend.coordinateSpecs) { (visual, _) in visual }
        let allPrimitiveSpecs = MetalBackend.primitiveSpecs
            .merging(AudioBackend.primitiveSpecs) { (visual, _) in visual }

        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: allCoordinateSpecs,
            primitiveSpecs: allPrimitiveSpecs
        )
        let annotations = annotationPass.annotate()

        let partitioner = Partitioner(program: program, graph: graph, annotations: annotations)
        let swatchGraph = partitioner.partition()

        let audioSwatch = swatchGraph.swatches.first { $0.backend == "audio" }
        XCTAssertNotNil(audioSwatch)
        XCTAssertTrue(audioSwatch!.bundles.contains("scope"))
        XCTAssertTrue(audioSwatch!.isSink)
    }

    // MARK: - AudioCodeGen scope tests

    func testAudioCodeGenCompilesScopeFunction() throws {
        let program = IRProgram(bundles: [
            "osc": IRBundle(name: "osc", strands: [
                IRStrand(name: "val", index: 0, expr: .num(0.5))
            ]),
            "play": IRBundle(name: "play", strands: [
                IRStrand(name: "0", index: 0, expr: .index(bundle: "osc", indexExpr: .param("val")))
            ]),
            "scope": IRBundle(name: "scope", strands: [
                IRStrand(name: "signal", index: 0, expr: .index(bundle: "osc", indexExpr: .param("val")))
            ])
        ])

        let swatch = Swatch(backend: "audio", bundles: ["osc", "play", "scope"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        let renderFn = try codegen.generateRenderFunction()
        let scopeResult = try codegen.generateScopeFunction()

        // Render function works
        let (left, _) = renderFn(0, 0.0, 44100.0)
        XCTAssertEqual(left, 0.5, accuracy: 0.001)

        // Scope function works
        XCTAssertNotNil(scopeResult)
        let (scopeFn, scopeNames) = scopeResult!
        XCTAssertEqual(scopeNames, ["signal"])
        let scopeValues = scopeFn(0, 0.0, 44100.0)
        XCTAssertEqual(scopeValues.count, 1)
        XCTAssertEqual(scopeValues[0], 0.5, accuracy: 0.001)
    }

    func testNoScopeBundleReturnsNil() throws {
        let program = IRProgram(bundles: [
            "play": IRBundle(name: "play", strands: [
                IRStrand(name: "0", index: 0, expr: .num(0.5))
            ])
        ])

        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        let scopeResult = try codegen.generateScopeFunction()
        XCTAssertNil(scopeResult)
    }

    func testScopeOnlyWithoutPlay() throws {
        let program = IRProgram(bundles: [
            "osc": IRBundle(name: "osc", strands: [
                IRStrand(name: "val", index: 0, expr: .num(0.75))
            ]),
            "scope": IRBundle(name: "scope", strands: [
                IRStrand(name: "signal", index: 0, expr: .index(bundle: "osc", indexExpr: .param("val")))
            ])
        ])

        let swatch = Swatch(backend: "audio", bundles: ["osc", "scope"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)

        // Render function should return silence (no play bundle)
        let renderFn = try codegen.generateRenderFunction()
        let (left, right) = renderFn(0, 0.0, 44100.0)
        XCTAssertEqual(left, 0.0)
        XCTAssertEqual(right, 0.0)

        // Scope function should still work
        let scopeResult = try codegen.generateScopeFunction()
        XCTAssertNotNil(scopeResult)
        let (scopeFn, scopeNames) = scopeResult!
        XCTAssertEqual(scopeNames, ["signal"])
        let scopeValues = scopeFn(0, 0.0, 44100.0)
        XCTAssertEqual(scopeValues[0], 0.75, accuracy: 0.001)
    }
}
