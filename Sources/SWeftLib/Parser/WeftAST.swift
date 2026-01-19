// WeftAST.swift - Abstract Syntax Tree types for WEFT language

import Foundation

// MARK: - Program

public struct WeftProgram: Equatable {
    public var statements: [Statement]

    public init(statements: [Statement]) {
        self.statements = statements
    }
}

// MARK: - Statements

public enum Statement: Equatable {
    case bundleDecl(BundleDecl)
    case spindleDef(SpindleDef)
}

public struct BundleDecl: Equatable {
    public let name: String
    public let outputs: [OutputItem]
    public let expr: Expr

    public init(name: String, outputs: [OutputItem], expr: Expr) {
        self.name = name
        self.outputs = outputs
        self.expr = expr
    }
}

/// Output item in a bundle declaration: either a name (r, g, b) or a number (0, 1, 2)
public enum OutputItem: Equatable {
    case name(String)
    case index(Int)

    public var stringValue: String {
        switch self {
        case .name(let s): return s
        case .index(let i): return String(i)
        }
    }
}

public struct SpindleDef: Equatable {
    public let name: String
    public let params: [String]
    public let body: [BodyStatement]

    public init(name: String, params: [String], body: [BodyStatement]) {
        self.name = name
        self.params = params
        self.body = body
    }
}

public enum BodyStatement: Equatable {
    case bundleDecl(BundleDecl)
    case returnAssign(ReturnAssign)
}

public struct ReturnAssign: Equatable {
    public let index: Int
    public let expr: Expr

    public init(index: Int, expr: Expr) {
        self.index = index
        self.expr = expr
    }
}

// MARK: - Expressions

public indirect enum Expr: Equatable {
    // Literals
    case number(Double)
    case string(String)
    case identifier(String)

    // Bundle literal: [expr1, expr2, ...]
    case bundleLit([Expr])

    // Strand access: bundle.strand, bundle.0, bundle.(expr)
    case strandAccess(StrandAccess)

    // Binary operation: left op right
    case binaryOp(BinaryOp)

    // Unary operation: op operand
    case unaryOp(UnaryOp)

    // Spindle call: name(arg1, arg2, ...)
    case spindleCall(SpindleCall)

    // Call extract: call.index (extract strand from multi-strand result)
    case callExtract(CallExtract)

    // Remap expression: base(coord1 ~ expr1, coord2 ~ expr2)
    case remapExpr(RemapExpr)

    // Chain expression: base -> pattern1 -> pattern2
    case chainExpr(ChainExpr)

    // Range expression: start..end (used in patterns)
    case rangeExpr(RangeExpr)
}

// MARK: - Strand Access

public struct StrandAccess: Equatable {
    /// The bundle being accessed. Can be nil for bare strand access (.0 or .x)
    public let bundle: StrandBundle?
    public let accessor: StrandAccessor

    public init(bundle: StrandBundle?, accessor: StrandAccessor) {
        self.bundle = bundle
        self.accessor = accessor
    }
}

public enum StrandBundle: Equatable {
    case named(String)          // me, display, etc.
    case bundleLit([Expr])      // [a, b, c]
}

public enum StrandAccessor: Equatable {
    case name(String)           // .x, .r, .val
    case index(Int)             // .0, .1, .-1
    case expr(Expr)             // .(expr)
}

// MARK: - Binary Operations

public struct BinaryOp: Equatable {
    public let left: Expr
    public let op: BinaryOperator
    public let right: Expr

    public init(left: Expr, op: BinaryOperator, right: Expr) {
        self.left = left
        self.op = op
        self.right = right
    }
}

public enum BinaryOperator: String, Equatable {
    // Arithmetic
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case power = "^"
    case modulo = "%"

    // Comparison
    case equal = "=="
    case notEqual = "!="
    case less = "<"
    case greater = ">"
    case lessEqual = "<="
    case greaterEqual = ">="

    // Logical
    case and = "&&"
    case or = "||"
}

// MARK: - Unary Operations

public struct UnaryOp: Equatable {
    public let op: UnaryOperator
    public let operand: Expr

    public init(op: UnaryOperator, operand: Expr) {
        self.op = op
        self.operand = operand
    }
}

public enum UnaryOperator: String, Equatable {
    case negate = "-"
    case not = "!"
}

// MARK: - Spindle Call

public struct SpindleCall: Equatable {
    public let name: String
    public let args: [Expr]

    public init(name: String, args: [Expr]) {
        self.name = name
        self.args = args
    }
}

// MARK: - Call Extract

public struct CallExtract: Equatable {
    public let call: Expr       // Must be a spindleCall or bundleLit
    public let index: Int

    public init(call: Expr, index: Int) {
        self.call = call
        self.index = index
    }
}

// MARK: - Remap Expression

public struct RemapExpr: Equatable {
    public let base: StrandAccess
    public let remappings: [RemapArg]

    public init(base: StrandAccess, remappings: [RemapArg]) {
        self.base = base
        self.remappings = remappings
    }
}

public struct RemapArg: Equatable {
    public let domain: StrandAccess
    public let expr: Expr

    public init(domain: StrandAccess, expr: Expr) {
        self.domain = domain
        self.expr = expr
    }
}

// MARK: - Chain Expression

public struct ChainExpr: Equatable {
    public let base: Expr
    public let patterns: [PatternBlock]

    public init(base: Expr, patterns: [PatternBlock]) {
        self.base = base
        self.patterns = patterns
    }
}

public struct PatternBlock: Equatable {
    public let outputs: [PatternOutput]

    public init(outputs: [PatternOutput]) {
        self.outputs = outputs
    }
}

public struct PatternOutput: Equatable {
    public let value: Expr

    public init(value: Expr) {
        self.value = value
    }
}

// MARK: - Range Expression

public struct RangeExpr: Equatable {
    public let start: Int?      // nil for open start (..)
    public let end: Int?        // nil for open end (0..)

    public init(start: Int?, end: Int?) {
        self.start = start
        self.end = end
    }
}

// MARK: - CustomStringConvertible

extension Expr: CustomStringConvertible {
    public var description: String {
        switch self {
        case .number(let n):
            return String(n)
        case .string(let s):
            return "\"\(s)\""
        case .identifier(let id):
            return id
        case .bundleLit(let elements):
            return "[\(elements.map { $0.description }.joined(separator: ", "))]"
        case .strandAccess(let access):
            return access.description
        case .binaryOp(let op):
            return "(\(op.left) \(op.op.rawValue) \(op.right))"
        case .unaryOp(let op):
            return "\(op.op.rawValue)\(op.operand)"
        case .spindleCall(let call):
            return "\(call.name)(\(call.args.map { $0.description }.joined(separator: ", ")))"
        case .callExtract(let extract):
            return "\(extract.call).\(extract.index)"
        case .remapExpr(let remap):
            let args = remap.remappings.map { "\($0.domain) ~ \($0.expr)" }.joined(separator: ", ")
            return "\(remap.base)(\(args))"
        case .chainExpr(let chain):
            let patterns = chain.patterns.map { pattern in
                let outputs = pattern.outputs.map { $0.value.description }.joined(separator: ", ")
                return "-> {\(outputs)}"
            }.joined(separator: " ")
            return "\(chain.base) \(patterns)"
        case .rangeExpr(let range):
            let start = range.start.map { String($0) } ?? ""
            let end = range.end.map { String($0) } ?? ""
            return "\(start)..\(end)"
        }
    }
}

extension StrandAccess: CustomStringConvertible {
    public var description: String {
        let bundleStr: String
        switch bundle {
        case .none:
            bundleStr = ""
        case .named(let name):
            bundleStr = name
        case .bundleLit(let elements):
            bundleStr = "[\(elements.map { $0.description }.joined(separator: ", "))]"
        }

        let accessorStr: String
        switch accessor {
        case .name(let n):
            accessorStr = ".\(n)"
        case .index(let i):
            accessorStr = ".\(i)"
        case .expr(let e):
            accessorStr = ".(\(e))"
        }

        return bundleStr + accessorStr
    }
}

extension Statement: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bundleDecl(let decl):
            let outputs = decl.outputs.map { $0.stringValue }.joined(separator: ", ")
            return "\(decl.name)[\(outputs)] = \(decl.expr)"
        case .spindleDef(let def):
            let params = def.params.joined(separator: ", ")
            return "spindle \(def.name)(\(params)) { ... }"
        }
    }
}
