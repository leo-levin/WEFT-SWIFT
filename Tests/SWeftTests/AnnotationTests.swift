// AnnotationTests.swift - Tests for domain/access annotation system

import XCTest
@testable import SWeftLib

final class AnnotationTests: XCTestCase {

    func testCameraHardwarePropagation() throws {
        // Test program with camera input - hardware should propagate through references
        let json = """
        {
            "bundles": {
                "img": {
                    "name": "img",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {"type": "builtin", "name": "camera", "args": [
                            {"type": "index", "bundle": "me", "field": "x"},
                            {"type": "index", "bundle": "me", "field": "y"},
                            {"type": "num", "value": 0}
                        ]}},
                        {"name": "g", "index": 1, "expr": {"type": "builtin", "name": "camera", "args": [
                            {"type": "index", "bundle": "me", "field": "x"},
                            {"type": "index", "bundle": "me", "field": "y"},
                            {"type": "num", "value": 1}
                        ]}},
                        {"name": "b", "index": 2, "expr": {"type": "builtin", "name": "camera", "args": [
                            {"type": "index", "bundle": "me", "field": "x"},
                            {"type": "index", "bundle": "me", "field": "y"},
                            {"type": "num", "value": 2}
                        ]}}
                    ]
                },
                "display": {
                    "name": "display",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {"type": "index", "bundle": "img", "field": "r"}},
                        {"name": "g", "index": 1, "expr": {"type": "index", "bundle": "img", "field": "g"}},
                        {"name": "b", "index": 2, "expr": {"type": "index", "bundle": "img", "field": "b"}}
                    ]
                }
            },
            "spindles": {},
            "order": [
                {"bundle": "img", "strands": ["r", "g", "b"]},
                {"bundle": "display", "strands": ["r", "g", "b"]}
            ],
            "resources": []
        }
        """

        let parser = IRParser()
        let program = try parser.parse(json: json)

        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = annotationPass.annotate()

        // img should be external with camera hardware
        let imgSignal = annotated.signals["img.r"]!
        XCTAssertTrue(imgSignal.hardware.contains(.camera), "img.r should require camera hardware")
        XCTAssertTrue(imgSignal.isExternal, "img.r should be external")
        XCTAssertEqual(imgSignal.domain.count, 3, "img.r should have 3 dimensions (x, y, t)")
        XCTAssertTrue(imgSignal.domain.contains { $0.name == "x" && $0.access == .free })
        XCTAssertTrue(imgSignal.domain.contains { $0.name == "y" && $0.access == .free })
        XCTAssertTrue(imgSignal.domain.contains { $0.name == "t" && $0.access == .bound })

        // display inherits hardware from img
        let displaySignal = annotated.signals["display.r"]!
        XCTAssertTrue(displaySignal.hardware.contains(.camera), "display.r should inherit camera hardware")
        XCTAssertTrue(displaySignal.isExternal, "display.r should be external")

        // Verify backend routing via hardware
        let imgHardware = annotated.bundleHardware("img")
        let displayHardware = annotated.bundleHardware("display")
        XCTAssertEqual(BackendRegistry.shared.backendFor(hardware: imgHardware), "visual")
        XCTAssertEqual(BackendRegistry.shared.backendFor(hardware: displayHardware), "visual")
    }

    func testRemapReducesDomain() throws {
        // img.r(me.x ~ 0.5) should have x removed from domain
        let json = """
        {
            "bundles": {
                "img": {
                    "name": "img",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {"type": "builtin", "name": "camera", "args": [
                            {"type": "index", "bundle": "me", "field": "x"},
                            {"type": "index", "bundle": "me", "field": "y"},
                            {"type": "num", "value": 0}
                        ]}}
                    ]
                },
                "sampled": {
                    "name": "sampled",
                    "strands": [
                        {"name": "r", "index": 0, "expr": {
                            "type": "remap",
                            "base": {"type": "index", "bundle": "img", "field": "r"},
                            "substitutions": {
                                "me.x": {"type": "num", "value": 0.5}
                            }
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

        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = annotationPass.annotate()

        // img.r has domain (x, y, t)
        let imgSignal = annotated.signals["img.r"]!
        XCTAssertTrue(imgSignal.domain.contains { $0.name == "x" }, "img.r should have x in domain")
        XCTAssertTrue(imgSignal.domain.contains { $0.name == "y" }, "img.r should have y in domain")
        XCTAssertTrue(imgSignal.domain.contains { $0.name == "t" }, "img.r should have t in domain")

        // sampled.r has domain (y, t) - x removed by remap with constant
        let sampledSignal = annotated.signals["sampled.r"]!
        XCTAssertFalse(sampledSignal.domain.contains { $0.name == "x" }, "sampled.r should NOT have x (remapped to constant)")
        XCTAssertTrue(sampledSignal.domain.contains { $0.name == "y" }, "sampled.r should have y in domain")
        XCTAssertTrue(sampledSignal.domain.contains { $0.name == "t" }, "sampled.r should have t in domain")

        // Both should still have camera hardware
        XCTAssertTrue(sampledSignal.hardware.contains(.camera))
    }

    func testPureExpressionHasEmptyHardware() throws {
        // Pure math expression: me.x + me.y
        let json = """
        {
            "bundles": {
                "sum": {
                    "name": "sum",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "binary", "op": "+",
                            "left": {"type": "index", "bundle": "me", "field": "x"},
                            "right": {"type": "index", "bundle": "me", "field": "y"}
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

        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = annotationPass.annotate()

        let sumSignal = annotated.signals["sum.val"]!
        XCTAssertTrue(sumSignal.isPure, "sum.val should be pure")
        XCTAssertTrue(sumSignal.hardware.isEmpty, "sum.val should have no hardware requirements")
        XCTAssertFalse(sumSignal.stateful, "sum.val should not be stateful")

        // Domain should have x and y (both free)
        XCTAssertTrue(sumSignal.domain.contains { $0.name == "x" && $0.access == .free })
        XCTAssertTrue(sumSignal.domain.contains { $0.name == "y" && $0.access == .free })
    }

    func testCacheIsStateful() throws {
        // cache(value, historySize, tapIndex, signal)
        let json = """
        {
            "bundles": {
                "cached": {
                    "name": "cached",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
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

        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = annotationPass.annotate()

        let cachedSignal = annotated.signals["cached.val"]!
        XCTAssertTrue(cachedSignal.stateful, "cached.val should be stateful")
        XCTAssertFalse(cachedSignal.isPure, "cached.val should not be pure (stateful)")
    }

    func testBoundDimensionPropagation() throws {
        // Using me.t (bound) should mark signal as having bound dimensions
        let json = """
        {
            "bundles": {
                "animated": {
                    "name": "animated",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "builtin", "name": "sin", "args": [
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

        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: MetalBackend.coordinateSpecs,
            primitiveSpecs: MetalBackend.primitiveSpecs
        )
        let annotated = annotationPass.annotate()

        let animatedSignal = annotated.signals["animated.val"]!
        XCTAssertEqual(animatedSignal.boundDimensions, ["t"], "animated.val should have t as bound dimension")
        XCTAssertTrue(animatedSignal.freeDimensions.isEmpty, "animated.val should have no free dimensions")
    }

    func testAudioCoordinates() throws {
        // Audio domain coordinates: me.i, me.t (both free in audio), me.sampleRate (bound)
        let json = """
        {
            "bundles": {
                "tone": {
                    "name": "tone",
                    "strands": [
                        {"name": "val", "index": 0, "expr": {
                            "type": "builtin", "name": "sin", "args": [
                                {"type": "binary", "op": "*",
                                    "left": {"type": "binary", "op": "/",
                                        "left": {"type": "index", "bundle": "me", "field": "i"},
                                        "right": {"type": "index", "bundle": "me", "field": "sampleRate"}
                                    },
                                    "right": {"type": "num", "value": 2764.6}
                                }
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

        // Use audio coordinate specs
        let annotationPass = AnnotationPass(
            program: program,
            coordinateSpecs: AudioBackend.coordinateSpecs,
            primitiveSpecs: AudioBackend.primitiveSpecs
        )
        let annotated = annotationPass.annotate()

        let toneSignal = annotated.signals["tone.val"]!
        XCTAssertTrue(toneSignal.isPure, "tone.val should be pure (no hardware, no state)")
        XCTAssertTrue(toneSignal.domain.contains { $0.name == "i" && $0.access == .free })
        XCTAssertTrue(toneSignal.domain.contains { $0.name == "sampleRate" && $0.access == .bound })
    }
}
