// WeftTokenizer.swift - Tokenizer for WEFT language (parsing-oriented)

import Foundation

// MARK: - Source Location

public struct SourceLocation: Equatable, CustomStringConvertible {
    public let line: Int      // 1-based
    public let column: Int    // 1-based
    public let offset: Int    // 0-based byte offset

    public init(line: Int = 1, column: Int = 1, offset: Int = 0) {
        self.line = line
        self.column = column
        self.offset = offset
    }

    public var description: String {
        "line \(line), column \(column)"
    }
}

public struct SourceRange: Equatable {
    public let start: SourceLocation
    public let end: SourceLocation

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }
}

// MARK: - Token

public enum Token: Equatable {
    // Keywords
    case spindle
    case `return`

    // Literals
    case identifier(String)
    case number(Double)
    case string(String)

    // Operators - Arithmetic
    case plus           // +
    case minus          // -
    case star           // *
    case slash          // /
    case caret          // ^
    case percent        // %
    case tilde          // ~

    // Operators - Comparison
    case equalEqual     // ==
    case bangEqual      // !=
    case less           // <
    case greater        // >
    case lessEqual      // <=
    case greaterEqual   // >=

    // Operators - Logical
    case ampAmp         // &&
    case pipePipe       // ||
    case bang           // !

    // Punctuation
    case leftParen      // (
    case rightParen     // )
    case leftBracket    // [
    case rightBracket   // ]
    case leftBrace      // {
    case rightBrace     // }
    case comma          // ,
    case equal          // =
    case dot            // .

    // Special
    case arrow          // ->
    case dotDot         // ..

    // Whitespace/Comments (usually skipped, but tracked for location)
    case newline
    case comment(String)

    // End of file
    case eof
}

// MARK: - Located Token

public struct LocatedToken: Equatable {
    public let token: Token
    public let location: SourceLocation
    public let text: String

    public init(token: Token, location: SourceLocation, text: String) {
        self.token = token
        self.location = location
        self.text = text
    }
}

// MARK: - Tokenizer Error

public enum TokenizerError: Error, LocalizedError {
    case unexpectedCharacter(Character, SourceLocation)
    case unterminatedString(SourceLocation)
    case invalidNumber(String, SourceLocation)

    public var errorDescription: String? {
        switch self {
        case .unexpectedCharacter(let char, let loc):
            return "Unexpected character '\(char)' at \(loc)"
        case .unterminatedString(let loc):
            return "Unterminated string at \(loc)"
        case .invalidNumber(let text, let loc):
            return "Invalid number '\(text)' at \(loc)"
        }
    }
}

// MARK: - Tokenizer

public class WeftTokenizer {
    private let source: String
    private var index: String.Index
    private var line: Int = 1
    private var column: Int = 1
    private var offset: Int = 0

    private static let keywords: [String: Token] = [
        "spindle": .spindle,
        "return": .return
    ]

    public init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    // MARK: - Public API

    /// Tokenize the entire source, returning all tokens (excluding whitespace/comments)
    public func tokenize() throws -> [LocatedToken] {
        var tokens: [LocatedToken] = []

        while true {
            let token = try nextToken()

            // Skip whitespace and comments for parsing
            switch token.token {
            case .newline, .comment:
                continue
            case .eof:
                tokens.append(token)
                return tokens
            default:
                tokens.append(token)
            }
        }
    }

    /// Tokenize including all tokens (for syntax highlighting)
    public func tokenizeAll() throws -> [LocatedToken] {
        var tokens: [LocatedToken] = []

        while true {
            let token = try nextToken()
            tokens.append(token)
            if case .eof = token.token {
                return tokens
            }
        }
    }

    // MARK: - Private Implementation

    private var currentChar: Character? {
        guard index < source.endIndex else { return nil }
        return source[index]
    }

    private func peek(offset: Int = 1) -> Character? {
        var targetIndex = index
        for _ in 0..<offset {
            guard targetIndex < source.endIndex else { return nil }
            targetIndex = source.index(after: targetIndex)
        }
        guard targetIndex < source.endIndex else { return nil }
        return source[targetIndex]
    }

    private var currentLocation: SourceLocation {
        SourceLocation(line: line, column: column, offset: offset)
    }

    private func advance() {
        guard index < source.endIndex else { return }
        let char = source[index]
        index = source.index(after: index)
        offset += 1

        if char == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    private func makeToken(_ token: Token, text: String, startLocation: SourceLocation) -> LocatedToken {
        LocatedToken(token: token, location: startLocation, text: text)
    }

    private func nextToken() throws -> LocatedToken {
        // Skip whitespace (but not newlines - we return those)
        skipWhitespace()

        let startLocation = currentLocation

        guard let char = currentChar else {
            return makeToken(.eof, text: "", startLocation: startLocation)
        }

        // Newline
        if char == "\n" {
            advance()
            return makeToken(.newline, text: "\n", startLocation: startLocation)
        }

        // Carriage return (with optional line feed)
        if char == "\r" {
            advance()
            if currentChar == "\n" {
                advance()
                return makeToken(.newline, text: "\r\n", startLocation: startLocation)
            }
            return makeToken(.newline, text: "\r", startLocation: startLocation)
        }

        // Comment
        if char == "/" && peek() == "/" {
            return try scanComment(startLocation: startLocation)
        }

        // String
        if char == "\"" {
            return try scanString(startLocation: startLocation)
        }

        // Number
        if char.isNumber {
            return try scanNumber(startLocation: startLocation)
        }

        // Identifier or keyword
        if char.isLetter || char == "_" || char == "$" {
            return scanIdentifier(startLocation: startLocation)
        }

        // Multi-character operators
        if char == "-" && peek() == ">" {
            advance()
            advance()
            return makeToken(.arrow, text: "->", startLocation: startLocation)
        }

        if char == "." && peek() == "." {
            advance()
            advance()
            return makeToken(.dotDot, text: "..", startLocation: startLocation)
        }

        if char == "=" && peek() == "=" {
            advance()
            advance()
            return makeToken(.equalEqual, text: "==", startLocation: startLocation)
        }

        if char == "!" && peek() == "=" {
            advance()
            advance()
            return makeToken(.bangEqual, text: "!=", startLocation: startLocation)
        }

        if char == "<" && peek() == "=" {
            advance()
            advance()
            return makeToken(.lessEqual, text: "<=", startLocation: startLocation)
        }

        if char == ">" && peek() == "=" {
            advance()
            advance()
            return makeToken(.greaterEqual, text: ">=", startLocation: startLocation)
        }

        if char == "&" && peek() == "&" {
            advance()
            advance()
            return makeToken(.ampAmp, text: "&&", startLocation: startLocation)
        }

        if char == "|" && peek() == "|" {
            advance()
            advance()
            return makeToken(.pipePipe, text: "||", startLocation: startLocation)
        }

        // Single-character tokens
        let singleCharToken: Token?
        switch char {
        case "(": singleCharToken = .leftParen
        case ")": singleCharToken = .rightParen
        case "[": singleCharToken = .leftBracket
        case "]": singleCharToken = .rightBracket
        case "{": singleCharToken = .leftBrace
        case "}": singleCharToken = .rightBrace
        case ",": singleCharToken = .comma
        case "=": singleCharToken = .equal
        case ".": singleCharToken = .dot
        case "+": singleCharToken = .plus
        case "-": singleCharToken = .minus
        case "*": singleCharToken = .star
        case "/": singleCharToken = .slash
        case "^": singleCharToken = .caret
        case "%": singleCharToken = .percent
        case "~": singleCharToken = .tilde
        case "<": singleCharToken = .less
        case ">": singleCharToken = .greater
        case "!": singleCharToken = .bang
        default: singleCharToken = nil
        }

        if let token = singleCharToken {
            let text = String(char)
            advance()
            return makeToken(token, text: text, startLocation: startLocation)
        }

        throw TokenizerError.unexpectedCharacter(char, startLocation)
    }

    private func skipWhitespace() {
        while let char = currentChar, char.isWhitespace && char != "\n" && char != "\r" {
            advance()
        }
    }

    private func scanComment(startLocation: SourceLocation) throws -> LocatedToken {
        var text = ""

        // Consume // and rest of line
        while let char = currentChar, char != "\n" && char != "\r" {
            text.append(char)
            advance()
        }

        return makeToken(.comment(text), text: text, startLocation: startLocation)
    }

    private func scanString(startLocation: SourceLocation) throws -> LocatedToken {
        var text = "\""
        var value = ""

        advance() // consume opening quote

        while let char = currentChar {
            if char == "\"" {
                text.append(char)
                advance()
                return makeToken(.string(value), text: text, startLocation: startLocation)
            }

            if char == "\n" || char == "\r" {
                throw TokenizerError.unterminatedString(startLocation)
            }

            // Handle escape sequences
            if char == "\\" {
                text.append(char)
                advance()

                if let escaped = currentChar {
                    text.append(escaped)

                    switch escaped {
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    case "\\": value.append("\\")
                    case "\"": value.append("\"")
                    default: value.append(escaped)
                    }
                    advance()
                }
            } else {
                text.append(char)
                value.append(char)
                advance()
            }
        }

        throw TokenizerError.unterminatedString(startLocation)
    }

    private func scanNumber(startLocation: SourceLocation) throws -> LocatedToken {
        var text = ""
        var hasDot = false

        while let char = currentChar {
            if char.isNumber {
                text.append(char)
                advance()
            } else if char == "." && !hasDot {
                // Check if this is a decimal point or range operator
                if peek() == "." {
                    // This is the start of ".." range operator, stop here
                    break
                }
                // Check if there's a digit after the dot
                if let next = peek(), next.isNumber {
                    hasDot = true
                    text.append(char)
                    advance()
                } else {
                    // Dot followed by non-digit - stop here (it's a member access)
                    break
                }
            } else {
                break
            }
        }

        guard let value = Double(text) else {
            throw TokenizerError.invalidNumber(text, startLocation)
        }

        return makeToken(.number(value), text: text, startLocation: startLocation)
    }

    private func scanIdentifier(startLocation: SourceLocation) -> LocatedToken {
        var text = ""
        var isFirst = true

        while let char = currentChar {
            if isFirst && char == "$" {
                text.append(char)
                advance()
                isFirst = false
                continue
            }
            guard char.isLetter || char.isNumber || char == "_" else { break }
            text.append(char)
            advance()
            isFirst = false
        }

        // Check if it's a keyword
        if let keyword = Self.keywords[text] {
            return makeToken(keyword, text: text, startLocation: startLocation)
        }

        return makeToken(.identifier(text), text: text, startLocation: startLocation)
    }
}
