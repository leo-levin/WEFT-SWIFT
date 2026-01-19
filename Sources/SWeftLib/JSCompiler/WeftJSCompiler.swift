// WeftJSCompiler.swift - Swift wrapper for the WEFT JS compiler via JavaScriptCore

import Foundation
import JavaScriptCore

// MARK: - Compiler Errors

public enum WeftCompileError: Error, LocalizedError {
    case jsContextCreationFailed
    case ohmLoadFailed(String)
    case compilerLoadFailed(String)
    case compilationFailed(String)
    case parseError(String)
    case jsonParseError(String)

    public var errorDescription: String? {
        switch self {
        case .jsContextCreationFailed:
            return "Failed to create JavaScript context"
        case .ohmLoadFailed(let msg):
            return "Failed to load Ohm.js: \(msg)"
        case .compilerLoadFailed(let msg):
            return "Failed to load WEFT compiler: \(msg)"
        case .compilationFailed(let msg):
            return "Compilation failed: \(msg)"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        case .jsonParseError(let msg):
            return "JSON parse error: \(msg)"
        }
    }
}

// MARK: - WEFT JS Compiler

public class WeftJSCompiler {
    private var context: JSContext?
    private var isInitialized = false

    // Singleton for convenience
    public static let shared = WeftJSCompiler()

    public init() {}

    /// Initialize the JavaScript context with Ohm.js and the WEFT compiler
    public func initialize() throws {
        guard context == nil else { return }

        // Create JSContext
        guard let ctx = JSContext() else {
            throw WeftCompileError.jsContextCreationFailed
        }
        context = ctx

        // Set up exception handler
        ctx.exceptionHandler = { _, exception in
            if let exc = exception {
                print("JSContext exception: \(exc)")
            }
        }

        // Load Ohm.js
        let ohmSource = getOhmSource()
        ctx.evaluateScript(ohmSource)

        if let exception = ctx.exception {
            throw WeftCompileError.ohmLoadFailed(exception.toString())
        }

        // Check that ohm is defined
        let ohmCheck = ctx.evaluateScript("typeof ohm")
        if ohmCheck?.toString() != "object" {
            throw WeftCompileError.ohmLoadFailed("ohm object not found after loading")
        }

        // Load WEFT compiler
        let compilerSource = getCompilerSource()
        ctx.evaluateScript(compilerSource)

        if let exception = ctx.exception {
            throw WeftCompileError.compilerLoadFailed(exception.toString())
        }

        // Check that WeftCompiler is defined
        let compilerCheck = ctx.evaluateScript("typeof WeftCompiler")
        if compilerCheck?.toString() != "object" {
            throw WeftCompileError.compilerLoadFailed("WeftCompiler object not found after loading")
        }

        isInitialized = true
    }

    /// Compile WEFT source code to IR JSON string
    public func compileToJSON(_ source: String) throws -> String {
        if !isInitialized {
            try initialize()
        }

        guard let ctx = context else {
            throw WeftCompileError.jsContextCreationFailed
        }

        // Escape the source for JavaScript
        let escapedSource = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        // Call WeftCompiler.compile()
        let script = "WeftCompiler.compile(\"\(escapedSource)\")"
        let result = ctx.evaluateScript(script)

        if let exception = ctx.exception {
            let errorMsg = exception.toString() ?? "Unknown error"
            ctx.exception = nil  // Clear the exception
            throw WeftCompileError.compilationFailed(errorMsg)
        }

        guard let jsonString = result?.toString(), jsonString != "undefined" else {
            throw WeftCompileError.compilationFailed("Compilation returned undefined")
        }

        return jsonString
    }

    /// Parse WEFT source code to AST JSON string
    public func parseToAST(_ source: String) throws -> String {
        if !isInitialized {
            try initialize()
        }

        guard let ctx = context else {
            throw WeftCompileError.jsContextCreationFailed
        }

        // Escape the source for JavaScript
        let escapedSource = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        // Call WeftCompiler.parseToAST()
        let script = "WeftCompiler.parseToAST(\"\(escapedSource)\")"
        let result = ctx.evaluateScript(script)

        if let exception = ctx.exception {
            let errorMsg = exception.toString() ?? "Unknown error"
            ctx.exception = nil  // Clear the exception
            throw WeftCompileError.parseError(errorMsg)
        }

        guard let jsonString = result?.toString(), jsonString != "undefined" else {
            throw WeftCompileError.parseError("Parse returned undefined")
        }

        return jsonString
    }

    /// Compile WEFT source code directly to IR
    public func compile(_ source: String) throws -> IRProgram {
        let json = try compileToJSON(source)

        guard let data = json.data(using: .utf8) else {
            throw WeftCompileError.jsonParseError("Could not convert JSON to data")
        }

        let parser = IRParser()
        do {
            return try parser.parse(data: data)
        } catch {
            // Include the actual JSON in the error for debugging
            let preview = String(json.prefix(500))
            throw WeftCompileError.jsonParseError("Parse failed: \(error.localizedDescription)\n\nJSON preview:\n\(preview)")
        }
    }

    // MARK: - Private Methods

    /// Get the Ohm.js source code (minified)
    private func getOhmSource() -> String {
        // Try Bundle.module (SPM resources)
        if let url = Bundle.module.url(forResource: "ohm.min", withExtension: "js"),
           let source = try? String(contentsOf: url) {
            return source
        }

        // Try to load from main bundle
        if let url = Bundle.main.url(forResource: "ohm.min", withExtension: "js"),
           let source = try? String(contentsOf: url) {
            return source
        }

        print("Warning: Could not load ohm.min.js from bundle")
        return ""
    }

    /// Get the WEFT compiler source code
    private func getCompilerSource() -> String {
        // Try Bundle.module (SPM resources)
        if let url = Bundle.module.url(forResource: "weft-compiler", withExtension: "js"),
           let source = try? String(contentsOf: url) {
            return source
        }

        // Try to load from main bundle
        if let url = Bundle.main.url(forResource: "weft-compiler", withExtension: "js"),
           let source = try? String(contentsOf: url) {
            return source
        }

        print("Warning: Could not load weft-compiler.js from bundle")
        return ""
    }
}
