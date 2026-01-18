// CacheManager.swift - Signal-driven history buffers for feedback effects
//
// Unified memory architecture: CacheManager owns ALL cache buffers.
// Both Metal and Audio backends access the same physical memory.

import Foundation
import Metal

// MARK: - Cache Node Descriptor

/// Complete description of a cache node for codegen
public struct CacheNodeDescriptor {
    /// Unique identifier for this cache node
    public let id: String

    /// Bundle containing this cache
    public let bundleName: String

    /// Strand index within the bundle
    public let strandIndex: Int

    /// Number of history slots
    public let historySize: Int

    /// Which history slot to read (0 = most recent)
    public let tapIndex: Int

    /// The value expression to cache
    public let valueExpr: IRExpr

    /// The signal expression for edge detection
    public let signalExpr: IRExpr

    /// Backend domain (visual or audio)
    public let domain: CacheDomain

    /// Buffer index for history data (CacheManager internal)
    public let historyBufferIndex: Int

    /// Buffer index for previous signal tracking (CacheManager internal)
    public let signalBufferIndex: Int

    // MARK: - Shader Buffer Index Calculation

    /// Base buffer index for cache buffers in shader (after uniforms at index 0)
    public static let shaderBufferStartIndex: Int = 1

    /// Calculate shader buffer index for history buffer given cache array position
    public static func shaderHistoryBufferIndex(cachePosition: Int) -> Int {
        return shaderBufferStartIndex + cachePosition * 2
    }

    /// Calculate shader buffer index for signal buffer given cache array position
    public static func shaderSignalBufferIndex(cachePosition: Int) -> Int {
        return shaderBufferStartIndex + cachePosition * 2 + 1
    }
}

/// Cache domain determines buffer layout
public enum CacheDomain {
    case visual  // Per-pixel history: width × height × history_size
    case audio   // Shared delay line: history_size (circular buffer)
}

// MARK: - Cache Buffer

/// Unified memory buffer accessible by both CPU and GPU
public class CacheBuffer {
    public let name: String
    public let mtlBuffer: MTLBuffer
    public let elementCount: Int

    /// Direct pointer access for CPU (audio backend)
    public var floatPointer: UnsafeMutablePointer<Float> {
        mtlBuffer.contents().assumingMemoryBound(to: Float.self)
    }

    public init(name: String, mtlBuffer: MTLBuffer, elementCount: Int) {
        self.name = name
        self.mtlBuffer = mtlBuffer
        self.elementCount = elementCount
    }
}

// MARK: - Cache Manager

public class CacheManager {
    /// Metal device for buffer allocation
    private var device: MTLDevice?

    /// Output dimensions (for visual caches)
    private var width: Int = 512
    private var height: Int = 512

    /// Cache node descriptors (analyzed from IR)
    private var descriptors: [CacheNodeDescriptor] = []

    /// Allocated buffers indexed by buffer index
    private var buffers: [Int: CacheBuffer] = [:]

    /// Next available buffer index
    private var nextBufferIndex: Int = 0

    public init() {}

    // MARK: - Analysis

    /// Analyze IR to find all cache nodes and create descriptors
    public func analyze(program: IRProgram, ownership: OwnershipAnalysis? = nil) {
        descriptors = []
        nextBufferIndex = 0

        for (bundleName, bundle) in program.bundles {
            for strand in bundle.strands {
                findCacheNodes(
                    expr: strand.expr,
                    bundleName: bundleName,
                    strandIndex: strand.index,
                    program: program,
                    ownership: ownership
                )
            }
        }

        print("CacheManager: found \(descriptors.count) cache nodes")
        for desc in descriptors {
            print("  - \(desc.id): \(desc.domain), historySize=\(desc.historySize), tap=\(desc.tapIndex)")
        }
    }

    /// Find cache builtin calls in an expression
    private func findCacheNodes(
        expr: IRExpr,
        bundleName: String,
        strandIndex: Int,
        program: IRProgram,
        ownership: OwnershipAnalysis?
    ) {
        switch expr {
        case .builtin(let name, let args) where name == "cache":
            // cache(value, history_size, tap_index, signal)
            if args.count >= 4 {
                let historySize: Int
                let tapIndex: Int

                if case .num(let h) = args[1] {
                    historySize = max(1, Int(h))
                } else {
                    historySize = 1
                }

                if case .num(let t) = args[2] {
                    tapIndex = Int(t)
                } else {
                    tapIndex = 0
                }

                // Determine domain from bundle ownership
                let domain: CacheDomain
                if let ownership = ownership {
                    let bundleOwner = ownership.ownership[bundleName] ?? .none
                    domain = (bundleOwner == .audio) ? .audio : .visual
                } else {
                    // Default heuristic: "play" bundle is audio, else visual
                    domain = (bundleName == "play") ? .audio : .visual
                }

                // Allocate buffer indices
                let historyBufferIndex = nextBufferIndex
                nextBufferIndex += 1
                let signalBufferIndex = nextBufferIndex
                nextBufferIndex += 1

                let id = "\(bundleName).\(strandIndex).\(descriptors.count)"

                let descriptor = CacheNodeDescriptor(
                    id: id,
                    bundleName: bundleName,
                    strandIndex: strandIndex,
                    historySize: historySize,
                    tapIndex: tapIndex,
                    valueExpr: args[0],
                    signalExpr: args[3],
                    domain: domain,
                    historyBufferIndex: historyBufferIndex,
                    signalBufferIndex: signalBufferIndex
                )
                descriptors.append(descriptor)
            }
            // Also check args recursively for nested caches
            for arg in args {
                findCacheNodes(expr: arg, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)
            }

        case .binaryOp(_, let left, let right):
            findCacheNodes(expr: left, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)
            findCacheNodes(expr: right, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)

        case .unaryOp(_, let operand):
            findCacheNodes(expr: operand, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)

        case .builtin(_, let args):
            for arg in args {
                findCacheNodes(expr: arg, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)
            }

        case .call(_, let args):
            for arg in args {
                findCacheNodes(expr: arg, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)
            }

        case .extract(let call, _):
            findCacheNodes(expr: call, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)

        case .remap(let base, let subs):
            findCacheNodes(expr: base, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)
            for (_, subExpr) in subs {
                findCacheNodes(expr: subExpr, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)
            }

        case .index(_, let indexExpr):
            findCacheNodes(expr: indexExpr, bundleName: bundleName, strandIndex: strandIndex, program: program, ownership: ownership)

        default:
            break
        }
    }

    // MARK: - Cycle Breaking Transformation

    /// Transform the program to break cache cycles
    /// This replaces back-references to cache locations with cacheRead expressions
    public func transformProgramForCaches(program: inout IRProgram) {
        // Build map of cache locations: "bundleName.strandIndex" or "bundleName.strandName" -> (cacheId, tapIndex)
        var cacheLocations: [String: (cacheId: String, tapIndex: Int)] = [:]

        for descriptor in descriptors {
            // A strand whose expression IS a cache builtin - the strand itself is the cache
            // We need to identify if the strand expression is directly a cache
            if let bundle = program.bundles[descriptor.bundleName] {
                for strand in bundle.strands where strand.index == descriptor.strandIndex {
                    // Check if this strand's expression is a cache
                    if case .builtin(let name, _) = strand.expr, name == "cache" {
                        // Map both by index and by name
                        cacheLocations["\(descriptor.bundleName).\(strand.index)"] = (descriptor.id, descriptor.tapIndex)
                        cacheLocations["\(descriptor.bundleName).\(strand.name)"] = (descriptor.id, descriptor.tapIndex)
                    }
                }
            }
        }

        guard !cacheLocations.isEmpty else { return }

        print("CacheManager: breaking cycles for cache locations: \(cacheLocations.keys.sorted())")

        // Transform each bundle's strand expressions
        for (bundleName, bundle) in program.bundles {
            var modifiedStrands = bundle.strands
            for i in 0..<modifiedStrands.count {
                modifiedStrands[i].expr = breakCacheCycles(
                    in: modifiedStrands[i].expr,
                    cacheLocations: cacheLocations,
                    program: program,
                    visited: []
                )
            }
            program.bundles[bundleName] = IRBundle(name: bundleName, strands: modifiedStrands)
        }

        // Also update the descriptors' valueExpr to use transformed expressions
        for i in 0..<descriptors.count {
            let transformedValueExpr = breakCacheCycles(
                in: descriptors[i].valueExpr,
                cacheLocations: cacheLocations,
                program: program,
                visited: []
            )
            // Recreate descriptor with transformed valueExpr
            descriptors[i] = CacheNodeDescriptor(
                id: descriptors[i].id,
                bundleName: descriptors[i].bundleName,
                strandIndex: descriptors[i].strandIndex,
                historySize: descriptors[i].historySize,
                tapIndex: descriptors[i].tapIndex,
                valueExpr: transformedValueExpr,
                signalExpr: descriptors[i].signalExpr,
                domain: descriptors[i].domain,
                historyBufferIndex: descriptors[i].historyBufferIndex,
                signalBufferIndex: descriptors[i].signalBufferIndex
            )
        }
    }

    /// Recursively transform expression to replace cache back-references with cacheRead
    private func breakCacheCycles(
        in expr: IRExpr,
        cacheLocations: [String: (cacheId: String, tapIndex: Int)],
        program: IRProgram,
        visited: Set<String>
    ) -> IRExpr {
        switch expr {
        case .index(let bundle, let indexExpr):
            // Check if this is a reference to a cache location
            let key: String
            if case .param(let field) = indexExpr {
                key = "\(bundle).\(field)"
            } else if case .num(let idx) = indexExpr {
                key = "\(bundle).\(Int(idx))"
            } else {
                // Dynamic index - transform the index expression and return
                let transformedIndex = breakCacheCycles(in: indexExpr, cacheLocations: cacheLocations, program: program, visited: visited)
                return .index(bundle: bundle, indexExpr: transformedIndex)
            }

            // If this reference is to a cache location, replace with cacheRead
            if let cacheInfo = cacheLocations[key] {
                return .cacheRead(cacheId: cacheInfo.cacheId, tapIndex: cacheInfo.tapIndex)
            }

            // Otherwise, continue with the original expression
            return expr

        case .binaryOp(let op, let left, let right):
            return .binaryOp(
                op: op,
                left: breakCacheCycles(in: left, cacheLocations: cacheLocations, program: program, visited: visited),
                right: breakCacheCycles(in: right, cacheLocations: cacheLocations, program: program, visited: visited)
            )

        case .unaryOp(let op, let operand):
            return .unaryOp(
                op: op,
                operand: breakCacheCycles(in: operand, cacheLocations: cacheLocations, program: program, visited: visited)
            )

        case .builtin(let name, let args):
            let transformedArgs = args.map { breakCacheCycles(in: $0, cacheLocations: cacheLocations, program: program, visited: visited) }
            return .builtin(name: name, args: transformedArgs)

        case .call(let spindle, let args):
            let transformedArgs = args.map { breakCacheCycles(in: $0, cacheLocations: cacheLocations, program: program, visited: visited) }
            return .call(spindle: spindle, args: transformedArgs)

        case .extract(let callExpr, let index):
            return .extract(
                call: breakCacheCycles(in: callExpr, cacheLocations: cacheLocations, program: program, visited: visited),
                index: index
            )

        case .remap(let base, let substitutions):
            let transformedBase = breakCacheCycles(in: base, cacheLocations: cacheLocations, program: program, visited: visited)
            var transformedSubs: [String: IRExpr] = [:]
            for (key, subExpr) in substitutions {
                transformedSubs[key] = breakCacheCycles(in: subExpr, cacheLocations: cacheLocations, program: program, visited: visited)
            }
            return .remap(base: transformedBase, substitutions: transformedSubs)

        default:
            // num, param, cacheRead - no transformation needed
            return expr
        }
    }

    // MARK: - Buffer Allocation

    /// Allocate unified memory buffers for all cache nodes
    public func allocateBuffers(device: MTLDevice, width: Int, height: Int) {
        self.device = device
        self.width = width
        self.height = height

        // Clear existing buffers
        buffers = [:]

        for descriptor in descriptors {
            allocateBuffersForDescriptor(descriptor)
        }

        print("CacheManager: allocated \(buffers.count) buffers")
    }

    /// Allocate buffers for a single cache descriptor
    private func allocateBuffersForDescriptor(_ descriptor: CacheNodeDescriptor) {
        guard let device = device else {
            print("CacheManager: No Metal device available")
            return
        }

        let historyCount: Int
        let signalCount: Int

        switch descriptor.domain {
        case .visual:
            // Per-pixel: width × height × history_size
            historyCount = width * height * descriptor.historySize
            signalCount = width * height

        case .audio:
            // Shared delay line: history_size + 1 (extra element stores write index)
            historyCount = descriptor.historySize + 1
            signalCount = 1
        }

        // Allocate history buffer
        let historyByteSize = historyCount * MemoryLayout<Float>.stride
        if let historyMTL = device.makeBuffer(length: historyByteSize, options: .storageModeShared) {
            // Zero-initialize
            memset(historyMTL.contents(), 0, historyByteSize)
            let historyBuffer = CacheBuffer(
                name: "\(descriptor.id).history",
                mtlBuffer: historyMTL,
                elementCount: historyCount
            )
            buffers[descriptor.historyBufferIndex] = historyBuffer
        }

        // Allocate signal buffer
        let signalByteSize = signalCount * MemoryLayout<Float>.stride
        if let signalMTL = device.makeBuffer(length: signalByteSize, options: .storageModeShared) {
            // Initialize to NaN so first comparison always triggers tick
            let ptr = signalMTL.contents().assumingMemoryBound(to: Float.self)
            for i in 0..<signalCount {
                ptr[i] = Float.nan
            }
            let signalBuffer = CacheBuffer(
                name: "\(descriptor.id).signal",
                mtlBuffer: signalMTL,
                elementCount: signalCount
            )
            buffers[descriptor.signalBufferIndex] = signalBuffer
        }
    }

    /// Reallocate buffers when dimensions change
    public func resizeBuffers(width: Int, height: Int) {
        guard let device = device, (width != self.width || height != self.height) else { return }
        allocateBuffers(device: device, width: width, height: height)
    }

    // MARK: - Buffer Access

    /// Get all cache descriptors
    public func getDescriptors() -> [CacheNodeDescriptor] {
        return descriptors
    }

    /// Get descriptors for a specific domain
    public func getDescriptors(for domain: CacheDomain) -> [CacheNodeDescriptor] {
        return descriptors.filter { $0.domain == domain }
    }

    /// Get buffer by index
    public func getBuffer(index: Int) -> CacheBuffer? {
        return buffers[index]
    }

    /// Get all buffers as a dictionary
    public func getAllBuffers() -> [Int: CacheBuffer] {
        return buffers
    }

    /// Get current dimensions
    public func getDimensions() -> (width: Int, height: Int) {
        return (width, height)
    }

    // MARK: - Audio Cache Operations (called from AudioCodeGen closures)

    /// Tick audio cache: store value if signal changed
    /// Returns the tapped value
    ///
    /// Thread safety: This method is called from the audio render callback, which
    /// runs on a single real-time thread. The method is safe for single-threaded
    /// access. Do not call `allocateBuffers()` while audio playback is active.
    ///
    /// The write index is stored at historyBuffer[historySize] (one extra element)
    /// to avoid dictionary access in the hot path.
    public func tickAudioCache(
        descriptor: CacheNodeDescriptor,
        value: Float,
        signal: Float
    ) -> Float {
        guard let historyBuffer = buffers[descriptor.historyBufferIndex],
              let signalBuffer = buffers[descriptor.signalBufferIndex] else {
            return value
        }

        let historyPtr = historyBuffer.floatPointer
        let signalPtr = signalBuffer.floatPointer

        let prevSignal = signalPtr[0]
        let shouldTick = prevSignal.isNaN || prevSignal != signal

        // Write index stored at end of history buffer (avoids dictionary in hot path)
        let writeIdxPtr = historyPtr.advanced(by: descriptor.historySize)
        var writeIdx = Int(writeIdxPtr.pointee)

        if shouldTick {
            signalPtr[0] = signal

            // Circular buffer: store at write position, advance index
            historyPtr[writeIdx] = value
            writeIdx = (writeIdx + 1) % descriptor.historySize
            writeIdxPtr.pointee = Float(writeIdx)
        }

        // Read from tap position (relative to current write position)
        let readIdx = (writeIdx - 1 - descriptor.tapIndex + descriptor.historySize * 2) % descriptor.historySize
        return historyPtr[readIdx]
    }

    /// Read from audio cache without ticking (for cacheRead expressions)
    /// Returns the value at the specified tap index
    public func readAudioCache(descriptor: CacheNodeDescriptor, tapIndex: Int) -> Float {
        guard let historyBuffer = buffers[descriptor.historyBufferIndex] else {
            return 0.0
        }

        let historyPtr = historyBuffer.floatPointer

        // Write index stored at end of history buffer
        let writeIdx = Int(historyPtr.advanced(by: descriptor.historySize).pointee)

        // Read from tap position (relative to current write position)
        let clampedTap = min(tapIndex, descriptor.historySize - 1)
        let readIdx = (writeIdx - 1 - clampedTap + descriptor.historySize * 2) % descriptor.historySize
        return historyPtr[readIdx]
    }
}
