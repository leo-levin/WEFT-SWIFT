// WeftLowering.swift - Transform AST to IR

import Foundation

// MARK: - Lowering Error

public enum LoweringError: Error, LocalizedError {
    case unknownBundle(String)
    case unknownSpindle(String)
    case unknownStrand(String, String)
    case unknownIdentifier(String)
    case duplicateSpindle(String)
    case missingReturnIndex(String, Int)
    case widthMismatch(expected: Int, got: Int, context: String)
    case rangeOutOfBounds(Int, Int)
    case rangeOutsidePattern
    case bareStrandOutsidePattern
    case invalidRemapArg
    case circularDependency(String)
    case invalidExpression(String)

    public var errorDescription: String? {
        switch self {
        case .unknownBundle(let name):
            return "Unknown bundle '\(name)'"
        case .unknownSpindle(let name):
            return "Unknown spindle '\(name)'"
        case .unknownStrand(let bundle, let strand):
            return "Unknown strand '\(bundle).\(strand)'"
        case .unknownIdentifier(let name):
            return "Unknown identifier '\(name)'"
        case .duplicateSpindle(let name):
            return "Duplicate spindle definition '\(name)'"
        case .missingReturnIndex(let spindle, let index):
            return "Spindle '\(spindle)' missing return.\(index)"
        case .widthMismatch(let expected, let got, let context):
            return "Width mismatch in \(context): expected \(expected), got \(got)"
        case .rangeOutOfBounds(let index, let max):
            return "Index \(index) out of range [0..\(max))"
        case .rangeOutsidePattern:
            return "Range expressions (0..3) are only valid inside pattern blocks"
        case .bareStrandOutsidePattern:
            return "Bare strand access (.0 or .x) only valid inside pattern blocks"
        case .invalidRemapArg:
            return "Invalid remap argument"
        case .circularDependency(let bundle):
            return "Circular dependency involving '\(bundle)'"
        case .invalidExpression(let msg):
            return msg
        }
    }
}

// MARK: - Built-in Functions

private let BUILTINS: Set<String> = SharedBuiltins.domainAgnosticNames.union([
    "osc", "cache", "key"  // handled by desugar/lowering, not backends
])

private struct ResourceBuiltin {
    let width: Int
    let minArgs: Int
    let maxArgs: Int

    init(width: Int, argCount: Int) {
        self.width = width
        self.minArgs = argCount
        self.maxArgs = argCount
    }

    init(width: Int, minArgs: Int, maxArgs: Int) {
        self.width = width
        self.minArgs = minArgs
        self.maxArgs = maxArgs
    }
}

private let RESOURCE_BUILTINS: [String: ResourceBuiltin] = [
    "texture": ResourceBuiltin(width: 3, argCount: 3),
    "camera": ResourceBuiltin(width: 3, argCount: 2),
    "microphone": ResourceBuiltin(width: 2, argCount: 1),
    "mouse": ResourceBuiltin(width: 3, argCount: 0),  // Returns [x, y, down]
    "load": ResourceBuiltin(width: 3, minArgs: 1, maxArgs: 3),  // load(path) or load(path, u, v)
    "sample": ResourceBuiltin(width: 2, minArgs: 1, maxArgs: 2),  // sample(path) or sample(path, offset)
    "text": ResourceBuiltin(width: 1, argCount: 3)  // text(content, x, y)
]

private let ME_STRANDS: [String: Int] = [
    "x": 0, "y": 1, "u": 2, "v": 3, "w": 4, "h": 5,
    "t": 6,
    "i": 0, "rate": 7, "duration": 8, "sampleRate": 7
]

// MARK: - Lowering Context

public class WeftLowering {
    private var bundleInfo: [String: BundleInfo] = [:]
    private var spindleInfo: [String: SpindleInfo] = [:]
    private var bundles: [String: IRBundle] = [:]
    private var spindles: [String: IRSpindle] = [:]
    private var declarations: [Declaration] = []
    private var resources: [String] = []
    private var resourceIndex: [String: Int] = [:]
    private var textResources: [String] = []
    private var textResourceIndex: [String: Int] = [:]

    // Current scope for spindle body lowering
    private var scope: Scope?

    // Lowered expressions for pattern-block-scoped locals (inline substitution)
    private var patternLocals: [String: [IRExpr]]?

    // Strand name-to-index mapping for the current pattern step's input
    private var patternStrandNames: [String: Int]?

    struct BundleInfo {
        var width: Int
        var strandIndex: [String: Int]

        init() {
            self.width = 0
            self.strandIndex = [:]
        }
    }

    struct SpindleInfo {
        var params: Set<String>
        var width: Int
    }

    struct Declaration {
        var bundle: String
        var strandNames: Set<String>
        var strands: [IRStrand]
    }

    struct Scope {
        var params: Set<String>
        var locals: [String: BundleInfo]
    }

    public init() {}

    // MARK: - Public API

    public func lower(_ program: WeftProgram) throws -> IRProgram {
        // Reset state
        bundleInfo = [:]
        spindleInfo = [:]
        bundles = [:]
        spindles = [:]
        declarations = []
        resources = []
        resourceIndex = [:]
        textResources = []
        textResourceIndex = [:]
        scope = nil
        patternLocals = nil
        patternStrandNames = nil

        // First pass: register all bundles and spindles
        for stmt in program.statements {
            switch stmt {
            case .bundleDecl(let decl):
                registerBundle(decl)
            case .spindleDef(let def):
                try registerSpindle(def)
            }
        }

        // Second pass: lower all statements
        for stmt in program.statements {
            switch stmt {
            case .bundleDecl(let decl):
                try lowerBundleDecl(decl)
            case .spindleDef(let def):
                try lowerSpindleDef(def)
            }
        }

        // Compute topological order
        let order = try topologicalSort()

        return IRProgram(bundles: bundles, spindles: spindles, order: order, resources: resources, textResources: textResources)
    }

    // MARK: - Registration Pass

    private func registerBundle(_ decl: BundleDecl) {
        var info = bundleInfo[decl.name] ?? BundleInfo()

        for output in decl.outputs {
            switch output {
            case .index(let idx):
                info.width = max(info.width, idx + 1)
                info.strandIndex[String(idx)] = idx
            case .name(let name):
                if info.strandIndex[name] == nil {
                    info.strandIndex[name] = info.width
                    info.width += 1
                }
            }
        }

        bundleInfo[decl.name] = info
    }

    private func registerSpindle(_ def: SpindleDef) throws {
        if spindleInfo[def.name] != nil {
            throw LoweringError.duplicateSpindle(def.name)
        }

        var maxIndex = -1
        var indices = Set<Int>()
        var returnListWidth: Int?

        for stmt in def.body {
            switch stmt {
            case .returnAssign(let ret):
                indices.insert(ret.index)
                maxIndex = max(maxIndex, ret.index)
            case .returnList(let exprs):
                returnListWidth = exprs.count
                for i in 0..<exprs.count {
                    indices.insert(i)
                    maxIndex = max(maxIndex, i)
                }
            case .bundleDecl:
                break
            }
        }

        // Verify all indices from 0..maxIndex are covered
        for i in 0...maxIndex {
            if !indices.contains(i) {
                throw LoweringError.missingReturnIndex(def.name, i)
            }
        }

        spindleInfo[def.name] = SpindleInfo(
            params: Set(def.params),
            width: returnListWidth ?? (maxIndex + 1)
        )
    }

    // MARK: - Lowering Pass

    private func lowerBundleDecl(_ decl: BundleDecl) throws {
        // Determine outputs - either explicit or inferred from expression
        let outputs: [OutputItem]
        let width: Int

        if decl.outputs.isEmpty {
            // Infer width from expression
            width = try inferWidth(decl.expr)
            outputs = (0..<width).map { OutputItem.index($0) }

            // Update bundleInfo with inferred width
            var info = bundleInfo[decl.name] ?? BundleInfo()
            info.width = width
            for i in 0..<width {
                info.strandIndex[String(i)] = i
            }
            bundleInfo[decl.name] = info
        } else {
            outputs = decl.outputs
            width = decl.outputs.count
        }

        let info = bundleInfo[decl.name]!
        let exprs = try lowerToStrands(decl.expr, width: width, subs: nil)

        var bundle = bundles[decl.name] ?? IRBundle(name: decl.name, strands: [])

        var strandNames = Set<String>()
        var declStrands: [IRStrand] = []

        for (i, output) in outputs.enumerated() {
            let isIdx: Bool
            let name: String
            let idx: Int

            switch output {
            case .index(let n):
                isIdx = true
                name = bundle.strands.first { $0.index == n }?.name ?? String(n)
                idx = n
            case .name(let n):
                isIdx = false
                name = n
                idx = info.strandIndex[n]!
            }

            strandNames.insert(name)

            let strand = IRStrand(name: name, index: idx, expr: exprs[i])
            declStrands.append(strand)

            // Update or add strand
            if let existingIdx = bundle.strands.firstIndex(where: { isIdx ? $0.index == idx : $0.name == name }) {
                bundle.strands[existingIdx] = strand
            } else {
                bundle.strands.append(strand)
            }
        }

        bundles[decl.name] = bundle
        declarations.append(Declaration(bundle: decl.name, strandNames: strandNames, strands: declStrands))
    }

    private func lowerSpindleDef(_ def: SpindleDef) throws {
        let info = spindleInfo[def.name]!

        scope = Scope(params: info.params, locals: [:])

        // First pass: Register all locals in scope (enables forward references)
        // This allows cache(out.val, ...) to reference out.val before it's defined
        for stmt in def.body {
            if case .bundleDecl(let decl) = stmt {
                var strandIndex: [String: Int] = [:]
                for (i, output) in decl.outputs.enumerated() {
                    strandIndex[output.stringValue] = i
                }
                scope?.locals[decl.name] = BundleInfo(width: decl.outputs.count, strandIndex: strandIndex)
            }
        }

        // Second pass: Lower expressions (now all locals are in scope)
        var locals: [IRBundle] = []
        var returns: [IRExpr?] = Array(repeating: nil, count: info.width)

        for stmt in def.body {
            switch stmt {
            case .bundleDecl(let decl):
                // Determine outputs - either explicit or inferred from expression
                let outputs: [OutputItem]
                let localWidth: Int

                if decl.outputs.isEmpty {
                    // Infer width from expression
                    localWidth = try inferWidth(decl.expr)
                    outputs = (0..<localWidth).map { OutputItem.index($0) }
                } else {
                    outputs = decl.outputs
                    localWidth = decl.outputs.count
                }

                let exprs = try lowerToStrands(decl.expr, width: localWidth, subs: nil)
                var strandIndex: [String: Int] = [:]
                var strands: [IRStrand] = []

                for (i, output) in outputs.enumerated() {
                    let name = output.stringValue
                    strandIndex[name] = i
                    strands.append(IRStrand(name: name, index: i, expr: exprs[i]))
                }

                locals.append(IRBundle(name: decl.name, strands: strands))

            case .returnAssign(let ret):
                let width = try inferWidth(ret.expr)
                if width != 1 {
                    throw LoweringError.widthMismatch(expected: 1, got: width, context: "return.\(ret.index)")
                }
                returns[ret.index] = try lowerExpr(ret.expr, subs: nil)

            case .returnList(let exprs):
                for (i, expr) in exprs.enumerated() {
                    returns[i] = try lowerExpr(expr, subs: nil)
                }
            }
        }

        scope = nil

        spindles[def.name] = IRSpindle(
            name: def.name,
            params: def.params,
            locals: locals,
            returns: returns.compactMap { $0 }
        )
    }

    // MARK: - Expression Lowering

    private func lowerExpr(_ expr: Expr, subs: [IRExpr]?) throws -> IRExpr {
        switch expr {
        case .number(let n):
            return .num(n)

        case .string(let s):
            throw LoweringError.invalidExpression("String literals not supported in expressions: \"\(s)\"")

        case .identifier(let name):
            if let scope = scope, scope.params.contains(name) {
                return .param(name)
            }
            throw LoweringError.unknownIdentifier(name)

        case .strandAccess(let access):
            if access.bundle == nil {
                guard let subs = subs else {
                    throw LoweringError.bareStrandOutsidePattern
                }
                return try lowerBareStrandAccess(access.accessor, subs: subs)
            }
            return try lowerStrandAccess(access, subs: subs)

        case .binaryOp(let op):
            let left = try lowerExpr(op.left, subs: subs)
            let right = try lowerExpr(op.right, subs: subs)
            return .binaryOp(op: op.op.rawValue, left: left, right: right)

        case .unaryOp(let op):
            let operand = try lowerExpr(op.operand, subs: subs)
            return .unaryOp(op: op.op.rawValue, operand: operand)

        case .spindleCall(let call):
            // Check for single-width resource builtins (like text) that need special string handling
            if let spec = RESOURCE_BUILTINS[call.name], spec.width == 1 {
                let results = try lowerResourceCall(call.name, args: call.args, width: 1, subs: subs)
                return results[0]
            }

            let irCall = try lowerCall(call.name, args: call.args, subs: subs)

            if BUILTINS.contains(call.name) {
                return irCall
            }

            if let info = spindleInfo[call.name] {
                if info.width == 1 {
                    return .extract(call: irCall, index: 0)
                }
                throw LoweringError.widthMismatch(expected: 1, got: info.width, context: "spindle '\(call.name)' in single-value context")
            }

            throw LoweringError.unknownSpindle(call.name)

        case .callExtract(let extract):
            guard case .spindleCall(let call) = extract.call else {
                throw LoweringError.invalidExpression("Call extract requires spindle call")
            }
            // Handle resource builtins specially (they may have string arguments)
            if let spec = RESOURCE_BUILTINS[call.name] {
                if extract.index < 0 || extract.index >= spec.width {
                    throw LoweringError.rangeOutOfBounds(extract.index, spec.width)
                }
                let results = try lowerResourceCall(call.name, args: call.args, width: spec.width, subs: subs)
                return results[extract.index]
            }
            let irCall = try lowerCall(call.name, args: call.args, subs: subs)
            return .extract(call: irCall, index: extract.index)

        case .remapExpr(let remap):
            return try lowerRemapExpr(remap, subs: subs)

        case .bundleLit:
            throw LoweringError.invalidExpression("Bundle literal not valid in single-value context")

        case .chainExpr:
            throw LoweringError.invalidExpression("Chain expression not valid in single-value context")

        case .rangeExpr:
            throw LoweringError.rangeOutsidePattern

        case .tagExpr:
            throw LoweringError.invalidExpression("Tag expressions must be desugared before lowering")
        }
    }

    private func lowerToStrands(_ expr: Expr, width: Int, subs: [IRExpr]?) throws -> [IRExpr] {
        switch expr {
        case .bundleLit(let elements):
            var result: [IRExpr] = []
            for el in elements {
                let w = try inferWidth(el)
                if w == 1 {
                    result.append(try lowerExpr(el, subs: subs))
                } else {
                    result.append(contentsOf: try lowerToStrands(el, width: w, subs: subs))
                }
            }
            if result.count != width {
                throw LoweringError.widthMismatch(expected: width, got: result.count, context: "bundle literal")
            }
            return result

        case .chainExpr(let chain):
            return try lowerChainExpr(chain, expectedWidth: width)

        case .spindleCall(let call):
            if let spec = RESOURCE_BUILTINS[call.name] {
                return try lowerResourceCall(call.name, args: call.args, width: width, subs: subs)
            }

            let info = spindleInfo[call.name]
            let isBuiltin = BUILTINS.contains(call.name)
            let w = info?.width ?? (isBuiltin ? 1 : nil)

            guard let actualWidth = w else {
                throw LoweringError.unknownSpindle(call.name)
            }

            if actualWidth != width {
                throw LoweringError.widthMismatch(expected: width, got: actualWidth, context: "spindle '\(call.name)'")
            }

            let irCall = try lowerCall(call.name, args: call.args, subs: subs)

            if isBuiltin {
                return [irCall]
            }

            return (0..<actualWidth).map { .extract(call: irCall, index: $0) }

        case .identifier(let name):
            if name == "me" {
                let meWidth = ME_STRANDS.count
                if meWidth < width {
                    throw LoweringError.widthMismatch(expected: width, got: meWidth, context: "me")
                }
                return (0..<width).map { .index(bundle: "me", indexExpr: .num(Double($0))) }
            }

            // Check pattern-scoped locals first (inline substitution)
            if let locals = patternLocals, let strandExprs = locals[name] {
                if strandExprs.count != width {
                    throw LoweringError.widthMismatch(expected: width, got: strandExprs.count, context: "pattern local '\(name)'")
                }
                return strandExprs
            }

            // Guard against forward references to not-yet-lowered pattern locals
            if patternLocals != nil,
               let localScope = scope, localScope.locals[name] != nil,
               patternLocals?[name] == nil, bundleInfo[name] == nil {
                throw LoweringError.invalidExpression("Pattern local '\(name)' must be defined before use")
            }

            guard let info = bundleInfo[name] else {
                if let scope = scope, let local = scope.locals[name] {
                    if local.width != width {
                        throw LoweringError.widthMismatch(expected: width, got: local.width, context: "local '\(name)'")
                    }
                    return (0..<width).map { .index(bundle: name, indexExpr: .num(Double($0))) }
                }
                throw LoweringError.unknownBundle(name)
            }

            if info.width != width {
                throw LoweringError.widthMismatch(expected: width, got: info.width, context: "bundle '\(name)'")
            }
            return (0..<width).map { .index(bundle: name, indexExpr: .num(Double($0))) }

        default:
            if width == 1 {
                return [try lowerExpr(expr, subs: subs)]
            }
            throw LoweringError.invalidExpression("Cannot expand \(type(of: expr)) to \(width) strands")
        }
    }

    private func inferStrandNames(_ expr: Expr) -> [String: Int]? {
        switch expr {
        case .identifier(let name):
            if let info = bundleInfo[name] { return info.strandIndex }
            if let scope = scope, let local = scope.locals[name] { return local.strandIndex }
            return nil
        default:
            return nil
        }
    }

    private func lowerChainExpr(_ chain: ChainExpr, expectedWidth: Int) throws -> [IRExpr] {
        let savedPatternStrandNames = patternStrandNames

        var exprs = try lowerToStrands(chain.base, width: try inferWidth(chain.base), subs: nil)
        var strandNames = inferStrandNames(chain.base)

        for pattern in chain.patterns {
            let prev = exprs
            patternStrandNames = strandNames

            switch pattern.content {
            case .inline(let outputs):
                exprs = try lowerInlinePatternOutputs(outputs, prev: prev)

            case .fullBody(let body):
                exprs = try lowerFullBodyPattern(body, prev: prev)
            }

            // Pattern outputs are positional — no named strands
            strandNames = nil
        }

        patternStrandNames = savedPatternStrandNames

        if exprs.count != expectedWidth {
            throw LoweringError.widthMismatch(expected: expectedWidth, got: exprs.count, context: "chain expression")
        }

        return exprs
    }

    private func lowerInlinePatternOutputs(_ outputs: [PatternOutput], prev: [IRExpr]) throws -> [IRExpr] {
        var exprs: [IRExpr] = []

        for output in outputs {
            let ranges = findRanges(output.value)

            if ranges.isEmpty {
                // No ranges - process normally
                let w = try inferWidth(output.value)
                if w == 1 {
                    exprs.append(try lowerExpr(output.value, subs: prev))
                } else {
                    exprs.append(contentsOf: try lowerToStrands(output.value, width: w, subs: prev))
                }
            } else {
                // Has ranges - expand the expression
                let sizes = ranges.map { computeRangeSize($0, defaultWidth: prev.count) }

                // Verify all ranges have the same size
                let firstSize = sizes[0]
                for size in sizes {
                    if size != firstSize {
                        throw LoweringError.invalidExpression("Range size mismatch: found ranges of size \(firstSize) and \(size)")
                    }
                }

                // Expand for each iteration
                for iterNum in 0..<firstSize {
                    let expanded = expandRangeExpr(output.value, iterNum: iterNum, defaultWidth: prev.count)
                    let w = try inferWidth(expanded)
                    if w == 1 {
                        exprs.append(try lowerExpr(expanded, subs: prev))
                    } else {
                        exprs.append(contentsOf: try lowerToStrands(expanded, width: w, subs: prev))
                    }
                }
            }
        }

        return exprs
    }

    private func lowerFullBodyPattern(_ body: [BodyStatement], prev: [IRExpr]) throws -> [IRExpr] {
        // Save current state
        let savedScope = scope
        let savedPatternLocals = patternLocals
        let savedPatternStrandNames = patternStrandNames

        // Create a scope for the pattern block with pattern locals
        var localScope = Scope(params: savedScope?.params ?? [], locals: savedScope?.locals ?? [:])
        patternLocals = [:]

        // First pass: register all locals in scope (for forward references in cache, etc.)
        for stmt in body {
            if case .bundleDecl(let decl) = stmt {
                var strandIndex: [String: Int] = [:]
                if decl.outputs.isEmpty {
                    let w = try inferWidth(decl.expr)
                    for i in 0..<w {
                        strandIndex[String(i)] = i
                    }
                    localScope.locals[decl.name] = BundleInfo(width: w, strandIndex: strandIndex)
                } else {
                    for (i, output) in decl.outputs.enumerated() {
                        strandIndex[output.stringValue] = i
                    }
                    localScope.locals[decl.name] = BundleInfo(width: decl.outputs.count, strandIndex: strandIndex)
                }
            }
        }

        scope = localScope

        // Second pass: lower each local's expression with subs = prev
        for stmt in body {
            if case .bundleDecl(let decl) = stmt {
                let localInfo = localScope.locals[decl.name]!
                let loweredStrands = try lowerToStrands(decl.expr, width: localInfo.width, subs: prev)
                patternLocals?[decl.name] = loweredStrands
            }
        }

        // Collect return outputs
        var returnOutputs: [PatternOutput]?
        var returnsByIndex: [Int: IRExpr] = [:]

        for stmt in body {
            switch stmt {
            case .returnList(let exprs):
                returnOutputs = exprs.map { PatternOutput(value: $0) }
            case .returnAssign(let ret):
                returnsByIndex[ret.index] = try lowerExpr(ret.expr, subs: prev)
            case .bundleDecl:
                break
            }
        }

        var result: [IRExpr]

        if let outputs = returnOutputs {
            // return = [expr, expr, ...] — process like inline pattern outputs
            result = try lowerInlinePatternOutputs(outputs, prev: prev)
        } else if !returnsByIndex.isEmpty {
            // return.0, return.1, ... — collect by index
            let maxIdx = returnsByIndex.keys.max()!
            result = []
            for i in 0...maxIdx {
                guard let expr = returnsByIndex[i] else {
                    throw LoweringError.missingReturnIndex("pattern block", i)
                }
                result.append(expr)
            }
        } else {
            throw LoweringError.invalidExpression("Full-body pattern block must have at least one return statement")
        }

        // Restore state
        scope = savedScope
        patternLocals = savedPatternLocals
        patternStrandNames = savedPatternStrandNames

        return result
    }

    private func lowerBareStrandAccess(_ accessor: StrandAccessor, subs: [IRExpr]) throws -> IRExpr {
        switch accessor {
        case .index(let idx):
            let resolved = idx < 0 ? subs.count + idx : idx
            if resolved < 0 || resolved >= subs.count {
                throw LoweringError.rangeOutOfBounds(idx, subs.count)
            }
            return subs[resolved]

        case .name(let name):
            if let nameMap = patternStrandNames, let idx = nameMap[name] {
                if idx < 0 || idx >= subs.count {
                    throw LoweringError.rangeOutOfBounds(idx, subs.count)
                }
                return subs[idx]
            }
            throw LoweringError.invalidExpression("Unknown strand name '.\(name)' — input has no named strands")

        case .expr(let indexExpr):
            let irIndex = try lowerExpr(indexExpr, subs: subs)
            return buildSelector(subs, index: irIndex)
        }
    }

    private func lowerStrandAccess(_ access: StrandAccess, subs: [IRExpr]?) throws -> IRExpr {
        guard let bundle = access.bundle else {
            throw LoweringError.bareStrandOutsidePattern
        }

        switch bundle {
        case .bundleLit(let elements):
            let lowered = try elements.map { try lowerExpr($0, subs: subs) }
            switch access.accessor {
            case .index(let idx):
                let resolved = idx < 0 ? lowered.count + idx : idx
                if resolved < 0 || resolved >= lowered.count {
                    throw LoweringError.rangeOutOfBounds(idx, lowered.count)
                }
                return lowered[resolved]
            case .expr(let indexExpr):
                let irIndex = try lowerExpr(indexExpr, subs: subs)
                return buildSelector(lowered, index: irIndex)
            case .name:
                throw LoweringError.invalidExpression("Cannot use named access on bundle literal")
            }

        case .named(let bundleName):
            if bundleName == "me" {
                return try lowerMeAccess(access.accessor, subs: subs)
            }

            // Check pattern-scoped locals first (inline substitution)
            if let locals = patternLocals, let strandExprs = locals[bundleName] {
                switch access.accessor {
                case .index(let idx):
                    let resolved = idx < 0 ? strandExprs.count + idx : idx
                    if resolved < 0 || resolved >= strandExprs.count {
                        throw LoweringError.rangeOutOfBounds(idx, strandExprs.count)
                    }
                    return strandExprs[resolved]
                case .name(let name):
                    // Look up name in scope's local info
                    if let localInfo = scope?.locals[bundleName], let idx = localInfo.strandIndex[name] {
                        return strandExprs[idx]
                    }
                    throw LoweringError.unknownStrand(bundleName, name)
                case .expr(let indexExpr):
                    let irIndex = try lowerExpr(indexExpr, subs: subs)
                    return buildSelector(strandExprs, index: irIndex)
                }
            }

            // Guard against forward references to not-yet-lowered pattern locals
            if patternLocals != nil,
               let localScope = scope, localScope.locals[bundleName] != nil,
               patternLocals?[bundleName] == nil, bundleInfo[bundleName] == nil {
                throw LoweringError.invalidExpression("Pattern local '\(bundleName)' must be defined before use")
            }

            let info = try getBundleInfo(bundleName)

            switch access.accessor {
            case .name(let name):
                guard let idx = info.strandIndex[name] else {
                    throw LoweringError.unknownStrand(bundleName, name)
                }
                return .index(bundle: bundleName, indexExpr: .num(Double(idx)))

            case .index(let idx):
                let resolved = idx < 0 ? info.width + idx : idx
                if resolved < 0 || resolved >= info.width {
                    throw LoweringError.rangeOutOfBounds(idx, info.width)
                }
                return .index(bundle: bundleName, indexExpr: .num(Double(resolved)))

            case .expr(let indexExpr):
                // Expand dynamic indexing to select builtin for runtime resolution
                let irIndex = try lowerExpr(indexExpr, subs: subs)

                // Build array of all strand expressions as static indices
                let strandExprs = (0..<info.width).map { idx -> IRExpr in
                    .index(bundle: bundleName, indexExpr: .num(Double(idx)))
                }

                // Generate select(index, strand0, strand1, ...) for runtime selection
                return buildSelector(strandExprs, index: irIndex)
            }
        }
    }

    private func lowerMeAccess(_ accessor: StrandAccessor, subs: [IRExpr]?) throws -> IRExpr {
        let meWidth = ME_STRANDS.count

        switch accessor {
        case .name(let name):
            guard let idx = ME_STRANDS[name] else {
                throw LoweringError.unknownStrand("me", name)
            }
            // Use param with field name for special handling in IR
            return .index(bundle: "me", indexExpr: .param(name))

        case .index(let idx):
            let resolved = idx < 0 ? meWidth + idx : idx
            return .index(bundle: "me", indexExpr: .num(Double(resolved)))

        case .expr(let indexExpr):
            let irIndex = try lowerExpr(indexExpr, subs: subs)
            return .index(bundle: "me", indexExpr: irIndex)
        }
    }

    private func lowerRemapExpr(_ remap: RemapExpr, subs: [IRExpr]?) throws -> IRExpr {
        let irBase = try lowerExpr(remap.base, subs: subs)

        var subMap: [String: IRExpr] = [:]

        for r in remap.remappings {
            let domainIR = try lowerStrandAccess(r.domain, subs: subs)

            // Extract the key from the domain
            let key: String
            if case .index(let bundle, let indexExpr) = domainIR {
                if case .num(let idx) = indexExpr {
                    key = "\(bundle).\(Int(idx))"
                } else if case .param(let field) = indexExpr {
                    key = "\(bundle).\(field)"
                } else {
                    throw LoweringError.invalidRemapArg
                }
            } else {
                throw LoweringError.invalidRemapArg
            }
            subMap[key] = try lowerExpr(r.expr, subs: subs)
        }

        return .remap(base: irBase, substitutions: subMap)
    }

    private func lowerCall(_ name: String, args: [Expr], subs: [IRExpr]?) throws -> IRExpr {
        let irArgs = try args.map { try lowerExpr($0, subs: subs) }

        if BUILTINS.contains(name) {
            return .builtin(name: name, args: irArgs)
        }

        guard let info = spindleInfo[name] else {
            throw LoweringError.unknownSpindle(name)
        }

        if irArgs.count != info.params.count {
            throw LoweringError.invalidExpression("Spindle '\(name)' expects \(info.params.count) args, got \(irArgs.count)")
        }

        return .call(spindle: name, args: irArgs)
    }

    private func lowerResourceCall(_ name: String, args: [Expr], width: Int, subs: [IRExpr]?) throws -> [IRExpr] {
        guard let spec = RESOURCE_BUILTINS[name] else {
            throw LoweringError.unknownSpindle(name)
        }

        // Check arg count is in valid range
        if args.count < spec.minArgs || args.count > spec.maxArgs {
            if spec.minArgs == spec.maxArgs {
                throw LoweringError.invalidExpression("\(name)() expects \(spec.minArgs) args, got \(args.count)")
            } else {
                throw LoweringError.invalidExpression("\(name)() expects \(spec.minArgs)-\(spec.maxArgs) args, got \(args.count)")
            }
        }

        if spec.width != width {
            throw LoweringError.widthMismatch(expected: width, got: spec.width, context: "\(name)()")
        }

        switch name {
        case "camera":
            let u = try lowerExpr(args[0], subs: subs)
            let v = try lowerExpr(args[1], subs: subs)
            return expandChannels(spec.width, name: "camera", baseArgs: [u, v])

        case "microphone":
            let offset = try lowerExpr(args[0], subs: subs)
            return expandChannels(spec.width, name: "microphone", baseArgs: [offset])

        case "texture":
            guard case .string(let path) = args[0] else {
                throw LoweringError.invalidExpression("texture() first argument must be a string literal")
            }
            let resourceId = registerResource(path)
            let u = try lowerExpr(args[1], subs: subs)
            let v = try lowerExpr(args[2], subs: subs)
            return expandChannels(spec.width, name: "texture", baseArgs: [.num(Double(resourceId)), u, v])

        case "load":
            guard case .string(let path) = args[0] else {
                throw LoweringError.invalidExpression("load() first argument must be a string literal")
            }
            let resourceId = registerResource(path)
            let u: IRExpr
            let v: IRExpr
            if args.count >= 3 {
                u = try lowerExpr(args[1], subs: subs)
                v = try lowerExpr(args[2], subs: subs)
            } else {
                u = .index(bundle: "me", indexExpr: .param("x"))
                v = .index(bundle: "me", indexExpr: .param("y"))
            }
            return expandChannels(spec.width, name: "texture", baseArgs: [.num(Double(resourceId)), u, v])

        case "sample":
            guard case .string(let path) = args[0] else {
                throw LoweringError.invalidExpression("sample() first argument must be a string literal")
            }
            let resourceId = registerResource(path)
            let offset: IRExpr
            if args.count >= 2 {
                offset = try lowerExpr(args[1], subs: subs)
            } else {
                offset = .index(bundle: "me", indexExpr: .param("i"))
            }
            return expandChannels(spec.width, name: "sample", baseArgs: [.num(Double(resourceId)), offset])

        case "mouse":
            return expandChannels(spec.width, name: "mouse", baseArgs: [])

        case "text":
            guard case .string(let content) = args[0] else {
                throw LoweringError.invalidExpression("text() first argument must be a string literal")
            }
            let resourceId = registerTextResource(content)
            let x = try lowerExpr(args[1], subs: subs)
            let y = try lowerExpr(args[2], subs: subs)
            return [.builtin(name: "text", args: [.num(Double(resourceId)), x, y])]

        default:
            throw LoweringError.unknownSpindle(name)
        }
    }

    // MARK: - Helper Functions

    private func registerResource(_ path: String) -> Int {
        if let existing = resourceIndex[path] { return existing }
        let id = resources.count
        resources.append(path)
        resourceIndex[path] = id
        return id
    }

    private func registerTextResource(_ content: String) -> Int {
        if let existing = textResourceIndex[content] { return existing }
        let id = textResources.count
        textResources.append(content)
        textResourceIndex[content] = id
        return id
    }

    private func expandChannels(_ width: Int, name: String, baseArgs: [IRExpr]) -> [IRExpr] {
        (0..<width).map { channel in
            .builtin(name: name, args: baseArgs + [.num(Double(channel))])
        }
    }

    private func getBundleInfo(_ name: String) throws -> BundleInfo {
        if let scope = scope, let local = scope.locals[name] {
            return local
        }

        guard let info = bundleInfo[name] else {
            throw LoweringError.unknownBundle(name)
        }

        return info
    }

    private func inferWidth(_ expr: Expr) throws -> Int {
        switch expr {
        case .bundleLit(let elements):
            return try elements.reduce(0) { $0 + (try inferWidth($1)) }

        case .chainExpr(let chain):
            if chain.patterns.isEmpty {
                return try inferWidth(chain.base)
            }
            return try inferPatternWidth(chain.patterns.last!)

        case .identifier(let name):
            if name == "me" {
                return ME_STRANDS.count
            }
            if let scope = scope, scope.params.contains(name) {
                return 1
            }
            if let info = bundleInfo[name] {
                return info.width
            }
            if let scope = scope, let local = scope.locals[name] {
                return local.width
            }
            throw LoweringError.unknownIdentifier(name)

        case .spindleCall(let call):
            if let spec = RESOURCE_BUILTINS[call.name] {
                return spec.width
            }
            if let info = spindleInfo[call.name] {
                return info.width
            }
            if BUILTINS.contains(call.name) {
                return 1
            }
            throw LoweringError.unknownSpindle(call.name)

        case .callExtract:
            return 1

        case .tagExpr(let tag):
            return try inferWidth(tag.expr)

        case .remapExpr(let remap):
            return try inferWidth(remap.base)

        default:
            return 1
        }
    }

    private func inferPatternWidth(_ pattern: PatternBlock) throws -> Int {
        switch pattern.content {
        case .inline(let outputs):
            return outputs.count
        case .fullBody(let body):
            for stmt in body {
                switch stmt {
                case .returnList(let exprs):
                    return exprs.count
                case .returnAssign(let ret):
                    // Continue scanning to find max index
                    break
                case .bundleDecl:
                    break
                }
            }
            // Count from returnAssign indices
            var maxIndex = -1
            for stmt in body {
                if case .returnAssign(let ret) = stmt {
                    maxIndex = max(maxIndex, ret.index)
                }
            }
            if maxIndex >= 0 {
                return maxIndex + 1
            }
            throw LoweringError.invalidExpression("Full-body pattern block must have at least one return statement")
        }
    }

    private func buildSelector(_ exprs: [IRExpr], index: IRExpr) -> IRExpr {
        // Generate select(index, expr0, expr1, ...) builtin
        var args = [index]
        args.append(contentsOf: exprs)
        return .builtin(name: "select", args: args)
    }

    private func substituteInExpr(_ expr: IRExpr, substitutions: [String: IRExpr]) -> IRExpr {
        if case .index(let bundle, let indexExpr) = expr,
           case .num(let idx) = indexExpr,
           let sub = substitutions["\(bundle).\(Int(idx))"] {
            return sub
        }
        return expr.mapChildren { substituteInExpr($0, substitutions: substitutions) }
    }

    // MARK: - Range Handling

    private struct RangeInfo {
        let range: RangeExpr
        let inExprAccessor: Bool
        let bundleName: String?
    }

    private func findRanges(_ expr: Expr) -> [RangeInfo] {
        var ranges: [RangeInfo] = []

        func visit(_ node: Expr, inExprAccessor: Bool, bundleName: String?) {
            switch node {
            case .rangeExpr(let range):
                ranges.append(RangeInfo(range: range, inExprAccessor: inExprAccessor, bundleName: bundleName))

            case .strandAccess(let access):
                if case .expr(let inner) = access.accessor {
                    let name: String?
                    if case .named(let n) = access.bundle {
                        name = n
                    } else {
                        name = nil
                    }
                    visit(inner, inExprAccessor: true, bundleName: name)
                }
                if case .bundleLit(let elements) = access.bundle {
                    for el in elements {
                        visit(el, inExprAccessor: false, bundleName: nil)
                    }
                }

            case .binaryOp(let op):
                visit(op.left, inExprAccessor: false, bundleName: nil)
                visit(op.right, inExprAccessor: false, bundleName: nil)

            case .unaryOp(let op):
                visit(op.operand, inExprAccessor: false, bundleName: nil)

            case .spindleCall(let call):
                for arg in call.args {
                    visit(arg, inExprAccessor: false, bundleName: nil)
                }

            case .callExtract(let extract):
                visit(extract.call, inExprAccessor: false, bundleName: nil)

            case .remapExpr(let remap):
                visit(remap.base, inExprAccessor: false, bundleName: nil)
                for r in remap.remappings {
                    visit(r.expr, inExprAccessor: false, bundleName: nil)
                }

            case .bundleLit(let elements):
                for el in elements {
                    visit(el, inExprAccessor: false, bundleName: nil)
                }

            case .chainExpr(let chain):
                visit(chain.base, inExprAccessor: false, bundleName: nil)
                // Don't descend into pattern blocks - they have their own context

            case .tagExpr(let tag):
                visit(tag.expr, inExprAccessor: false, bundleName: nil)

            default:
                break
            }
        }

        visit(expr, inExprAccessor: false, bundleName: nil)
        return ranges
    }

    private func computeRangeSize(_ info: RangeInfo, defaultWidth: Int) -> Int {
        let range = info.range

        var width = defaultWidth
        if info.inExprAccessor, let bundleName = info.bundleName {
            if let bundleWidth = bundleInfo[bundleName]?.width {
                width = bundleWidth
            }
        }

        var start = range.start ?? 0
        var end = range.end ?? width

        if start < 0 { start = width + start }
        if end < 0 { end = width + end }

        return end - start
    }

    private func expandRangeExpr(_ expr: Expr, iterNum: Int, defaultWidth: Int) -> Expr {
        func computeIndex(_ range: RangeExpr, bundleName: String?) -> Int {
            var width = defaultWidth
            if let bundleName = bundleName, let info = bundleInfo[bundleName] {
                width = info.width
            }

            var start = range.start ?? 0
            if start < 0 { start = width + start }

            return start + iterNum
        }

        func substitute(_ node: Expr, bundleContext: String?) -> Expr {
            switch node {
            case .rangeExpr(let range):
                // Standalone range - replace with bare strand accessor
                let idx = computeIndex(range, bundleName: bundleContext)
                return .strandAccess(StrandAccess(bundle: nil, accessor: .index(idx)))

            case .strandAccess(let access):
                if case .expr(let inner) = access.accessor {
                    if case .rangeExpr(let range) = inner {
                        let bundleName: String?
                        if case .named(let n) = access.bundle {
                            bundleName = n
                        } else {
                            bundleName = nil
                        }
                        let idx = computeIndex(range, bundleName: bundleName)
                        return .strandAccess(StrandAccess(bundle: access.bundle, accessor: .index(idx)))
                    }
                    let newInner = substitute(inner, bundleContext: nil)
                    if case .expr = access.accessor {
                        return .strandAccess(StrandAccess(bundle: access.bundle, accessor: .expr(newInner)))
                    }
                }
                if case .bundleLit(let elements) = access.bundle {
                    let newElements = elements.map { substitute($0, bundleContext: nil) }
                    return .strandAccess(StrandAccess(bundle: .bundleLit(newElements), accessor: access.accessor))
                }
                return node

            case .binaryOp(let op):
                let newLeft = substitute(op.left, bundleContext: nil)
                let newRight = substitute(op.right, bundleContext: nil)
                return .binaryOp(BinaryOp(left: newLeft, op: op.op, right: newRight))

            case .unaryOp(let op):
                let newOperand = substitute(op.operand, bundleContext: nil)
                return .unaryOp(UnaryOp(op: op.op, operand: newOperand))

            case .spindleCall(let call):
                let newArgs = call.args.map { substitute($0, bundleContext: nil) }
                return .spindleCall(SpindleCall(name: call.name, args: newArgs))

            case .callExtract(let extract):
                let newCall = substitute(extract.call, bundleContext: nil)
                return .callExtract(CallExtract(call: newCall, index: extract.index))

            case .remapExpr(let remap):
                let newBase = substitute(remap.base, bundleContext: nil)
                let newRemappings = remap.remappings.map { r in
                    RemapArg(domain: r.domain, expr: substitute(r.expr, bundleContext: nil))
                }
                return .remapExpr(RemapExpr(base: newBase, remappings: newRemappings))

            case .bundleLit(let elements):
                let newElements = elements.map { substitute($0, bundleContext: nil) }
                return .bundleLit(newElements)

            case .chainExpr(let chain):
                let newBase = substitute(chain.base, bundleContext: nil)
                return .chainExpr(ChainExpr(base: newBase, patterns: chain.patterns))

            case .tagExpr(let tag):
                return .tagExpr(TagExpr(name: tag.name, expr: substitute(tag.expr, bundleContext: nil)))

            default:
                return node
            }
        }

        return substitute(expr, bundleContext: nil)
    }

    // MARK: - Topological Sort

    private func topologicalSort() throws -> [IRProgram.OrderEntry] {
        var strandToDecl: [String: Int] = [:]
        var bundleToDecls: [String: [Int]] = [:]

        for (i, decl) in declarations.enumerated() {
            for name in decl.strandNames {
                strandToDecl["\(decl.bundle).\(name)"] = i
            }
            bundleToDecls[decl.bundle, default: []].append(i)
        }

        var visited = Set<Int>()
        var visiting = Set<Int>()
        var order: [IRProgram.OrderEntry] = []

        func visit(_ i: Int) throws {
            if visited.contains(i) { return }
            if visiting.contains(i) {
                let decl = declarations[i]
                throw LoweringError.circularDependency(decl.bundle)
            }

            visiting.insert(i)

            for strand in declarations[i].strands {
                for ref in strand.expr.currentTickFreeVars() {
                    if ref.contains(".") {
                        if let dep = strandToDecl[ref], dep != i {
                            try visit(dep)
                        }
                    } else {
                        for dep in bundleToDecls[ref] ?? [] {
                            if dep != i {
                                try visit(dep)
                            }
                        }
                    }
                }
            }

            visiting.remove(i)
            visited.insert(i)

            let decl = declarations[i]
            order.append(IRProgram.OrderEntry(bundle: decl.bundle, strands: Array(decl.strandNames)))
        }

        for i in 0..<declarations.count {
            try visit(i)
        }

        return order
    }
}

// MARK: - BundleInfo Extension

extension WeftLowering.BundleInfo {
    init(width: Int, strandIndex: [String: Int]) {
        self.width = width
        self.strandIndex = strandIndex
    }
}
