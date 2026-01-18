// CacheManager.swift - Signal-driven history buffers for feedback effects

import Foundation
import Metal

// MARK: - Cache Entry

/// A single cache entry tracking history for one coordinate
public struct CacheEntry {
    public var historySize: Int
    public var tapIndex: Int
    public var history: [Float]
    public var previousSignal: Float?

    public init(historySize: Int, tapIndex: Int) {
        self.historySize = historySize
        self.tapIndex = tapIndex
        self.history = [Float](repeating: 0, count: historySize)
        self.previousSignal = nil
    }

    /// Tick: shift history and store new value if signal changed
    public mutating func tick(value: Float, signal: Float) -> Float {
        // Check if signal changed
        let shouldTick = previousSignal == nil || previousSignal != signal
        previousSignal = signal

        if shouldTick {
            // Shift history
            for i in stride(from: historySize - 1, through: 1, by: -1) {
                history[i] = history[i - 1]
            }
            // Store new value
            history[0] = value
        }

        // Return tapped value
        let clampedIndex = min(max(tapIndex, 0), historySize - 1)
        return history[clampedIndex]
    }
}

// MARK: - Cache Node Info

/// Information about a cache node in the IR
public struct CacheNodeInfo {
    public var bundleName: String
    public var strandIndex: Int
    public var historySize: Int
    public var tapIndex: Int
    public var signalExpr: IRExpr

    public var key: String {
        "\(bundleName).\(strandIndex)"
    }
}

// MARK: - Cache Manager

public class CacheManager {
    /// Cache entries keyed by "bundleName.strandIndex"
    private var entries: [String: CacheEntry] = [:]

    /// Cache node info extracted from IR
    private var nodeInfo: [CacheNodeInfo] = []

    public init() {}

    /// Analyze IR to find all cache nodes
    public func analyze(program: IRProgram) {
        entries = [:]
        nodeInfo = []

        for (bundleName, bundle) in program.bundles {
            for strand in bundle.strands {
                findCacheNodes(
                    expr: strand.expr,
                    bundleName: bundleName,
                    strandIndex: strand.index,
                    program: program
                )
            }
        }

        // Initialize entries for each cache node
        for info in nodeInfo {
            entries[info.key] = CacheEntry(
                historySize: info.historySize,
                tapIndex: info.tapIndex
            )
        }

        print("CacheManager: found \(nodeInfo.count) cache nodes")
    }

    /// Find cache builtin calls in an expression
    private func findCacheNodes(
        expr: IRExpr,
        bundleName: String,
        strandIndex: Int,
        program: IRProgram
    ) {
        switch expr {
        case .builtin(let name, let args) where name == "cache":
            // cache(value, history_size, tap_index, signal)
            if args.count >= 4 {
                let historySize: Int
                let tapIndex: Int

                if case .num(let h) = args[1] {
                    historySize = Int(h)
                } else {
                    historySize = 1
                }

                if case .num(let t) = args[2] {
                    tapIndex = Int(t)
                } else {
                    tapIndex = 0
                }

                let info = CacheNodeInfo(
                    bundleName: bundleName,
                    strandIndex: strandIndex,
                    historySize: historySize,
                    tapIndex: tapIndex,
                    signalExpr: args[3]
                )
                nodeInfo.append(info)
            }
            // Also check args recursively
            for arg in args {
                findCacheNodes(expr: arg, bundleName: bundleName, strandIndex: strandIndex, program: program)
            }

        case .binaryOp(_, let left, let right):
            findCacheNodes(expr: left, bundleName: bundleName, strandIndex: strandIndex, program: program)
            findCacheNodes(expr: right, bundleName: bundleName, strandIndex: strandIndex, program: program)

        case .unaryOp(_, let operand):
            findCacheNodes(expr: operand, bundleName: bundleName, strandIndex: strandIndex, program: program)

        case .builtin(_, let args):
            for arg in args {
                findCacheNodes(expr: arg, bundleName: bundleName, strandIndex: strandIndex, program: program)
            }

        case .call(_, let args):
            for arg in args {
                findCacheNodes(expr: arg, bundleName: bundleName, strandIndex: strandIndex, program: program)
            }

        case .extract(let call, _):
            findCacheNodes(expr: call, bundleName: bundleName, strandIndex: strandIndex, program: program)

        case .remap(let base, let subs):
            findCacheNodes(expr: base, bundleName: bundleName, strandIndex: strandIndex, program: program)
            for (_, subExpr) in subs {
                findCacheNodes(expr: subExpr, bundleName: bundleName, strandIndex: strandIndex, program: program)
            }

        case .index(_, let indexExpr):
            findCacheNodes(expr: indexExpr, bundleName: bundleName, strandIndex: strandIndex, program: program)

        default:
            break
        }
    }

    /// Tick a cache entry
    public func tick(key: String, value: Float, signal: Float) -> Float {
        guard var entry = entries[key] else { return value }
        let result = entry.tick(value: value, signal: signal)
        entries[key] = entry
        return result
    }

    /// Get cache entries
    public func getEntries() -> [String: CacheEntry] {
        return entries
    }

    /// Get cache node info
    public func getNodeInfo() -> [CacheNodeInfo] {
        return nodeInfo
    }
}
