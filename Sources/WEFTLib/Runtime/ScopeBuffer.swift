// ScopeBuffer.swift - Thread-safe ring buffer for oscilloscope data

import Foundation

/// Thread-safe ring buffer for oscilloscope data.
/// Written from audio render callback, read from UI thread.
///
/// Uses a double-buffer approach: the audio thread writes into the live buffer,
/// and periodically publishes a snapshot that the UI reads lock-free.
public class ScopeBuffer {
    public let strandNames: [String]
    public let strandCount: Int
    public let capacity: Int

    // Live ring buffer (written by audio thread under lock)
    private var buffers: [[Float]]  // [strandIndex][sampleIndex]
    private var writeIndex: Int = 0
    private var samplesWritten: Int = 0
    private let lock = NSLock()

    // Published snapshot (swapped atomically for UI reads)
    private var publishedSnapshot: [[Float]]
    private let snapshotLock = NSLock()

    // Publish at ~60fps from 44100Hz audio: every ~735 samples
    private let publishInterval: Int = 735

    public init(strandNames: [String], capacity: Int = 8192) {
        self.strandNames = strandNames
        self.strandCount = strandNames.count
        self.capacity = capacity
        self.buffers = (0..<strandNames.count).map { _ in
            [Float](repeating: 0, count: capacity)
        }
        self.publishedSnapshot = (0..<strandNames.count).map { _ in
            [Float](repeating: 0, count: capacity)
        }
    }

    /// Write one or more frames of scope data.
    /// Each inner array has one value per strand.
    /// Called from audio render callback.
    public func write(values: [[Float]]) {
        lock.lock()

        for frame in values {
            for (strandIdx, value) in frame.prefix(strandCount).enumerated() {
                buffers[strandIdx][writeIndex] = value
            }
            writeIndex = (writeIndex + 1) % capacity
            samplesWritten += 1
        }

        // Periodically publish a snapshot for the UI
        if samplesWritten >= publishInterval {
            samplesWritten = 0
            let snap = captureSnapshotLocked()
            lock.unlock()

            snapshotLock.lock()
            publishedSnapshot = snap
            snapshotLock.unlock()
        } else {
            lock.unlock()
        }
    }

    /// Capture a snapshot while already holding the write lock.
    private func captureSnapshotLocked() -> [[Float]] {
        var result: [[Float]] = []
        for strandIdx in 0..<strandCount {
            var samples = [Float](repeating: 0, count: capacity)
            // Linearize ring buffer: oldest sample first
            let start = writeIndex
            for i in 0..<capacity {
                samples[i] = buffers[strandIdx][(start + i) % capacity]
            }
            result.append(samples)
        }
        return result
    }

    /// Get the most recently published snapshot for display.
    /// Returns [[Float]] -- one array per strand, oldest-first, full capacity length.
    /// Called from UI thread. Lock-free against audio writes (only contends briefly
    /// with the periodic publish).
    public func snapshot(count: Int) -> [[Float]] {
        snapshotLock.lock()
        let snap = publishedSnapshot
        snapshotLock.unlock()

        if count >= capacity {
            return snap
        }
        // Return the last `count` samples from each strand
        return snap.map { Array($0.suffix(count)) }
    }
}
