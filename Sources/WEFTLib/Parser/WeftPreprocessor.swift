// WeftPreprocessor.swift - Preprocessor for WEFT #include directives

import Foundation

// MARK: - Preprocessor Error

public enum PreprocessorError: Error, LocalizedError {
    case fileNotFound(path: String, includedFrom: String, line: Int)
    case circularInclude(cycle: String)
    case emptyIncludePath(file: String, line: Int)
    case invalidIncludeSyntax(file: String, line: Int, content: String)
    case fileReadError(path: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path, let includedFrom, let line):
            return "#include \"\(path)\" - file not found\n  included from \(includedFrom):\(line)"
        case .circularInclude(let cycle):
            return "Circular include detected: \(cycle)"
        case .emptyIncludePath(let file, let line):
            return "\(file):\(line): #include with empty path"
        case .invalidIncludeSyntax(let file, let line, let content):
            return "\(file):\(line): Invalid #include syntax: \(content)"
        case .fileReadError(let path, let underlying):
            return "Failed to read \(path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Source Map

/// Maps processed line numbers back to original file locations
public struct SourceMap {
    /// Each entry maps a processed line number (index) to original file:line
    public struct Entry: Equatable {
        public let file: String
        public let line: Int

        public init(file: String, line: Int) {
            self.file = file
            self.line = line
        }
    }

    /// Line mappings (0-indexed array, but line numbers are 1-based)
    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func addLine(file: String, line: Int) {
        entries.append(Entry(file: file, line: line))
    }

    /// Insert an entry at a specific index (used for synthetic lines like join newlines)
    public mutating func insert(_ entry: Entry, at index: Int) {
        entries.insert(entry, at: index)
    }

    /// Get original location for a processed line number (1-based)
    public func originalLocation(forProcessedLine line: Int) -> Entry? {
        let index = line - 1
        guard index >= 0 && index < entries.count else { return nil }
        return entries[index]
    }

    /// Format an error message with source location
    public func formatError(processedLine: Int, message: String) -> String {
        guard let location = originalLocation(forProcessedLine: processedLine) else {
            return "line \(processedLine): \(message)"
        }
        return "\(location.file):\(location.line): \(message)"
    }
}

// MARK: - Preprocessor Result

public struct PreprocessorResult {
    /// The fully processed source code with all includes expanded
    public let source: String

    /// Source map for error location mapping
    public let sourceMap: SourceMap

    /// Set of all files that were included (for debugging/caching)
    public let includedFiles: Set<String>
}

// MARK: - WEFT Preprocessor

/// Preprocessor for WEFT source code that handles #include directives
public class WeftPreprocessor {

    /// Search paths for include files (in order of priority)
    public var searchPaths: [String] = []

    /// Optional stdlib directory path
    public var stdlibPath: String?

    public init() {}

    // MARK: - Public API

    /// Preprocess source code from a file path
    /// - Parameters:
    ///   - path: Path to the source file
    /// - Returns: Preprocessed result with expanded includes
    public func preprocessFile(at path: String) throws -> PreprocessorResult {
        let source = try readFile(at: path)
        let absolutePath = absolutize(path: path)
        return try preprocess(source, path: absolutePath)
    }

    /// Preprocess source code from a string
    /// - Parameters:
    ///   - source: The source code string
    ///   - path: Virtual path for error reporting (default: "<string>")
    /// - Returns: Preprocessed result with expanded includes
    public func preprocess(_ source: String, path: String = "<string>") throws -> PreprocessorResult {
        var sourceMap = SourceMap()
        var includedFiles = Set<String>()
        let processed = try processSource(
            source,
            currentFile: path,
            includeStack: [],
            includedFiles: &includedFiles,
            sourceMap: &sourceMap
        )
        return PreprocessorResult(
            source: processed,
            sourceMap: sourceMap,
            includedFiles: includedFiles
        )
    }

    /// Preprocess source with stdlib auto-included
    /// - Parameters:
    ///   - source: User source code
    ///   - path: Virtual path for user code
    ///   - stdlibSource: Standard library source to prepend
    /// - Returns: Preprocessed result
    public func preprocessWithStdlib(
        _ source: String,
        path: String = "<string>",
        stdlibSource: String
    ) throws -> PreprocessorResult {
        var sourceMap = SourceMap()
        var includedFiles = Set<String>()

        // Process stdlib first
        let processedStdlib = try processSource(
            stdlibSource,
            currentFile: "<stdlib>",
            includeStack: [],
            includedFiles: &includedFiles,
            sourceMap: &sourceMap
        )

        // Record where stdlib entries end — the synthetic newline goes here
        let stdlibEntryCount = sourceMap.entries.count

        // Then process user source
        let processedUser = try processSource(
            source,
            currentFile: path,
            includeStack: [],
            includedFiles: &includedFiles,
            sourceMap: &sourceMap
        )

        let combined = processedStdlib + "\n" + processedUser

        // Insert the synthetic newline entry BETWEEN stdlib and user entries
        sourceMap.insert(SourceMap.Entry(file: "<stdlib>", line: 0), at: stdlibEntryCount)

        return PreprocessorResult(
            source: combined,
            sourceMap: sourceMap,
            includedFiles: includedFiles
        )
    }

    // MARK: - Private Implementation

    /// Regex pattern for #include directive
    /// Matches: #include "path" with optional leading whitespace and trailing comment
    /// Does NOT match if inside a comment (handled separately)
    private static let includePattern = try! NSRegularExpression(
        pattern: #"^(\s*)#include\s+"([^"]*)"(\s*(//.*)?)?$"#,
        options: []
    )

    /// Process source code, expanding includes
    private func processSource(
        _ source: String,
        currentFile: String,
        includeStack: [String],
        includedFiles: inout Set<String>,
        sourceMap: inout SourceMap
    ) throws -> String {
        // Check for circular includes
        if includeStack.contains(currentFile) {
            let cycle = (includeStack + [currentFile]).joined(separator: " → ")
            throw PreprocessorError.circularInclude(cycle: cycle)
        }

        let newStack = includeStack + [currentFile]
        let lines = source.components(separatedBy: "\n")
        var outputLines: [String] = []
        var inBlockComment = false

        for (lineIndex, line) in lines.enumerated() {
            let lineNumber = lineIndex + 1

            // Track block comments
            let (updatedInBlock, isCommented) = checkCommentState(line: line, inBlockComment: inBlockComment)
            inBlockComment = updatedInBlock

            // Skip include processing if we're in a comment
            if isCommented {
                outputLines.append(line)
                sourceMap.addLine(file: currentFile, line: lineNumber)
                continue
            }

            // Check if this line has an include directive (not in a comment)
            if let includePath = parseIncludeDirective(line: line, isInComment: false) {
                // Validate non-empty path
                guard !includePath.isEmpty else {
                    throw PreprocessorError.emptyIncludePath(file: currentFile, line: lineNumber)
                }

                // Resolve the include path
                let resolvedPath = try resolvePath(
                    includePath,
                    relativeTo: currentFile,
                    includedFrom: currentFile,
                    line: lineNumber
                )

                // Check include guard - skip if already included
                if includedFiles.contains(resolvedPath) {
                    // Add a blank line to maintain structure but skip content
                    outputLines.append("// (already included: \(includePath))")
                    sourceMap.addLine(file: currentFile, line: lineNumber)
                    continue
                }

                // Mark as included
                includedFiles.insert(resolvedPath)

                // Read and process the included file
                let includedSource = try readFile(at: resolvedPath)
                let processed = try processSource(
                    includedSource,
                    currentFile: resolvedPath,
                    includeStack: newStack,
                    includedFiles: &includedFiles,
                    sourceMap: &sourceMap
                )

                // Add processed content — split into individual lines so
                // outputLines.count stays in sync with sourceMap.entries.count.
                // The recursive processSource call already added one sourceMap
                // entry per line, so we must add one outputLines element per line.
                let includedLines = processed.components(separatedBy: "\n")
                outputLines.append(contentsOf: includedLines)
            } else {
                // Regular line - add to output
                outputLines.append(line)
                sourceMap.addLine(file: currentFile, line: lineNumber)
            }
        }

        return outputLines.joined(separator: "\n")
    }

    /// Parse an #include directive from a line
    /// Returns the include path if found, nil otherwise
    private func parseIncludeDirective(line: String, isInComment: Bool) -> String? {
        // Don't parse includes inside comments
        if isInComment { return nil }

        // Check if line starts with // comment
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return nil }

        // Check for #include with regex
        let range = NSRange(line.startIndex..., in: line)
        guard let match = Self.includePattern.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        // Extract the path from capture group 2
        guard let pathRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        return String(line[pathRange])
    }

    /// Check comment state for a line
    /// Returns (newInBlockComment, isCurrentLineCommented)
    private func checkCommentState(line: String, inBlockComment: Bool) -> (Bool, Bool) {
        var inBlock = inBlockComment
        var isCommented = inBlockComment

        // Simple state machine for block comments
        var i = line.startIndex
        while i < line.endIndex {
            let remaining = line[i...]

            if inBlock {
                if remaining.hasPrefix("*/") {
                    inBlock = false
                    i = line.index(i, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                    continue
                }
            } else {
                if remaining.hasPrefix("/*") {
                    inBlock = true
                    isCommented = true
                    i = line.index(i, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                    continue
                }
                if remaining.hasPrefix("//") {
                    // Rest of line is commented
                    break
                }
            }
            i = line.index(after: i)
        }

        return (inBlock, isCommented)
    }

    /// Resolve an include path to an absolute path
    private func resolvePath(
        _ includePath: String,
        relativeTo currentFile: String,
        includedFrom: String,
        line: Int
    ) throws -> String {
        // If already absolute, check if it exists
        if includePath.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: includePath) {
                return includePath
            }
            throw PreprocessorError.fileNotFound(path: includePath, includedFrom: includedFrom, line: line)
        }

        // Search order:
        // 1. Relative to current file's directory
        // 2. Search paths
        // 3. Stdlib path

        var searchLocations: [String] = []

        // 1. Current file's directory
        if currentFile != "<string>" && currentFile != "<stdlib>" {
            let currentDir = (currentFile as NSString).deletingLastPathComponent
            let relativePath = (currentDir as NSString).appendingPathComponent(includePath)
            searchLocations.append(relativePath)
        }

        // 2. Configured search paths
        for searchPath in searchPaths {
            let candidate = (searchPath as NSString).appendingPathComponent(includePath)
            searchLocations.append(candidate)
        }

        // 3. Stdlib path
        if let stdlib = stdlibPath {
            let candidate = (stdlib as NSString).appendingPathComponent(includePath)
            searchLocations.append(candidate)
        }

        // Try each location
        for location in searchLocations {
            let normalized = absolutize(path: location)
            if FileManager.default.fileExists(atPath: normalized) {
                return normalized
            }
        }

        throw PreprocessorError.fileNotFound(path: includePath, includedFrom: includedFrom, line: line)
    }

    /// Read a file's contents
    private func readFile(at path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw PreprocessorError.fileReadError(path: path, underlying: error)
        }
    }

    /// Convert a path to absolute
    private func absolutize(path: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(path)
    }
}

// MARK: - Convenience Extensions

extension WeftPreprocessor {
    /// Create a preprocessor configured with standard search paths
    public static func standard(stdlibPath: String? = nil) -> WeftPreprocessor {
        let preprocessor = WeftPreprocessor()
        preprocessor.stdlibPath = stdlibPath
        return preprocessor
    }
}
