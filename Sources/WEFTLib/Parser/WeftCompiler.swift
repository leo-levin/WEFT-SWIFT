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
            // Update preprocessor search paths
            preprocessor.searchPaths = includePaths

            // Preprocess (handle #include directives)
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

            // Store source map for error reporting
            self.lastSourceMap = preprocessResult.sourceMap

            // Tokenize
            let tokenizer = WeftTokenizer(source: preprocessResult.source)
            let tokens = try tokenizer.tokenize()

            // Parse
            let parser = WeftParser(tokens: tokens)
            let ast = try parser.parse()

            // Desugar tag expressions into synthetic bundles
            let desugar = WeftDesugar()
            let desugaredAST = desugar.desugar(ast)

            // Lower to IR
            let lowering = WeftLowering()
            return try lowering.lower(desugaredAST)

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

    /// Compile WEFT source code to IR JSON string
    public func compileToJSON(_ source: String) throws -> String {
        let ir = try compile(source)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(ir)

        guard let json = String(data: data, encoding: .utf8) else {
            throw WeftCompileError.internalError("Failed to encode IR to JSON")
        }

        return json
    }

    /// Parse WEFT source code to AST (for debugging/tooling)
    public func parseToAST(_ source: String) throws -> WeftProgram {
        do {
            let parser = try WeftParser(source: source)
            return try parser.parse()
        } catch let error as TokenizerError {
            throw WeftCompileError.tokenizationFailed(error)
        } catch let error as ParseError {
            throw WeftCompileError.parseFailed(error)
        } catch {
            throw WeftCompileError.internalError(error.localizedDescription)
        }
    }

    /// Parse WEFT source code to AST JSON string (for debugging/tooling)
    public func parseToASTJSON(_ source: String) throws -> String {
        // For now, just return a simple description since AST isn't Codable
        let ast = try parseToAST(source)

        var result = "{\n  \"statements\": [\n"
        for (i, stmt) in ast.statements.enumerated() {
            result += "    \"\(stmt)\""
            if i < ast.statements.count - 1 {
                result += ","
            }
            result += "\n"
        }
        result += "  ]\n}"

        return result
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
}
