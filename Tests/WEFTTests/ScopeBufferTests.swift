import XCTest
@testable import WEFTLib

final class ScopeBufferTests: XCTestCase {
    func testWriteAndReadSamples() {
        let buffer = ScopeBuffer(strandNames: ["a", "b"], capacity: 8)
        XCTAssertEqual(buffer.strandNames, ["a", "b"])
        XCTAssertEqual(buffer.strandCount, 2)

        // Write 4 frames of data
        buffer.write(values: [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [7.0, 8.0]])

        // Read back -- should get the data we wrote
        let snapshot = buffer.snapshot(count: 4)
        XCTAssertEqual(snapshot.count, 2) // 2 strands
        XCTAssertEqual(snapshot[0], [1.0, 3.0, 5.0, 7.0]) // strand "a" history (oldest first)
        XCTAssertEqual(snapshot[1], [2.0, 4.0, 6.0, 8.0]) // strand "b"
    }

    func testRingBufferWraps() {
        let buffer = ScopeBuffer(strandNames: ["x"], capacity: 4)
        // Write 6 frames (wraps around capacity of 4)
        buffer.write(values: [[1.0], [2.0], [3.0], [4.0], [5.0], [6.0]])

        let snapshot = buffer.snapshot(count: 4)
        // Should contain last 4 values
        XCTAssertEqual(snapshot[0], [3.0, 4.0, 5.0, 6.0])
    }

    func testSnapshotCountClampedToCapacity() {
        let buffer = ScopeBuffer(strandNames: ["x"], capacity: 4)
        buffer.write(values: [[1.0], [2.0]])

        // Request more than capacity
        let snapshot = buffer.snapshot(count: 10)
        XCTAssertEqual(snapshot[0].count, 4) // clamped to capacity
    }
}
