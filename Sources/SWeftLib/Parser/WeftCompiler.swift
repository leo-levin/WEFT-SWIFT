// WeftCompiler.swift - Native Swift compiler for WEFT language

import Foundation

// MARK: - Compiler Error

public enum WeftCompileError: Error, LocalizedError {
    case tokenizationFailed(TokenizerError)
    case parseFailed(ParseError)
    case loweringFailed(LoweringError)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
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
    public var includeStdlib: Bool = true

    public init() {}

    // MARK: - Public API

    /// Compile WEFT source code directly to IR
    public func compile(_ source: String) throws -> IRProgram {
        do {
            // Prepend stdlib if enabled
            let fullSource = includeStdlib ? (WeftStdlib.source + "\n" + source) : source

            // Tokenize
            let tokenizer = WeftTokenizer(source: fullSource)
            let tokens = try tokenizer.tokenize()

            // Parse
            let parser = WeftParser(tokens: tokens)
            let ast = try parser.parse()

            // Lower to IR
            let lowering = WeftLowering()
            return try lowering.lower(ast)

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
        return try compile(source)
    }

    /// Compile a WEFT file from URL
    public func compileFile(at url: URL) throws -> IRProgram {
        let source = try String(contentsOf: url, encoding: .utf8)
        return try compile(source)
    }
}
