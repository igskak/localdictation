import XCTest
@testable import Witness

final class MeetingAudioBufferTests: XCTestCase {
    func testQueueIsBoundedAndReportsLostFramesAndSequenceGaps() throws {
        let queue = MeetingAudioBuffer(capacity: 2, maximumFrames: 4, sampleRate: 48_000)
        func send(_ values: [Float], _ time: UInt64) {
            values.withUnsafeBufferPointer { queue.ingest($0, hostTime: time) }
        }
        send([1, 2], 10)
        send([3], 20)
        send([4, 5, 6], 30)
        XCTAssertEqual(queue.snapshot(), SystemAudioBufferCounters(receivedCallbacks: 3, droppedCallbacks: 1, droppedFrames: 3, queuedChunks: 2, peakQueuedChunks: 2))
        let first = try XCTUnwrap(queue.take())
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(first.hostTime, 10)
        XCTAssertEqual(first.samples, [1, 2])
        send([7], 40)
        XCTAssertEqual(queue.take()?.sequence, 1)
        let last = try XCTUnwrap(queue.take())
        XCTAssertEqual(last.sequence, 3)
        XCTAssertEqual(last.samples, [7])
        XCTAssertNil(queue.take())
        XCTAssertEqual(queue.snapshot().peakQueuedChunks, 2)
    }

    func testOversizedCallbackIsReportedWithoutTruncation() {
        let queue = MeetingAudioBuffer(capacity: 1, maximumFrames: 2, sampleRate: 48_000)
        [Float](repeating: 1, count: 3).withUnsafeBufferPointer { queue.ingest($0, hostTime: 1) }
        XCTAssertNil(queue.take())
        XCTAssertEqual(queue.snapshot().droppedFrames, 3)
    }
}
