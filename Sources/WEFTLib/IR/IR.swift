// IR.swift - Intermediate Representation types matching JS ir.js

import Foundation

// MARK: - Program Structure

public struct IRProgram: Codable, Equatable {
    public var bundles: [String: IRBundle]
    public var spindles: [String: IRSpindle]
    public var order: [OrderEntry]
    public var resources: [String]
    public var textResources: [String]

    public init(bundles: [String: IRBundle] = [:],
                spindles: [String: IRSpindle] = [:],
                order: [OrderEntry] = [],
                resources: [String] = [],
                textResources: [String] = []) {
        self.bundles = bundles
        self.spindles = spindles
        self.order = order
        self.resources = resources
        self.textResources = textResources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundles = try container.decode([String: IRBundle].self, forKey: .bundles)
        spindles = try container.decode([String: IRSpindle].self, forKey: .spindles)
        order = try container.decode([OrderEntry].self, forKey: .order)
        resources = try container.decodeIfPresent([String].self, forKey: .resources) ?? []
        textResources = try container.decodeIfPresent([String].self, forKey: .textResources) ?? []
    }

    public struct OrderEntry: Codable, Equatable {
        public var bundle: String
        public var strands: [String]?

        public init(bundle: String, strands: [String]? = nil) {
            self.bundle = bundle
            self.strands = strands
        }
    }
}

public struct IRBundle: Codable, Equatable {
    public var name: String
    public var strands: [IRStrand]

    public var width: Int { strands.count }

    public init(name: String, strands: [IRStrand]) {
        self.name = name
        self.strands = strands
    }
}

public struct IRStrand: Codable, Equatable {
    public var name: String
    public var index: Int
    public var expr: IRExpr

    public init(name: String, index: Int, expr: IRExpr) {
        self.name = name
        self.index = index
        self.expr = expr
    }
}

public struct IRSpindle: Codable, Equatable {
    public var name: String
    public var params: [String]
    public var locals: [IRBundle]
    public var returns: [IRExpr]

    public var width: Int { returns.count }

    public init(name: String, params: [String], locals: [IRBundle], returns: [IRExpr]) {
        self.name = name
        self.params = params
        self.locals = locals
        self.returns = returns
    }
}

// MARK: - Expression Types

public indirect enum IRExpr: Codable, Equatable {
    case num(Double)
    case param(String)
    case index(bundle: String, indexExpr: IRExpr)
    case binaryOp(op: String, left: IRExpr, right: IRExpr)
    case unaryOp(op: String, operand: IRExpr)
    case call(spindle: String, args: [IRExpr])
    case builtin(name: String, args: [IRExpr])
    case extract(call: IRExpr, index: Int)
    case remap(base: IRExpr, substitutions: [String: IRExpr])
    /// Read from cache history buffer (used to break cycles in feedback effects)
    case cacheRead(cacheId: String, tapIndex: Int)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, value, name, bundle, field, indexExpr, op, left, right, operand
        case spindle, args, call, index, base, substitutions
        case resourceId, u, v, channel, offset
        case cacheId, tapIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "num":
            let value = try container.decode(Double.self, forKey: .value)
            self = .num(value)

        case "param":
            let name = try container.decode(String.self, forKey: .name)
            self = .param(name)

        case "index":
            let bundle = try container.decode(String.self, forKey: .bundle)
            // Handle both static field access and dynamic index
            if let field = try? container.decode(String.self, forKey: .field) {
                // Static field access: convert field name to index expression
                // For "me.x", "me.y", etc., we treat as special builtin coordinates
                self = .index(bundle: bundle, indexExpr: .param(field))
            } else if let indexExpr = try? container.decode(IRExpr.self, forKey: .indexExpr) {
                self = .index(bundle: bundle, indexExpr: indexExpr)
            } else {
                // Fallback for simple numeric index
                let index = try container.decode(Int.self, forKey: .index)
                self = .index(bundle: bundle, indexExpr: .num(Double(index)))
            }

        case "binary":
            let op = try container.decode(String.self, forKey: .op)
            let left = try container.decode(IRExpr.self, forKey: .left)
            let right = try container.decode(IRExpr.self, forKey: .right)
            self = .binaryOp(op: op, left: left, right: right)

        case "unary":
            let op = try container.decode(String.self, forKey: .op)
            let operand = try container.decode(IRExpr.self, forKey: .operand)
            self = .unaryOp(op: op, operand: operand)

        case "call":
            let spindle = try container.decode(String.self, forKey: .spindle)
            let args = try container.decode([IRExpr].self, forKey: .args)
            self = .call(spindle: spindle, args: args)

        case "builtin":
            let name = try container.decode(String.self, forKey: .name)
            let args = try container.decode([IRExpr].self, forKey: .args)
            self = .builtin(name: name, args: args)

        case "extract":
            let call = try container.decode(IRExpr.self, forKey: .call)
            let index = try container.decode(Int.self, forKey: .index)
            self = .extract(call: call, index: index)

        case "remap":
            let base = try container.decode(IRExpr.self, forKey: .base)
            let substitutions = try container.decode([String: IRExpr].self, forKey: .substitutions)
            self = .remap(base: base, substitutions: substitutions)

        case "texture":
            // Convert legacy format to builtin: texture(resourceId, u, v, channel)
            let resourceId = try container.decode(Int.self, forKey: .resourceId)
            let u = try container.decode(IRExpr.self, forKey: .u)
            let v = try container.decode(IRExpr.self, forKey: .v)
            let channel = try container.decode(Int.self, forKey: .channel)
            self = .builtin(name: "texture", args: [.num(Double(resourceId)), u, v, .num(Double(channel))])

        case "camera":
            // Convert legacy format to builtin: camera(u, v, channel)
            let u = try container.decode(IRExpr.self, forKey: .u)
            let v = try container.decode(IRExpr.self, forKey: .v)
            let channel = try container.decode(Int.self, forKey: .channel)
            self = .builtin(name: "camera", args: [u, v, .num(Double(channel))])

        case "microphone":
            // Convert legacy format to builtin: microphone(offset, channel)
            let offset = try container.decode(IRExpr.self, forKey: .offset)
            let channel = try container.decode(Int.self, forKey: .channel)
            self = .builtin(name: "microphone", args: [offset, .num(Double(channel))])

        case "cacheRead":
            let cacheId = try container.decode(String.self, forKey: .cacheId)
            let tapIndex = try container.decode(Int.self, forKey: .tapIndex)
            self = .cacheRead(cacheId: cacheId, tapIndex: tapIndex)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown expression type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .num(let value):
            try container.encode("num", forKey: .type)
            try container.encode(value, forKey: .value)

        case .param(let name):
            try container.encode("param", forKey: .type)
            try container.encode(name, forKey: .name)

        case .index(let bundle, let indexExpr):
            try container.encode("index", forKey: .type)
            try container.encode(bundle, forKey: .bundle)
            try container.encode(indexExpr, forKey: .indexExpr)

        case .binaryOp(let op, let left, let right):
            try container.encode("binary", forKey: .type)
            try container.encode(op, forKey: .op)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)

        case .unaryOp(let op, let operand):
            try container.encode("unary", forKey: .type)
            try container.encode(op, forKey: .op)
            try container.encode(operand, forKey: .operand)

        case .call(let spindle, let args):
            try container.encode("call", forKey: .type)
            try container.encode(spindle, forKey: .spindle)
            try container.encode(args, forKey: .args)

        case .builtin(let name, let args):
            try container.encode("builtin", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(args, forKey: .args)

        case .extract(let call, let index):
            try container.encode("extract", forKey: .type)
            try container.encode(call, forKey: .call)
            try container.encode(index, forKey: .index)

        case .remap(let base, let substitutions):
            try container.encode("remap", forKey: .type)
            try container.encode(base, forKey: .base)
            try container.encode(substitutions, forKey: .substitutions)

        case .cacheRead(let cacheId, let tapIndex):
            try container.encode("cacheRead", forKey: .type)
            try container.encode(cacheId, forKey: .cacheId)
            try container.encode(tapIndex, forKey: .tapIndex)
        }
    }
}

// MARK: - Expression Utilities

extension IRExpr {
    /// Get free variables (bundle.strand references) in this expression
    public func freeVars() -> Set<String> {
        switch self {
        case .num:
            return []
        case .param:
            return []
        case .index(let bundle, let indexExpr):
            var vars = indexExpr.freeVars()
            if case .num(let idx) = indexExpr {
                vars.insert("\(bundle).\(Int(idx))")
            } else if case .param(let field) = indexExpr {
                vars.insert("\(bundle).\(field)")
            } else {
                vars.insert(bundle)
            }
            return vars
        case .binaryOp(_, let left, let right):
            return left.freeVars().union(right.freeVars())
        case .unaryOp(_, let operand):
            return operand.freeVars()
        case .call(_, let args):
            return args.reduce(into: Set<String>()) { $0.formUnion($1.freeVars()) }
        case .builtin(_, let args):
            return args.reduce(into: Set<String>()) { $0.formUnion($1.freeVars()) }
        case .extract(let call, _):
            return call.freeVars()
        case .remap(let base, let substitutions):
            var vars = base.freeVars()
            for (key, _) in substitutions {
                vars.remove(key)
            }
            for (_, expr) in substitutions {
                vars.formUnion(expr.freeVars())
            }
            return vars
        case .cacheRead:
            return []  // cacheRead is a terminal - no bundle references
        }
    }

    /// Get free variables for current-tick dependency analysis.
    /// Same as freeVars() except: for .remap nodes where substitution keys include "me.t",
    /// exclude the base expression's free vars (they're previous-tick dependencies).
    public func currentTickFreeVars() -> Set<String> {
        switch self {
        case .num:
            return []
        case .param:
            return []
        case .index(let bundle, let indexExpr):
            var vars = indexExpr.currentTickFreeVars()
            if case .num(let idx) = indexExpr {
                vars.insert("\(bundle).\(Int(idx))")
            } else if case .param(let field) = indexExpr {
                vars.insert("\(bundle).\(field)")
            } else {
                vars.insert(bundle)
            }
            return vars
        case .binaryOp(_, let left, let right):
            return left.currentTickFreeVars().union(right.currentTickFreeVars())
        case .unaryOp(_, let operand):
            return operand.currentTickFreeVars()
        case .call(_, let args):
            return args.reduce(into: Set<String>()) { $0.formUnion($1.currentTickFreeVars()) }
        case .builtin(_, let args):
            return args.reduce(into: Set<String>()) { $0.formUnion($1.currentTickFreeVars()) }
        case .extract(let call, _):
            return call.currentTickFreeVars()
        case .remap(let base, let substitutions):
            let isTemporalRemap = substitutions.keys.contains("me.t")
            if isTemporalRemap {
                // For temporal remaps, base refs are previous-tick -- only include substitution expr vars
                var vars = Set<String>()
                for (_, expr) in substitutions {
                    vars.formUnion(expr.currentTickFreeVars())
                }
                return vars
            }
            // Non-temporal remap: same as freeVars()
            var vars = base.currentTickFreeVars()
            for (key, _) in substitutions {
                vars.remove(key)
            }
            for (_, expr) in substitutions {
                vars.formUnion(expr.currentTickFreeVars())
            }
            return vars
        case .cacheRead:
            return []
        }
    }

    /// Check if expression uses a specific builtin
    public func usesBuiltin(_ name: String) -> Bool {
        if case .builtin(let n, _) = self, n == name { return true }
        var found = false
        forEachChild { if $0.usesBuiltin(name) { found = true } }
        return found
    }

    /// Get all builtins used in this expression
    public func allBuiltins() -> Set<String> {
        var result = Set<String>()
        func visit(_ e: IRExpr) {
            if case .builtin(let name, _) = e { result.insert(name) }
            e.forEachChild(visit)
        }
        visit(self)
        return result
    }

    /// Check if expression tree contains any spindle `.call` node (indicates "heavy" expression)
    public func containsCall() -> Bool {
        if case .call = self { return true }
        var found = false
        forEachChild { if $0.containsCall() { found = true } }
        return found
    }

    /// Count the total number of nodes in this expression tree.
    public func nodeCount() -> Int {
        var count = 1
        forEachChild { count += $0.nodeCount() }
        return count
    }

    /// Check if expression is complex enough to warrant pre-rendering to an intermediate texture.
    /// After spindle inlining, .call nodes may not exist, so we use node count as the heuristic.
    public func isHeavyExpression(threshold: Int = 30) -> Bool {
        return containsCall() || nodeCount() >= threshold
    }
}

// MARK: - Tree Traversal

extension IRExpr {
    /// Apply a transform to all direct children, preserving node structure.
    public func mapChildren(_ transform: (IRExpr) throws -> IRExpr) rethrows -> IRExpr {
        switch self {
        case .num, .param, .cacheRead:
            return self
        case .index(let bundle, let indexExpr):
            return .index(bundle: bundle, indexExpr: try transform(indexExpr))
        case .binaryOp(let op, let left, let right):
            return .binaryOp(op: op, left: try transform(left), right: try transform(right))
        case .unaryOp(let op, let operand):
            return .unaryOp(op: op, operand: try transform(operand))
        case .call(let spindle, let args):
            return .call(spindle: spindle, args: try args.map(transform))
        case .builtin(let name, let args):
            return .builtin(name: name, args: try args.map(transform))
        case .extract(let call, let index):
            return .extract(call: try transform(call), index: index)
        case .remap(let base, let subs):
            var newSubs: [String: IRExpr] = [:]
            for (key, value) in subs {
                newSubs[key] = try transform(value)
            }
            return .remap(base: try transform(base), substitutions: newSubs)
        }
    }

    /// Collect all bundle names referenced via `.index` in this expression tree.
    public func collectBundleReferences(excludeMe: Bool = false) -> Set<String> {
        var result = Set<String>()
        func visit(_ e: IRExpr) {
            if case .index(let bundle, _) = e {
                if !(excludeMe && bundle == "me") { result.insert(bundle) }
            }
            e.forEachChild(visit)
        }
        visit(self)
        return result
    }

    /// Visit all direct children.
    public func forEachChild(_ visitor: (IRExpr) -> Void) {
        switch self {
        case .num, .param, .cacheRead:
            break
        case .index(_, let indexExpr):
            visitor(indexExpr)
        case .binaryOp(_, let left, let right):
            visitor(left)
            visitor(right)
        case .unaryOp(_, let operand):
            visitor(operand)
        case .call(_, let args):
            args.forEach(visitor)
        case .builtin(_, let args):
            args.forEach(visitor)
        case .extract(let call, _):
            visitor(call)
        case .remap(let base, let subs):
            visitor(base)
            subs.values.forEach(visitor)
        }
    }
}

// MARK: - Description

extension IRExpr: CustomStringConvertible {
    public var description: String {
        switch self {
        case .num(let value):
            return "\(value)"
        case .param(let name):
            return name
        case .index(let bundle, let indexExpr):
            if case .param(let field) = indexExpr {
                return "\(bundle).\(field)"
            }
            return "\(bundle).(\(indexExpr))"
        case .binaryOp(let op, let left, let right):
            return "(\(left) \(op) \(right))"
        case .unaryOp(let op, let operand):
            return "\(op)\(operand)"
        case .call(let spindle, let args):
            return "\(spindle)(\(args.map { $0.description }.joined(separator: ", ")))"
        case .builtin(let name, let args):
            return "\(name)(\(args.map { $0.description }.joined(separator: ", ")))"
        case .extract(let call, let index):
            return "\(call).\(index)"
        case .remap(let base, let substitutions):
            let subs = substitutions.map { "\($0.key) ~ \($0.value)" }.joined(separator: ", ")
            return "\(base)[\(subs)]"
        case .cacheRead(let cacheId, let tapIndex):
            return "cacheRead(\(cacheId), \(tapIndex))"
        }
    }
}
