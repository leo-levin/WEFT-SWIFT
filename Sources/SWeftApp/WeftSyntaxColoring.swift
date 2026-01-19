// WeftSyntaxColoring.swift - Tokenizer and syntax highlighter for WEFT language

import AppKit

// MARK: - Token Types

enum TokenType {
    // Keywords
    case keyword           // spindle, display, camera, play, microphone, return

    // Bundle & Strand
    case bundleName        // identifier when followed by . or [
    case strandDeclBracket // [ ] after bundle name
    case strandDeclName    // r, g, b inside [ ]
    case strandAccessor    // .r or .0 (includes the dot)

    // Literals
    case identifier        // standalone identifier
    case number            // 42, 0.5
    case rangeNumber       // numbers in range expressions like 0..3
    case string            // "..."
    case comment           // // to end of line

    // Operators
    case arithmeticOp      // + - * / ^ % ~
    case comparisonOp      // == != < > <= >=
    case logicalOp         // && || !

    // Chain syntax
    case chain             // -> { }

    // Range
    case range             // ..

    // Other punctuation
    case paren             // ( )
    case comma             // ,
    case equals            // =

    case whitespace
    case newline
    case unknown
}

// MARK: - Token

struct Token {
    let type: TokenType
    let text: String
    let range: NSRange
}

// MARK: - Tokenizer

class WeftTokenizer {
    private let source: String
    private var index: String.Index
    private var nsOffset: Int  // track NSRange offset

    private static let keywords: Set<String> = [
        "spindle", "display", "camera", "play", "microphone", "return"
    ]

    init(source: String) {
        self.source = source
        self.index = source.startIndex
        self.nsOffset = 0
    }

    func tokenize() -> [Token] {
        var tokens: [Token] = []

        while index < source.endIndex {
            let token = nextToken()
            tokens.append(token)
        }

        return tokens
    }

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

    private func advance() {
        guard index < source.endIndex else { return }
        let char = source[index]
        index = source.index(after: index)
        nsOffset += char.utf16.count
    }

    private func makeToken(type: TokenType, text: String, startOffset: Int) -> Token {
        let nsLength = text.utf16.count
        return Token(type: type, text: text, range: NSRange(location: startOffset, length: nsLength))
    }

    private func nextToken() -> Token {
        guard let char = currentChar else {
            return makeToken(type: .unknown, text: "", startOffset: nsOffset)
        }

        let startOffset = nsOffset

        // Whitespace (not newline)
        if char.isWhitespace && !char.isNewline {
            return scanWhitespace(startOffset: startOffset)
        }

        // Newline
        if char.isNewline {
            advance()
            return makeToken(type: .newline, text: String(char), startOffset: startOffset)
        }

        // Comment
        if char == "/" && peek() == "/" {
            return scanComment(startOffset: startOffset)
        }

        // String
        if char == "\"" {
            return scanString(startOffset: startOffset)
        }

        // Number
        if char.isNumber || (char == "." && peek()?.isNumber == true) {
            return scanNumber(startOffset: startOffset)
        }

        // Identifier or keyword
        if char.isLetter || char == "_" {
            return scanIdentifierOrKeyword(startOffset: startOffset)
        }

        // Multi-character operators
        if char == "-" && peek() == ">" {
            advance()
            advance()
            return makeToken(type: .chain, text: "->", startOffset: startOffset)
        }

        if char == "." && peek() == "." {
            advance()
            advance()
            return makeToken(type: .range, text: "..", startOffset: startOffset)
        }

        if char == "=" && peek() == "=" {
            advance()
            advance()
            return makeToken(type: .comparisonOp, text: "==", startOffset: startOffset)
        }

        if char == "!" && peek() == "=" {
            advance()
            advance()
            return makeToken(type: .comparisonOp, text: "!=", startOffset: startOffset)
        }

        if char == "<" && peek() == "=" {
            advance()
            advance()
            return makeToken(type: .comparisonOp, text: "<=", startOffset: startOffset)
        }

        if char == ">" && peek() == "=" {
            advance()
            advance()
            return makeToken(type: .comparisonOp, text: ">=", startOffset: startOffset)
        }

        if char == "&" && peek() == "&" {
            advance()
            advance()
            return makeToken(type: .logicalOp, text: "&&", startOffset: startOffset)
        }

        if char == "|" && peek() == "|" {
            advance()
            advance()
            return makeToken(type: .logicalOp, text: "||", startOffset: startOffset)
        }

        // Single-character tokens
        switch char {
        case "{", "}":
            advance()
            return makeToken(type: .chain, text: String(char), startOffset: startOffset)
        case "(", ")":
            advance()
            return makeToken(type: .paren, text: String(char), startOffset: startOffset)
        case "[", "]":
            advance()
            return makeToken(type: .strandDeclBracket, text: String(char), startOffset: startOffset)
        case ",":
            advance()
            return makeToken(type: .comma, text: ",", startOffset: startOffset)
        case "=":
            advance()
            return makeToken(type: .equals, text: "=", startOffset: startOffset)
        case "+", "-", "*", "/", "^", "%", "~":
            advance()
            return makeToken(type: .arithmeticOp, text: String(char), startOffset: startOffset)
        case "<", ">":
            advance()
            return makeToken(type: .comparisonOp, text: String(char), startOffset: startOffset)
        case "!":
            advance()
            return makeToken(type: .logicalOp, text: "!", startOffset: startOffset)
        case ".":
            // Standalone dot - likely a strand accessor without context
            advance()
            return makeToken(type: .unknown, text: ".", startOffset: startOffset)
        default:
            advance()
            return makeToken(type: .unknown, text: String(char), startOffset: startOffset)
        }
    }

    private func scanWhitespace(startOffset: Int) -> Token {
        var text = ""
        while let char = currentChar, char.isWhitespace && !char.isNewline {
            text.append(char)
            advance()
        }
        return makeToken(type: .whitespace, text: text, startOffset: startOffset)
    }

    private func scanComment(startOffset: Int) -> Token {
        var text = ""
        // Consume // and rest of line
        while let char = currentChar, !char.isNewline {
            text.append(char)
            advance()
        }
        return makeToken(type: .comment, text: text, startOffset: startOffset)
    }

    private func scanString(startOffset: Int) -> Token {
        var text = ""
        text.append(currentChar!) // opening quote
        advance()

        while let char = currentChar {
            text.append(char)
            advance()
            if char == "\"" {
                break
            }
            // Handle escape sequences
            if char == "\\" && currentChar != nil {
                text.append(currentChar!)
                advance()
            }
        }
        return makeToken(type: .string, text: text, startOffset: startOffset)
    }

    private func scanNumber(startOffset: Int) -> Token {
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
                hasDot = true
                text.append(char)
                advance()
            } else {
                break
            }
        }
        return makeToken(type: .number, text: text, startOffset: startOffset)
    }

    private func scanIdentifierOrKeyword(startOffset: Int) -> Token {
        var text = ""

        while let char = currentChar, char.isLetter || char.isNumber || char == "_" {
            text.append(char)
            advance()
        }

        // Look ahead to determine token type
        let isKeyword = Self.keywords.contains(text)

        // Skip whitespace for lookahead
        var lookaheadIndex = index
        while lookaheadIndex < source.endIndex && source[lookaheadIndex].isWhitespace && !source[lookaheadIndex].isNewline {
            lookaheadIndex = source.index(after: lookaheadIndex)
        }

        let nextNonWhitespace: Character? = lookaheadIndex < source.endIndex ? source[lookaheadIndex] : nil

        // Determine token type based on lookahead
        if isKeyword {
            // Keywords followed by . get strand accessor treatment for the dot
            return makeToken(type: .keyword, text: text, startOffset: startOffset)
        } else if nextNonWhitespace == "." || nextNonWhitespace == "[" || nextNonWhitespace == "-" {
            // Identifier followed by ., [, or -> is a bundle name
            return makeToken(type: .bundleName, text: text, startOffset: startOffset)
        } else {
            return makeToken(type: .identifier, text: text, startOffset: startOffset)
        }
    }
}

// MARK: - Context-Aware Token Processor

/// Post-processes tokens to handle context-dependent token types
class WeftTokenProcessor {
    func process(_ tokens: [Token]) -> [Token] {
        // First pass: handle strands and accessors
        let firstPass = processStrandsAndAccessors(tokens)
        // Second pass: handle range numbers
        return processRangeNumbers(firstPass)
    }

    private func processRangeNumbers(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []

        for i in 0..<tokens.count {
            let token = tokens[i]

            if token.type == .number {
                // Check if this number is adjacent to a range operator
                let prevNonWhitespace = findPrevNonWhitespace(tokens, before: i)
                let nextNonWhitespace = findNextNonWhitespace(tokens, after: i)

                let isAfterRange = prevNonWhitespace?.type == .range
                let isBeforeRange = nextNonWhitespace?.type == .range

                if isAfterRange || isBeforeRange {
                    result.append(Token(type: .rangeNumber, text: token.text, range: token.range))
                } else {
                    result.append(token)
                }
            } else {
                result.append(token)
            }
        }

        return result
    }

    private func findPrevNonWhitespace(_ tokens: [Token], before index: Int) -> Token? {
        var i = index - 1
        while i >= 0 {
            if tokens[i].type != .whitespace && tokens[i].type != .newline {
                return tokens[i]
            }
            i -= 1
        }
        return nil
    }

    private func findNextNonWhitespace(_ tokens: [Token], after index: Int) -> Token? {
        var i = index + 1
        while i < tokens.count {
            if tokens[i].type != .whitespace && tokens[i].type != .newline {
                return tokens[i]
            }
            i += 1
        }
        return nil
    }

    private func processStrandsAndAccessors(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var i = 0

        while i < tokens.count {
            let token = tokens[i]

            // Handle strand declaration brackets: identifier[r,g,b]
            if token.type == .bundleName || token.type == .keyword {
                result.append(token)
                i += 1

                // Skip whitespace
                while i < tokens.count && tokens[i].type == .whitespace {
                    result.append(tokens[i])
                    i += 1
                }

                // Check for [ (strand declaration)
                if i < tokens.count && tokens[i].type == .strandDeclBracket && tokens[i].text == "[" {
                    result.append(tokens[i]) // [
                    i += 1

                    // Process contents until ]
                    while i < tokens.count {
                        let innerToken = tokens[i]

                        if innerToken.type == .strandDeclBracket && innerToken.text == "]" {
                            result.append(innerToken)
                            i += 1
                            break
                        } else if innerToken.type == .identifier || innerToken.type == .bundleName {
                            // Identifiers inside brackets are strand names
                            result.append(Token(type: .strandDeclName, text: innerToken.text, range: innerToken.range))
                            i += 1
                        } else if innerToken.type == .number {
                            // Numbers inside brackets are also strand names
                            result.append(Token(type: .strandDeclName, text: innerToken.text, range: innerToken.range))
                            i += 1
                        } else {
                            result.append(innerToken)
                            i += 1
                        }
                    }
                }
                // Check for . (strand accessor)
                else if i < tokens.count && tokens[i].type == .unknown && tokens[i].text == "." {
                    let dotToken = tokens[i]
                    i += 1

                    // Get the accessor name/number
                    if i < tokens.count {
                        let accessorToken = tokens[i]
                        if accessorToken.type == .identifier || accessorToken.type == .bundleName || accessorToken.type == .number {
                            // Combine dot with accessor name
                            let combinedText = "." + accessorToken.text
                            let combinedRange = NSRange(location: dotToken.range.location, length: dotToken.range.length + accessorToken.range.length)
                            result.append(Token(type: .strandAccessor, text: combinedText, range: combinedRange))
                            i += 1
                        } else {
                            result.append(Token(type: .strandAccessor, text: ".", range: dotToken.range))
                        }
                    } else {
                        result.append(Token(type: .strandAccessor, text: ".", range: dotToken.range))
                    }
                }
            }
            // Handle standalone [ ] not after bundle name - might be array syntax
            else if token.type == .strandDeclBracket {
                result.append(token)
                i += 1
            }
            // Handle standalone . that might be strand accessor (e.g., after me keyword)
            else if token.type == .unknown && token.text == "." {
                let dotToken = token
                i += 1

                // Get the accessor name/number if present
                if i < tokens.count {
                    let nextToken = tokens[i]
                    if nextToken.type == .identifier || nextToken.type == .bundleName || nextToken.type == .number {
                        let combinedText = "." + nextToken.text
                        let combinedRange = NSRange(location: dotToken.range.location, length: dotToken.range.length + nextToken.range.length)
                        result.append(Token(type: .strandAccessor, text: combinedText, range: combinedRange))
                        i += 1
                    } else {
                        result.append(dotToken)
                    }
                } else {
                    result.append(dotToken)
                }
            }
            else {
                result.append(token)
                i += 1
            }
        }

        return result
    }
}

// MARK: - NSColor Extensions

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }

    // WEFT syntax colors based on VS Code Dark Modern
    static let weftKeyword = NSColor(hex: "#c586c0")       // purple
    static let weftString = NSColor(hex: "#ce9178")        // orange
    static let weftNumber = NSColor(hex: "#d4d4d4")        // light gray (subtle)
    static let weftComment = NSColor(hex: "#6a9955")       // green
    static let weftIdentifier = NSColor(hex: "#dcdcaa")    // yellow/gold
    static let weftBundle = NSColor(hex: "#569cd6")        // blue
    static let weftStrand = NSColor(hex: "#9cdcfe")        // lighter blue
    static let weftChain = NSColor(hex: "#4ec9b0")         // teal
    static let weftOperator = NSColor(hex: "#d4d4d4")      // light gray
}

// MARK: - Syntax Highlighter

class WeftSyntaxHighlighter {
    private let tokenizer: WeftTokenizer
    private let processor: WeftTokenProcessor

    init() {
        // These will be recreated for each highlight call
        self.tokenizer = WeftTokenizer(source: "")
        self.processor = WeftTokenProcessor()
    }

    func highlight(_ textStorage: NSTextStorage) {
        let source = textStorage.string
        guard !source.isEmpty else { return }

        // Tokenize
        let tokenizer = WeftTokenizer(source: source)
        let rawTokens = tokenizer.tokenize()

        // Process for context-aware token types
        let processor = WeftTokenProcessor()
        let tokens = processor.process(rawTokens)

        // Begin editing
        textStorage.beginEditing()

        // Reset to default color for entire range
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(.foregroundColor, range: fullRange)

        // Apply colors based on token types
        for token in tokens {
            guard token.range.location + token.range.length <= textStorage.length else { continue }

            if let color = color(for: token.type) {
                textStorage.addAttribute(.foregroundColor, value: color, range: token.range)
            }
        }

        textStorage.endEditing()
    }

    private func color(for tokenType: TokenType) -> NSColor? {
        switch tokenType {
        case .keyword:
            return .weftKeyword
        case .bundleName, .strandDeclBracket:
            return .weftBundle
        case .strandAccessor, .strandDeclName:
            return .weftStrand
        case .identifier:
            return .weftIdentifier
        case .number:
            return .weftNumber
        case .rangeNumber:
            return .weftStrand
        case .string:
            return .weftString
        case .comment:
            return .weftComment
        case .chain, .range:
            return .weftChain
        case .arithmeticOp, .comparisonOp, .logicalOp, .paren, .comma, .equals:
            return .weftOperator
        case .whitespace, .newline, .unknown:
            return nil
        }
    }
}
