// WeftParser.swift - Recursive descent parser for WEFT language

import Foundation

// MARK: - Parser Error

public enum ParseError: Error, LocalizedError {
    case unexpectedToken(expected: String, found: Token, location: SourceLocation)
    case unexpectedEndOfFile(expected: String)
    case invalidSyntax(String, SourceLocation)

    public var errorDescription: String? {
        switch self {
        case .unexpectedToken(let expected, let found, let loc):
            return "Expected \(expected), found \(found) at \(loc)"
        case .unexpectedEndOfFile(let expected):
            return "Unexpected end of file, expected \(expected)"
        case .invalidSyntax(let msg, let loc):
            return "\(msg) at \(loc)"
        }
    }
}

// MARK: - Parser

public class WeftParser {
    private var tokens: [LocatedToken]
    private var current: Int = 0

    public init(tokens: [LocatedToken]) {
        self.tokens = tokens
    }

    public convenience init(source: String) throws {
        let tokenizer = WeftTokenizer(source: source)
        let tokens = try tokenizer.tokenize()
        self.init(tokens: tokens)
    }

    // MARK: - Public API

    public func parse() throws -> WeftProgram {
        var statements: [Statement] = []

        while !isAtEnd {
            let stmt = try parseStatement()
            statements.append(stmt)
        }

        return WeftProgram(statements: statements)
    }

    // MARK: - Token Navigation

    private var isAtEnd: Bool {
        if case .eof = peek().token { return true }
        return false
    }

    private func peek(offset: Int = 0) -> LocatedToken {
        let index = current + offset
        guard index < tokens.count else {
            return tokens.last ?? LocatedToken(token: .eof, location: SourceLocation(), text: "")
        }
        return tokens[index]
    }

    private var currentLocation: SourceLocation {
        peek().location
    }

    @discardableResult
    private func advance() -> LocatedToken {
        if !isAtEnd {
            current += 1
        }
        return tokens[current - 1]
    }

    private func check(_ token: Token) -> Bool {
        if isAtEnd { return false }
        return tokenMatches(peek().token, token)
    }

    private func tokenMatches(_ a: Token, _ b: Token) -> Bool {
        switch (a, b) {
        case (.identifier, .identifier): return true
        case (.number, .number): return true
        case (.string, .string): return true
        default:
            // For simple tokens, use equality
            return a == b
        }
    }

    private func match(_ tokens: Token...) -> Bool {
        for token in tokens {
            if check(token) {
                advance()
                return true
            }
        }
        return false
    }

    private func consume(_ expected: Token, _ message: String) throws -> LocatedToken {
        if check(expected) {
            return advance()
        }
        throw ParseError.unexpectedToken(expected: message, found: peek().token, location: currentLocation)
    }

    // MARK: - Statement Parsing

    private func parseStatement() throws -> Statement {
        if check(.spindle) {
            return .spindleDef(try parseSpindleDef())
        }
        return .bundleDecl(try parseBundleDecl())
    }

    private func parseBundleDecl() throws -> BundleDecl {
        // ident ("." ident | "[" OutputList "]") "=" Expr
        let nameToken = try consume(.identifier(""), "bundle name")
        guard case .identifier(let name) = nameToken.token else {
            throw ParseError.invalidSyntax("Expected identifier", nameToken.location)
        }

        var outputs: [OutputItem] = []

        if match(.dot) {
            // Shorthand: name.strand = expr
            let strandToken = try consume(.identifier(""), "strand name")
            guard case .identifier(let strandName) = strandToken.token else {
                throw ParseError.invalidSyntax("Expected strand name", strandToken.location)
            }
            outputs = [.name(strandName)]
        } else if match(.leftBracket) {
            // Full: name[r, g, b] = expr
            outputs = try parseOutputList()
            try consume(.rightBracket, "]")
        } else {
            throw ParseError.unexpectedToken(expected: ". or [", found: peek().token, location: currentLocation)
        }

        try consume(.equal, "=")
        let expr = try parseExpr()

        return BundleDecl(name: name, outputs: outputs, expr: expr)
    }

    private func parseOutputList() throws -> [OutputItem] {
        var items: [OutputItem] = []

        repeat {
            if case .identifier(let name) = peek().token {
                advance()
                items.append(.name(name))
            } else if case .number(let n) = peek().token {
                advance()
                items.append(.index(Int(n)))
            } else {
                throw ParseError.unexpectedToken(expected: "strand name or index", found: peek().token, location: currentLocation)
            }
        } while match(.comma)

        return items
    }

    private func parseSpindleDef() throws -> SpindleDef {
        // "spindle" ident "(" IdentList? ")" "{" Body "}"
        try consume(.spindle, "spindle")

        let nameToken = try consume(.identifier(""), "spindle name")
        guard case .identifier(let name) = nameToken.token else {
            throw ParseError.invalidSyntax("Expected spindle name", nameToken.location)
        }

        try consume(.leftParen, "(")
        var params: [String] = []
        if !check(.rightParen) {
            params = try parseIdentList()
        }
        try consume(.rightParen, ")")

        try consume(.leftBrace, "{")
        var body: [BodyStatement] = []
        while !check(.rightBrace) && !isAtEnd {
            let stmt = try parseBodyStatement()
            body.append(stmt)
        }
        try consume(.rightBrace, "}")

        return SpindleDef(name: name, params: params, body: body)
    }

    private func parseIdentList() throws -> [String] {
        var idents: [String] = []

        repeat {
            let token = try consume(.identifier(""), "parameter name")
            guard case .identifier(let name) = token.token else {
                throw ParseError.invalidSyntax("Expected identifier", token.location)
            }
            idents.append(name)
        } while match(.comma)

        return idents
    }

    private func parseBodyStatement() throws -> BodyStatement {
        if check(.return) {
            return .returnAssign(try parseReturnAssign())
        }
        return .bundleDecl(try parseBundleDecl())
    }

    private func parseReturnAssign() throws -> ReturnAssign {
        // "return" "." integer "=" Expr
        try consume(.return, "return")
        try consume(.dot, ".")

        let indexToken = try consume(.number(0), "return index")
        guard case .number(let n) = indexToken.token else {
            throw ParseError.invalidSyntax("Expected return index", indexToken.location)
        }

        try consume(.equal, "=")
        let expr = try parseExpr()

        return ReturnAssign(index: Int(n), expr: expr)
    }

    // MARK: - Expression Parsing

    private func parseExpr() throws -> Expr {
        return try parseChainExpr()
    }

    private func parseChainExpr() throws -> Expr {
        // ComparisonExpr ("->" PatternBlock)*
        var expr = try parseComparisonExpr()

        var patterns: [PatternBlock] = []
        while match(.arrow) {
            let pattern = try parsePatternBlock()
            patterns.append(pattern)
        }

        if patterns.isEmpty {
            return expr
        }

        return .chainExpr(ChainExpr(base: expr, patterns: patterns))
    }

    private func parseComparisonExpr() throws -> Expr {
        // AddExpr (compareOp AddExpr)*
        var expr = try parseAddExpr()

        while true {
            let op: BinaryOperator?
            if match(.equalEqual) { op = .equal }
            else if match(.bangEqual) { op = .notEqual }
            else if match(.less) { op = .less }
            else if match(.greater) { op = .greater }
            else if match(.lessEqual) { op = .lessEqual }
            else if match(.greaterEqual) { op = .greaterEqual }
            else if match(.ampAmp) { op = .and }
            else if match(.pipePipe) { op = .or }
            else { break }

            let right = try parseAddExpr()
            expr = .binaryOp(BinaryOp(left: expr, op: op!, right: right))
        }

        return expr
    }

    private func parseAddExpr() throws -> Expr {
        // MultExpr (("+" | "-") MultExpr)*
        var expr = try parseMultExpr()

        while true {
            let op: BinaryOperator?
            if match(.plus) { op = .add }
            else if match(.minus) { op = .subtract }
            else { break }

            let right = try parseMultExpr()
            expr = .binaryOp(BinaryOp(left: expr, op: op!, right: right))
        }

        return expr
    }

    private func parseMultExpr() throws -> Expr {
        // ExpoExpr (("*" | "/" | "%") ExpoExpr)*
        var expr = try parseExpoExpr()

        while true {
            let op: BinaryOperator?
            if match(.star) { op = .multiply }
            else if match(.slash) { op = .divide }
            else if match(.percent) { op = .modulo }
            else { break }

            let right = try parseExpoExpr()
            expr = .binaryOp(BinaryOp(left: expr, op: op!, right: right))
        }

        return expr
    }

    private func parseExpoExpr() throws -> Expr {
        // UnaryExpr ("^" UnaryExpr)*
        // Note: ^ is right-associative
        let base = try parseUnaryExpr()

        if match(.caret) {
            let right = try parseExpoExpr()  // Right associative
            return .binaryOp(BinaryOp(left: base, op: .power, right: right))
        }

        return base
    }

    private func parseUnaryExpr() throws -> Expr {
        // ("-" | "!") UnaryExpr | PostfixExpr
        if match(.minus) {
            let operand = try parseUnaryExpr()
            return .unaryOp(UnaryOp(op: .negate, operand: operand))
        }
        if match(.bang) {
            let operand = try parseUnaryExpr()
            return .unaryOp(UnaryOp(op: .not, operand: operand))
        }

        return try parsePostfixExpr()
    }

    private func parsePostfixExpr() throws -> Expr {
        // PrimaryExpr ("." accessor)*
        var expr = try parsePrimaryExpr()

        while check(.dot) {
            // Check if this is a strand access or just a dot
            let dotLoc = peek().location
            advance()  // consume dot

            // Check what follows the dot
            if case .identifier(let name) = peek().token {
                advance()
                // Check for remap: ident.strand(args)
                if check(.leftParen) && isRemapArgs() {
                    let access = StrandAccess(bundle: exprToBundle(expr), accessor: .name(name))
                    expr = try parseRemapExpr(base: access)
                } else {
                    expr = .strandAccess(StrandAccess(bundle: exprToBundle(expr), accessor: .name(name)))
                }
            } else if case .number(let n) = peek().token {
                advance()
                let index = Int(n)
                // Handle negative index if preceded by minus
                expr = .strandAccess(StrandAccess(bundle: exprToBundle(expr), accessor: .index(index)))
            } else if match(.leftParen) {
                // Dynamic index access: expr.(indexExpr)
                let indexExpr = try parseExpr()
                try consume(.rightParen, ")")
                expr = .strandAccess(StrandAccess(bundle: exprToBundle(expr), accessor: .expr(indexExpr)))
            } else if match(.minus) {
                // Negative index: .-1
                let numToken = try consume(.number(0), "index")
                guard case .number(let n) = numToken.token else {
                    throw ParseError.invalidSyntax("Expected index after -", dotLoc)
                }
                expr = .strandAccess(StrandAccess(bundle: exprToBundle(expr), accessor: .index(-Int(n))))
            } else {
                throw ParseError.invalidSyntax("Expected strand accessor after .", dotLoc)
            }
        }

        return expr
    }

    private func exprToBundle(_ expr: Expr) -> StrandBundle? {
        switch expr {
        case .identifier(let name):
            return .named(name)
        case .bundleLit(let elements):
            return .bundleLit(elements)
        default:
            return nil
        }
    }

    private func isRemapArgs() -> Bool {
        // Look ahead to see if this is a remap: check for ~ after first arg
        var depth = 1
        var i = current + 1  // Start after (
        var sawTilde = false

        while i < tokens.count && depth > 0 {
            switch tokens[i].token {
            case .leftParen, .leftBracket, .leftBrace:
                depth += 1
            case .rightParen:
                depth -= 1
            case .rightBracket, .rightBrace:
                depth -= 1
            case .tilde:
                if depth == 1 {
                    sawTilde = true
                }
            default:
                break
            }
            i += 1
        }

        return sawTilde
    }

    private func parsePrimaryExpr() throws -> Expr {
        let loc = currentLocation

        // Parenthesized expression
        if match(.leftParen) {
            let expr = try parseExpr()
            try consume(.rightParen, ")")
            return expr
        }

        // Bundle literal: [expr, expr, ...]
        if match(.leftBracket) {
            var elements: [Expr] = []
            if !check(.rightBracket) {
                elements = try parseExprList()
            }
            try consume(.rightBracket, "]")
            return .bundleLit(elements)
        }

        // Range or bare strand access starting with ..
        if match(.dotDot) {
            // Could be ..end or just ..
            if case .number(let n) = peek().token {
                advance()
                return .rangeExpr(RangeExpr(start: nil, end: Int(n)))
            } else if match(.minus) {
                // Negative end: ..-1
                let numToken = try consume(.number(0), "range end")
                guard case .number(let n) = numToken.token else {
                    throw ParseError.invalidSyntax("Expected number", loc)
                }
                return .rangeExpr(RangeExpr(start: nil, end: -Int(n)))
            }
            return .rangeExpr(RangeExpr(start: nil, end: nil))
        }

        // Bare strand access: .x or .0
        if match(.dot) {
            if case .identifier(let name) = peek().token {
                advance()
                return .strandAccess(StrandAccess(bundle: nil, accessor: .name(name)))
            } else if case .number(let n) = peek().token {
                advance()
                return .strandAccess(StrandAccess(bundle: nil, accessor: .index(Int(n))))
            } else if match(.minus) {
                let numToken = try consume(.number(0), "strand index")
                guard case .number(let n) = numToken.token else {
                    throw ParseError.invalidSyntax("Expected index", loc)
                }
                return .strandAccess(StrandAccess(bundle: nil, accessor: .index(-Int(n))))
            } else if match(.leftParen) {
                let indexExpr = try parseExpr()
                try consume(.rightParen, ")")
                return .strandAccess(StrandAccess(bundle: nil, accessor: .expr(indexExpr)))
            }
            throw ParseError.invalidSyntax("Expected strand accessor after .", loc)
        }

        // String literal
        if case .string(let value) = peek().token {
            advance()
            return .string(value)
        }

        // Number (possibly starting a range)
        if case .number(let n) = peek().token {
            advance()
            let value = Int(n)

            // Check for range: N..M or N..
            if match(.dotDot) {
                if case .number(let endN) = peek().token {
                    advance()
                    return .rangeExpr(RangeExpr(start: value, end: Int(endN)))
                } else if match(.minus) {
                    let numToken = try consume(.number(0), "range end")
                    guard case .number(let endN) = numToken.token else {
                        throw ParseError.invalidSyntax("Expected number", loc)
                    }
                    return .rangeExpr(RangeExpr(start: value, end: -Int(endN)))
                }
                return .rangeExpr(RangeExpr(start: value, end: nil))
            }

            return .number(n)
        }

        // Negative number (possibly starting a range)
        if check(.minus) {
            // Peek ahead to see if this is a negative number at start of range
            if case .number = peek(offset: 1).token {
                // Check if followed by ..
                if case .dotDot = peek(offset: 2).token {
                    advance()  // consume -
                    let numToken = advance()
                    guard case .number(let n) = numToken.token else {
                        throw ParseError.invalidSyntax("Expected number", loc)
                    }
                    let startValue = -Int(n)

                    advance()  // consume ..

                    // Parse end
                    if case .number(let endN) = peek().token {
                        advance()
                        return .rangeExpr(RangeExpr(start: startValue, end: Int(endN)))
                    } else if match(.minus) {
                        let endNumToken = try consume(.number(0), "range end")
                        guard case .number(let endN) = endNumToken.token else {
                            throw ParseError.invalidSyntax("Expected number", loc)
                        }
                        return .rangeExpr(RangeExpr(start: startValue, end: -Int(endN)))
                    }
                    return .rangeExpr(RangeExpr(start: startValue, end: nil))
                }
            }
        }

        // Identifier (possibly spindle call or strand access)
        if case .identifier(let name) = peek().token {
            advance()

            // Spindle call: name(args)
            if match(.leftParen) {
                var args: [Expr] = []
                if !check(.rightParen) {
                    args = try parseExprList()
                }
                try consume(.rightParen, ")")
                return .spindleCall(SpindleCall(name: name, args: args))
            }

            return .identifier(name)
        }

        throw ParseError.unexpectedToken(expected: "expression", found: peek().token, location: loc)
    }

    private func parseRemapExpr(base: StrandAccess) throws -> Expr {
        // We already have the base, now parse (RemapArgList)
        try consume(.leftParen, "(")
        let args = try parseRemapArgList()
        try consume(.rightParen, ")")

        return .remapExpr(RemapExpr(base: base, remappings: args))
    }

    private func parseRemapArgList() throws -> [RemapArg] {
        var args: [RemapArg] = []

        repeat {
            let arg = try parseRemapArg()
            args.append(arg)
        } while match(.comma)

        return args
    }

    private func parseRemapArg() throws -> RemapArg {
        // StrandAccess "~" Expr
        let domain = try parseStrandAccessForRemap()
        try consume(.tilde, "~")
        let expr = try parseExpr()

        return RemapArg(domain: domain, expr: expr)
    }

    private func parseStrandAccessForRemap() throws -> StrandAccess {
        // ident "." (ident | number)
        // or "." (ident | number) for bare access
        let loc = currentLocation

        if match(.dot) {
            // Bare strand access
            if case .identifier(let name) = peek().token {
                advance()
                return StrandAccess(bundle: nil, accessor: .name(name))
            } else if case .number(let n) = peek().token {
                advance()
                return StrandAccess(bundle: nil, accessor: .index(Int(n)))
            }
            throw ParseError.invalidSyntax("Expected strand accessor", loc)
        }

        let nameToken = try consume(.identifier(""), "bundle name")
        guard case .identifier(let bundleName) = nameToken.token else {
            throw ParseError.invalidSyntax("Expected bundle name", loc)
        }

        try consume(.dot, ".")

        if case .identifier(let strandName) = peek().token {
            advance()
            return StrandAccess(bundle: .named(bundleName), accessor: .name(strandName))
        } else if case .number(let n) = peek().token {
            advance()
            return StrandAccess(bundle: .named(bundleName), accessor: .index(Int(n)))
        } else if match(.minus) {
            let numToken = try consume(.number(0), "strand index")
            guard case .number(let n) = numToken.token else {
                throw ParseError.invalidSyntax("Expected strand index", loc)
            }
            return StrandAccess(bundle: .named(bundleName), accessor: .index(-Int(n)))
        }

        throw ParseError.invalidSyntax("Expected strand accessor", loc)
    }

    private func parseExprList() throws -> [Expr] {
        var exprs: [Expr] = []

        repeat {
            let expr = try parseExpr()
            exprs.append(expr)
        } while match(.comma)

        return exprs
    }

    private func parsePatternBlock() throws -> PatternBlock {
        // "{" PatternOutputList "}"
        try consume(.leftBrace, "{")

        var outputs: [PatternOutput] = []
        if !check(.rightBrace) {
            repeat {
                let expr = try parseExpr()
                outputs.append(PatternOutput(value: expr))
            } while match(.comma)
        }

        try consume(.rightBrace, "}")

        return PatternBlock(outputs: outputs)
    }
}
