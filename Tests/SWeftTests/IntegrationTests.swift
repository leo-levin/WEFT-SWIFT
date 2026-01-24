// IntegrationTests.swift - End-to-end integration tests

import XCTest
@testable import SWeftLib

final class IntegrationTests: XCTestCase {

    func testCoordinatorLoadsGradient() throws {
        let json = """
        {
            "bundles": {
                "display": {
                    "name": "display",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {"type": "index", "bundle": "me", "field": "x"}},
                        {"name": "g", "index": 1, "expr": {"type": "index", "bundle": "me", "field": "y"}},
                        {"name": "b", "index": 2, "expr": {"type": "builtin", "name": "fract", "args": [{"type": "index", "bundle": "me", "field": "t"}]}}
                    ]
                }
            },
            "spindles": {},
            "order": [{"bundle": "display"}],
            "resources": []
        }
        """

        let coordinator = Coordinator()
        try coordinator.load(json: json)

        XCTAssertNotNil(coordinator.program)
        XCTAssertNotNil(coordinator.swatchGraph)
        XCTAssertEqual(coordinator.swatchGraph?.swatches.count, 1)

        // Should have visual swatch
        let visualSwatches = coordinator.swatchGraph?.swatches.filter { $0.backend == "visual" }
        XCTAssertEqual(visualSwatches?.count, 1)
        XCTAssertTrue(visualSwatches?.first?.isSink ?? false)
    }

    func testCoordinatorLoadsAudio() throws {
        let json = """
        {
            "bundles": {
                "play": {
                    "name": "play",
                    "strands": [
                        {"name": "left", "index": 0, "expr": {
                            "type": "binary", "op": "*",
                            "left": {"type": "builtin", "name": "sin", "args": [
                                {"type": "binary", "op": "*",
                                    "left": {"type": "binary", "op": "/",
                                        "left": {"type": "index", "bundle": "me", "field": "i"},
                                        "right": {"type": "index", "bundle": "me", "field": "sampleRate"}
                                    },
                                    "right": {"type": "num", "value": 2764.6}
                                }
                            ]},
                            "right": {"type": "num", "value": 0.3}
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": [{"bundle": "play"}],
            "resources": []
        }
        """

        let coordinator = Coordinator()
        try coordinator.load(json: json)

        // Should have audio swatch
        let audioSwatches = coordinator.swatchGraph?.swatches.filter { $0.backend == "audio" }
        XCTAssertEqual(audioSwatches?.count, 1)
        XCTAssertTrue(audioSwatches?.first?.isSink ?? false)
    }

    func testCoordinatorLoadsCrossDomain() throws {
        let json = """
        {
            "bundles": {
                "amp": {
                    "name": "amp",
                    "strands": [
                        {"name": "value", "index": 0, "expr": {
                            "type": "builtin", "name": "abs", "args": [
                                {"type": "builtin", "name": "sin", "args": [
                                    {"type": "binary", "op": "*",
                                        "left": {"type": "index", "bundle": "me", "field": "t"},
                                        "right": {"type": "num", "value": 3.0}
                                    }
                                ]}
                            ]
                        }}
                    ]
                },
                "play": {
                    "name": "play",
                    "strands": [
                        {"name": "left", "index": 0, "expr": {
                            "type": "binary", "op": "*",
                            "left": {"type": "builtin", "name": "sin", "args": [
                                {"type": "binary", "op": "*",
                                    "left": {"type": "binary", "op": "/",
                                        "left": {"type": "index", "bundle": "me", "field": "i"},
                                        "right": {"type": "index", "bundle": "me", "field": "sampleRate"}
                                    },
                                    "right": {"type": "num", "value": 2764.6}
                                }
                            ]},
                            "right": {"type": "index", "bundle": "amp", "field": "value"}
                        }}
                    ]
                },
                "display": {
                    "name": "display",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {"type": "index", "bundle": "amp", "field": "value"}},
                        {"name": "g", "index": 1, "expr": {"type": "index", "bundle": "me", "field": "y"}},
                        {"name": "b", "index": 2, "expr": {"type": "index", "bundle": "me", "field": "x"}}
                    ]
                }
            },
            "spindles": {},
            "order": [{"bundle": "amp"}, {"bundle": "play"}, {"bundle": "display"}],
            "resources": []
        }
        """

        let coordinator = Coordinator()
        try coordinator.load(json: json)

        // Should have both swatches
        let visualSwatches = coordinator.swatchGraph?.swatches.filter { $0.backend == "visual" }
        let audioSwatches = coordinator.swatchGraph?.swatches.filter { $0.backend == "audio" }

        XCTAssertGreaterThanOrEqual(visualSwatches?.count ?? 0, 1)
        XCTAssertGreaterThanOrEqual(audioSwatches?.count ?? 0, 1)
    }

    func testMetalCodeGeneration() throws {
        let json = """
        {
            "bundles": {
                "display": {
                    "name": "display",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {"type": "index", "bundle": "me", "field": "x"}},
                        {"name": "g", "index": 1, "expr": {"type": "index", "bundle": "me", "field": "y"}},
                        {"name": "b", "index": 2, "expr": {"type": "builtin", "name": "sin", "args": [
                            {"type": "binary", "op": "*", "left": {"type": "index", "bundle": "me", "field": "t"}, "right": {"type": "num", "value": 3.0}}
                        ]}}
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

        let swatch = Swatch(backend: "visual", bundles: ["display"], isSink: true)
        let codegen = MetalCodeGen(program: program, swatch: swatch)
        let shader = try codegen.generate()

        // Verify shader contains expected code
        XCTAssertTrue(shader.contains("displayKernel"))
        XCTAssertTrue(shader.contains("float x = float(gid.x)"))
        XCTAssertTrue(shader.contains("float y = float(gid.y)"))
        XCTAssertTrue(shader.contains("sin"))
    }

    func testAudioCodeGeneration() throws {
        let json = """
        {
            "bundles": {
                "play": {
                    "name": "play",
                    "strands": [
                        {"name": "left", "index": 0, "expr": {
                            "type": "binary", "op": "*",
                            "left": {"type": "builtin", "name": "sin", "args": [
                                {"type": "binary", "op": "*",
                                    "left": {"type": "binary", "op": "/",
                                        "left": {"type": "index", "bundle": "me", "field": "i"},
                                        "right": {"type": "index", "bundle": "me", "field": "sampleRate"}
                                    },
                                    "right": {"type": "num", "value": 2764.6}
                                }
                            ]},
                            "right": {"type": "num", "value": 0.3}
                        }}
                    ]
                }
            },
            "spindles": {},
            "order": [{"bundle": "play"}],
            "resources": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)

        let swatch = Swatch(backend: "audio", bundles: ["play"], isSink: true)
        let codegen = AudioCodeGen(program: program, swatch: swatch)
        let renderFunc = try codegen.generateRenderFunction()

        // Test render function produces audio
        let (left, right) = renderFunc(0, 0.0, 44100.0)

        // At t=0, i=0, sin(0) * 0.3 = 0
        XCTAssertEqual(left, 0.0, accuracy: 0.0001)
        XCTAssertEqual(right, 0.0, accuracy: 0.0001)

        // At different sample indices, we should get different values
        let (left2, _) = renderFunc(100, 0.0, 44100.0)
        XCTAssertNotEqual(left2, 0.0)
    }

    func testDependencyGraph() throws {
        let json = """
        {
            "bundles": {
                "a": {"name": "a", "strands": [{"name": "v", "index": 0, "expr": {"type": "num", "value": 1.0}}]},
                "b": {"name": "b", "strands": [{"name": "v", "index": 0, "expr": {"type": "index", "bundle": "a", "index": 0}}]},
                "c": {"name": "c", "strands": [{"name": "v", "index": 0, "expr": {"type": "index", "bundle": "b", "index": 0}}]}
            },
            "spindles": {},
            "order": [],
            "resources": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)

        let graph = DependencyGraph()
        graph.build(from: program)

        XCTAssertEqual(graph.dependencies["a"], Set())
        XCTAssertEqual(graph.dependencies["b"], Set(["a"]))
        XCTAssertEqual(graph.dependencies["c"], Set(["b"]))

        // Topological sort
        let sorted = graph.topologicalSort()
        XCTAssertNotNil(sorted)

        // a must come before b, b must come before c
        if let sorted = sorted {
            let aIndex = sorted.firstIndex(of: "a")!
            let bIndex = sorted.firstIndex(of: "b")!
            let cIndex = sorted.firstIndex(of: "c")!
            XCTAssertLessThan(aIndex, bIndex)
            XCTAssertLessThan(bIndex, cIndex)
        }
    }
}
