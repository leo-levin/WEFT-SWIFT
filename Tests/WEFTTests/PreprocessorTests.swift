// PreprocessorTests.swift - Tests for the WEFT preprocessor #include functionality

import XCTest
@testable import WEFTLib

final class PreprocessorTests: XCTestCase {

    var preprocessor: WeftPreprocessor!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        preprocessor = WeftPreprocessor()

        // Create a temporary directory for test files
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeftPreprocessorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helper Methods

    func createTempFile(_ name: String, content: String) throws -> String {
        let path = tempDir.appendingPathComponent(name).path
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func createSubdir(_ name: String) throws -> URL {
        let subdir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        return subdir
    }

    // MARK: - Basic Include Tests

    func testBasicInclude() throws {
        // Create included file
        let helperContent = """
        spindle helper(x) {
            return.0 = x * 2
        }
        """
        let helperPath = try createTempFile("helper.weft", content: helperContent)

        // Create main file with include
        let mainContent = """
        #include "helper.weft"

        display[r,g,b] = [helper(me.x), 0, 0]
        """
        let mainPath = try createTempFile("main.weft", content: mainContent)

        // Process
        let result = try preprocessor.preprocessFile(at: mainPath)

        // Verify helper content was included
        XCTAssertTrue(result.source.contains("spindle helper(x)"))
        XCTAssertTrue(result.source.contains("return.0 = x * 2"))
        XCTAssertTrue(result.source.contains("display[r,g,b]"))

        // Verify source map
        XCTAssertFalse(result.includedFiles.isEmpty)
    }

    func testNestedIncludes() throws {
        // Create file C (deepest)
        let fileC = """
        spindle multiply(a, b) {
            return.0 = a * b
        }
        """
        try createTempFile("fileC.weft", content: fileC)

        // Create file B (includes C)
        let fileB = """
        #include "fileC.weft"

        spindle addAndMultiply(a, b, c) {
            return.0 = multiply(a + b, c)
        }
        """
        try createTempFile("fileB.weft", content: fileB)

        // Create file A (includes B)
        let fileA = """
        #include "fileB.weft"

        result.val = addAndMultiply(1, 2, 3)
        """
        let mainPath = try createTempFile("fileA.weft", content: fileA)

        let result = try preprocessor.preprocessFile(at: mainPath)

        // All content should be present
        XCTAssertTrue(result.source.contains("spindle multiply"))
        XCTAssertTrue(result.source.contains("spindle addAndMultiply"))
        XCTAssertTrue(result.source.contains("result.val"))
    }

    // MARK: - Include Guard Tests (Diamond Dependency)

    func testDiamondDependency() throws {
        // Create shared dependency D
        let fileD = """
        spindle shared(x) {
            return.0 = x
        }
        """
        try createTempFile("fileD.weft", content: fileD)

        // Create B (includes D)
        let fileB = """
        #include "fileD.weft"
        spindle fromB(x) { return.0 = shared(x) }
        """
        try createTempFile("fileB.weft", content: fileB)

        // Create C (includes D)
        let fileC = """
        #include "fileD.weft"
        spindle fromC(x) { return.0 = shared(x) }
        """
        try createTempFile("fileC.weft", content: fileC)

        // Create A (includes B and C - diamond)
        let fileA = """
        #include "fileB.weft"
        #include "fileC.weft"

        result.val = fromB(1) + fromC(2)
        """
        let mainPath = try createTempFile("fileA.weft", content: fileA)

        let result = try preprocessor.preprocessFile(at: mainPath)

        // D should only appear once (include guard)
        let occurrences = result.source.components(separatedBy: "spindle shared(x)").count - 1
        XCTAssertEqual(occurrences, 1, "Shared file should only be included once")

        // But both B and C spindles should be present
        XCTAssertTrue(result.source.contains("spindle fromB"))
        XCTAssertTrue(result.source.contains("spindle fromC"))
    }

    // MARK: - Circular Include Detection

    func testCircularIncludeDetection() throws {
        // Create two files that include each other
        let fileA = """
        #include "fileB.weft"
        spindle fromA(x) { return.0 = x }
        """
        try createTempFile("fileA.weft", content: fileA)

        let fileB = """
        #include "fileA.weft"
        spindle fromB(x) { return.0 = x }
        """
        let pathB = try createTempFile("fileB.weft", content: fileB)

        // Should throw circular include error
        XCTAssertThrowsError(try preprocessor.preprocessFile(at: pathB)) { error in
            guard case PreprocessorError.circularInclude(let cycle) = error else {
                XCTFail("Expected circularInclude error, got \(error)")
                return
            }
            XCTAssertTrue(cycle.contains("fileA.weft"))
            XCTAssertTrue(cycle.contains("fileB.weft"))
        }
    }

    func testSelfIncludeDetection() throws {
        // Create file that includes itself
        let selfInclude = """
        #include "self.weft"
        spindle test(x) { return.0 = x }
        """
        let path = try createTempFile("self.weft", content: selfInclude)

        XCTAssertThrowsError(try preprocessor.preprocessFile(at: path)) { error in
            guard case PreprocessorError.circularInclude = error else {
                XCTFail("Expected circularInclude error")
                return
            }
        }
    }

    // MARK: - Error Handling Tests

    func testFileNotFound() throws {
        let source = """
        #include "nonexistent.weft"
        display[r,g,b] = [0, 0, 0]
        """
        let path = try createTempFile("main.weft", content: source)

        XCTAssertThrowsError(try preprocessor.preprocessFile(at: path)) { error in
            guard case PreprocessorError.fileNotFound(let missingPath, _, _) = error else {
                XCTFail("Expected fileNotFound error, got \(error)")
                return
            }
            XCTAssertEqual(missingPath, "nonexistent.weft")
        }
    }

    func testEmptyIncludePath() throws {
        let source = """
        #include ""
        display[r,g,b] = [0, 0, 0]
        """
        let path = try createTempFile("main.weft", content: source)

        XCTAssertThrowsError(try preprocessor.preprocessFile(at: path)) { error in
            guard case PreprocessorError.emptyIncludePath = error else {
                XCTFail("Expected emptyIncludePath error, got \(error)")
                return
            }
        }
    }

    // MARK: - Comment Handling Tests

    func testIncludeInLineCommentIgnored() throws {
        // Include in comment should be ignored
        let source = """
        // #include "doesnotexist.weft"
        display[r,g,b] = [0, 0, 0]
        """

        let result = try preprocessor.preprocess(source, path: "<test>")

        // Should process without error (include is commented out)
        XCTAssertTrue(result.source.contains("display[r,g,b]"))
        XCTAssertTrue(result.source.contains("// #include"))
    }

    func testIncludeInBlockCommentIgnored() throws {
        let source = """
        /*
        #include "doesnotexist.weft"
        */
        display[r,g,b] = [0, 0, 0]
        """

        let result = try preprocessor.preprocess(source, path: "<test>")

        // Should process without error
        XCTAssertTrue(result.source.contains("display[r,g,b]"))
    }

    // MARK: - Whitespace Variations

    func testIncludeWithLeadingWhitespace() throws {
        let helper = "spindle helper(x) { return.0 = x }"
        try createTempFile("helper.weft", content: helper)

        let source = """
            #include "helper.weft"
        display[r,g,b] = [helper(me.x), 0, 0]
        """
        let path = try createTempFile("main.weft", content: source)

        let result = try preprocessor.preprocessFile(at: path)
        XCTAssertTrue(result.source.contains("spindle helper"))
    }

    func testIncludeWithExtraSpaces() throws {
        let helper = "spindle helper(x) { return.0 = x }"
        try createTempFile("helper.weft", content: helper)

        let source = """
        #include   "helper.weft"
        display[r,g,b] = [helper(me.x), 0, 0]
        """
        let path = try createTempFile("main.weft", content: source)

        let result = try preprocessor.preprocessFile(at: path)
        XCTAssertTrue(result.source.contains("spindle helper"))
    }

    // MARK: - Path Resolution Tests

    func testRelativePathResolution() throws {
        // Create subdirectory
        let subdir = try createSubdir("lib")

        // Create helper in subdirectory
        let helper = "spindle helper(x) { return.0 = x }"
        let helperPath = subdir.appendingPathComponent("helper.weft").path
        try helper.write(toFile: helperPath, atomically: true, encoding: .utf8)

        // Create main file that includes from subdirectory
        let source = """
        #include "lib/helper.weft"
        display[r,g,b] = [helper(me.x), 0, 0]
        """
        let mainPath = try createTempFile("main.weft", content: source)

        let result = try preprocessor.preprocessFile(at: mainPath)
        XCTAssertTrue(result.source.contains("spindle helper"))
    }

    func testSearchPathResolution() throws {
        // Create a library directory
        let libDir = try createSubdir("mylib")

        // Create helper in library directory
        let helper = "spindle libHelper(x) { return.0 = x * 3 }"
        let helperPath = libDir.appendingPathComponent("helper.weft").path
        try helper.write(toFile: helperPath, atomically: true, encoding: .utf8)

        // Configure search path
        preprocessor.searchPaths = [libDir.path]

        // Create main file (not in same directory as helper)
        let source = """
        #include "helper.weft"
        display[r,g,b] = [libHelper(me.x), 0, 0]
        """
        let mainPath = try createTempFile("main.weft", content: source)

        let result = try preprocessor.preprocessFile(at: mainPath)
        XCTAssertTrue(result.source.contains("spindle libHelper"))
    }

    // MARK: - Source Map Tests

    func testSourceMapBasic() throws {
        let helper = """
        spindle helper(x) {
            return.0 = x * 2
        }
        """
        try createTempFile("helper.weft", content: helper)

        let main = """
        #include "helper.weft"
        display[r,g,b] = [0, 0, 0]
        """
        let mainPath = try createTempFile("main.weft", content: main)

        let result = try preprocessor.preprocessFile(at: mainPath)

        // Check that source map has entries
        XCTAssertFalse(result.sourceMap.entries.isEmpty)

        // First lines should be from helper.weft
        let firstEntry = result.sourceMap.entries[0]
        XCTAssertTrue(firstEntry.file.contains("helper.weft"))
        XCTAssertEqual(firstEntry.line, 1)
    }

    func testSourceMapErrorFormatting() throws {
        var sourceMap = SourceMap()
        sourceMap.addLine(file: "test.weft", line: 1)
        sourceMap.addLine(file: "test.weft", line: 2)
        sourceMap.addLine(file: "included.weft", line: 1)
        sourceMap.addLine(file: "test.weft", line: 3)

        // Format error on processed line 3 (which maps to included.weft:1)
        let formatted = sourceMap.formatError(processedLine: 3, message: "test error")
        XCTAssertTrue(formatted.contains("included.weft"))
        XCTAssertTrue(formatted.contains(":1:"))
    }

    // MARK: - Include Position Tests

    func testIncludeAtEndOfFile() throws {
        let helper = "spindle helper(x) { return.0 = x }"
        try createTempFile("helper.weft", content: helper)

        let source = """
        display[r,g,b] = [0, 0, 0]
        #include "helper.weft"
        """
        let path = try createTempFile("main.weft", content: source)

        let result = try preprocessor.preprocessFile(at: path)
        XCTAssertTrue(result.source.contains("spindle helper"))
        XCTAssertTrue(result.source.contains("display[r,g,b]"))
    }

    func testMultipleIncludes() throws {
        let helper1 = "spindle helper1(x) { return.0 = x }"
        let helper2 = "spindle helper2(x) { return.0 = x * 2 }"
        try createTempFile("helper1.weft", content: helper1)
        try createTempFile("helper2.weft", content: helper2)

        let source = """
        #include "helper1.weft"
        #include "helper2.weft"
        display[r,g,b] = [helper1(me.x), helper2(me.y), 0]
        """
        let path = try createTempFile("main.weft", content: source)

        let result = try preprocessor.preprocessFile(at: path)
        XCTAssertTrue(result.source.contains("spindle helper1"))
        XCTAssertTrue(result.source.contains("spindle helper2"))
    }

    // MARK: - Integration with Compiler

    func testCompilerWithIncludes() throws {
        let helper = """
        spindle double(x) {
            return.0 = x * 2
        }
        """
        try createTempFile("helper.weft", content: helper)

        let source = """
        #include "helper.weft"
        display[r,g,b] = [double(me.x), 0, 0]
        """
        let mainPath = try createTempFile("main.weft", content: source)

        // Compile with stdlib disabled to avoid dependencies
        let compiler = WeftCompiler()
        compiler.includeStdlib = false

        let ir = try compiler.compileFile(at: mainPath)

        // Verify IR contains the spindle
        XCTAssertTrue(ir.spindles.keys.contains("double"))
    }

    func testCompilerWithStdlibIncludes() throws {
        // Test that stdlib + user includes work together
        let helper = """
        spindle userHelper(x) {
            return.0 = x + 1
        }
        """
        try createTempFile("helper.weft", content: helper)

        let source = """
        #include "helper.weft"
        display[r,g,b] = [userHelper(me.x), 0, 0]
        """
        let mainPath = try createTempFile("main.weft", content: source)

        let compiler = WeftCompiler()
        // With stdlib enabled
        compiler.includeStdlib = true

        let ir = try compiler.compileFile(at: mainPath)

        // Should have both stdlib spindles and user spindle
        XCTAssertTrue(ir.spindles.keys.contains("userHelper"))
        // And stdlib noise functions should be available
        XCTAssertTrue(ir.spindles.keys.contains("perlin3"))
    }

    // MARK: - No Include (Pass-through) Tests

    func testNoIncludesPassThrough() throws {
        let source = """
        display[r,g,b] = [me.x, me.y, 0]
        """

        let result = try preprocessor.preprocess(source, path: "<test>")

        // Source should pass through unchanged
        XCTAssertEqual(result.source.trimmingCharacters(in: .whitespacesAndNewlines),
                       source.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
