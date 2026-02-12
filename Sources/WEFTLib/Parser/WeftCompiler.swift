// WeftCompiler.swift - Native Swift compiler for WEFT language

import Foundation

// MARK: - Compiler Error

public enum WeftCompileError: Error, LocalizedError {
    case preprocessorFailed(PreprocessorError)
    case tokenizationFailed(TokenizerError)
    case parseFailed(ParseError)
    case loweringFailed(LoweringError)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .preprocessorFailed(let error):
            return "Preprocessor error: \(error.localizedDescription)"
        case .tokenizationFailed(let error):
            return "Tokenization error: \(error.localizedDescription)"
        case .parseFailed(let error):
            return "Parse error: \(error.localizedDescription)"
        case .loweringFailed(let error):
            return "Lowering error: \(error.localizedDescription)"
        case .internalError(let msg):
            return "Internal error: \(msg)"
        }
    }
}

// MARK: - WEFT Compiler

/// Native Swift compiler for WEFT language
/// Replaces the JavaScript-based WeftJSCompiler
public class WeftCompiler {

    // Singleton for convenience
    public static let shared = WeftCompiler()

    /// Whether to prepend the standard library to user code
    /// When false (default), users must explicitly #include "core.weft" or individual modules
    public var includeStdlib: Bool = false

    /// Additional search paths for #include directives
    public var includePaths: [String] = []

    /// The preprocessor used for #include handling
    public private(set) var preprocessor: WeftPreprocessor

    /// Last compilation's source map (for error location mapping)
    public private(set) var lastSourceMap: SourceMap?

    public init() {
        self.preprocessor = WeftPreprocessor()
        // Set up stdlib path from bundle resources if available
        if let stdlibURL = WeftStdlib.directoryURL {
            preprocessor.stdlibPath = stdlibURL.path
        }
    }

    // MARK: - Public API

    /// Compile WEFT source code directly to IR
    /// - Parameters:
    ///   - source: The WEFT source code
    ///   - path: Optional source file path for #include resolution (default: "<string>")
    public func compile(_ source: String, path: String = "<string>") throws -> IRProgram {
        do {
            preprocessor.searchPaths = includePaths

            let preprocessResult: PreprocessorResult
            if includeStdlib {
                preprocessResult = try preprocessor.preprocessWithStdlib(
                    source,
                    path: path,
                    stdlibSource: WeftStdlib.source
                )
            } else {
                preprocessResult = try preprocessor.preprocess(source, path: path)
            }

            self.lastSourceMap = preprocessResult.sourceMap

            let tokens = try WeftTokenizer(source: preprocessResult.source).tokenize()
            let ast = try WeftParser(tokens: tokens).parse()
            let desugaredAST = WeftDesugar().desugar(ast)
            let ir = try WeftLowering().lower(desugaredAST)

            return ir

        } catch let error as PreprocessorError {
            throw WeftCompileError.preprocessorFailed(error)
        } catch let error as TokenizerError {
            throw WeftCompileError.tokenizationFailed(error)
        } catch let error as ParseError {
            throw WeftCompileError.parseFailed(error)
        } catch let error as LoweringError {
            throw WeftCompileError.loweringFailed(error)
        } catch {
            throw WeftCompileError.internalError(error.localizedDescription)
        }
    }

}

// MARK: - Convenience Extensions

extension WeftCompiler {
    /// Compile a WEFT file from disk
    public func compileFile(at path: String) throws -> IRProgram {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let absolutePath = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        return try compile(source, path: absolutePath)
    }

    /// Compile a WEFT file from URL
    public func compileFile(at url: URL) throws -> IRProgram {
        let source = try String(contentsOf: url, encoding: .utf8)
        return try compile(source, path: url.path)
    }

    /// Format an error message with original source location
    /// Uses the source map from the last compilation to map back to original file:line
    public func formatError(processedLine: Int, message: String) -> String {
        guard let sourceMap = lastSourceMap else {
            return "line \(processedLine): \(message)"
        }
        return sourceMap.formatError(processedLine: processedLine, message: message)
    }

    /// Extract the original (pre-preprocessed) source location from a compile error.
    /// Returns `(file, line, column)` for tokenizer/parser errors whose source map entry
    /// points to user code (not `<stdlib>`). Returns nil for lowering, backend, preprocessor
    /// errors, or when the error originated in stdlib.
    public func mappedLocation(for error: WeftCompileError) -> (file: String, line: Int, column: Int)? {
        let loc: SourceLocation?

        switch error {
        case .tokenizationFailed(let e):
            switch e {
            case .unexpectedCharacter(_, let l): loc = l
            case .unterminatedString(let l):     loc = l
            case .invalidNumber(_, let l):       loc = l
            }
        case .parseFailed(let e):
            switch e {
            case .unexpectedToken(_, _, let l):  loc = l
            case .invalidSyntax(_, let l):       loc = l
            case .unexpectedEndOfFile:           loc = nil
            }
        case .preprocessorFailed, .loweringFailed, .internalError:
            loc = nil
        }

        guard let loc else { return nil }

        // Map through source map to get original file:line
        guard let sourceMap = lastSourceMap,
              let entry = sourceMap.originalLocation(forProcessedLine: loc.line) else {
            // No source map — return the raw location (single-file, no includes)
            return (file: "<string>", line: loc.line, column: loc.column)
        }

        // Filter out stdlib errors — those aren't actionable for the user
        if entry.file == "<stdlib>" { return nil }

        return (file: entry.file, line: entry.line, column: loc.column)
    }
}
