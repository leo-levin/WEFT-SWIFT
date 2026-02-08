// ScopeBuffer.swift - Thread-safe ring buffer for oscilloscope data

import Foundation

/// Thread-safe ring buffer for oscilloscope data.
/// Written from audio render callback, read from UI thread.
public class ScopeBuffer {
    public let strandNames: [String]
    public let strandCount: Int
    public let capacity: Int

    private var buffers: [[Float]]  // [strandIndex][sampleIndex]
    private var writeIndex: Int = 0
    private var samplesWritten: Int = 0
    private let lock = NSLock()

    public init(strandNames: [String], capacity: Int = 8192) {
        self.strandNames = strandNames
        self.strandCount = strandNames.count
        self.capacity = capacity
        self.buffers = (0..<strandNames.count).map { _ in
            [Float](repeating: 0, count: capacity)
        }
    }

    /// Write one or more frames of scope data.
    /// Each inner array has one value per strand.
    /// Called from audio render callback.
    public func write(values: [[Float]]) {
        lock.lock()
        defer { lock.unlock() }

        for frame in values {
            for (strandIdx, value) in frame.prefix(strandCount).enumerated() {
                buffers[strandIdx][writeIndex] = value
            }
            writeIndex = (writeIndex + 1) % capacity
            samplesWritten += 1
        }
    }

    /// Get a snapshot of recent samples for display.
    /// Returns [[Float]] -- one array per strand, oldest-first.
    /// Called from UI thread.
    public func snapshot(count: Int) -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }

        let n = min(count, capacity)
        var result: [[Float]] = []

        for strandIdx in 0..<strandCount {
            var samples = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let readIdx = (writeIndex - n + i + capacity) % capacity
                samples[i] = buffers[strandIdx][readIdx]
            }
            result.append(samples)
        }

        return result
    }
}
