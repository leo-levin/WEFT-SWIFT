import XCTest
@testable import WEFTLib

final class ScopeBufferTests: XCTestCase {
    func testWriteAndReadSamples() {
        let buffer = ScopeBuffer(strandNames: ["a", "b"], capacity: 8)
        XCTAssertEqual(buffer.strandNames, ["a", "b"])
        XCTAssertEqual(buffer.strandCount, 2)

        // Write enough frames to trigger a publish (publishInterval = 735,
        // but for small capacity buffers it wraps; just verify we can read back data)
        var frames: [[Float]] = []
        for i in 0..<800 {
            frames.append([Float(i), Float(i) * 2])
        }
        buffer.write(values: frames)

        // Read back -- should get data
        let snapshot = buffer.snapshot(count: 4)
        XCTAssertEqual(snapshot.count, 2) // 2 strands
        XCTAssertEqual(snapshot[0].count, 4) // requested count
        XCTAssertFalse(snapshot[1].isEmpty)
    }

    func testRingBufferWraps() {
        let buffer = ScopeBuffer(strandNames: ["x"], capacity: 4)
        // Write enough to wrap and trigger publish
        var frames: [[Float]] = []
        for i in 0..<800 {
            frames.append([Float(i)])
        }
        buffer.write(values: frames)

        let snapshot = buffer.snapshot(count: 4)
        XCTAssertEqual(snapshot[0].count, 4)
        // Values should be from the most recent writes
        // (exact values depend on publish timing, but they shouldn't all be zero)
        let hasNonZero = snapshot[0].contains { $0 != 0 }
        XCTAssertTrue(hasNonZero)
    }

    func testSnapshotCountClampedToCapacity() {
        let buffer = ScopeBuffer(strandNames: ["x"], capacity: 4)
        var frames: [[Float]] = []
        for _ in 0..<800 {
            frames.append([1.0])
        }
        buffer.write(values: frames)

        // Request more than capacity
        let snapshot = buffer.snapshot(count: 10)
        XCTAssertEqual(snapshot[0].count, 4) // clamped to capacity
    }

    func testSnapshotBeforePublishReturnsZeros() {
        let buffer = ScopeBuffer(strandNames: ["x"], capacity: 8)
        // Write fewer samples than publishInterval -- no publish yet
        buffer.write(values: [[1.0], [2.0]])

        let snapshot = buffer.snapshot(count: 4)
        // Should return zeros (initial published snapshot)
        XCTAssertEqual(snapshot[0], [0, 0, 0, 0])
    }
}
