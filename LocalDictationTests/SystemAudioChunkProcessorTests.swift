import CoreAudio
import XCTest
@testable import Witness

final class SystemAudioChunkProcessorTests: XCTestCase {
    func testFinalizationRequiresDrainingAndIsOnlyPerformedOnce() throws {
        let origin = AudioGetCurrentHostTime()
        let queue = MeetingAudioBuffer(capacity: 2, maximumFrames: 512, sampleRate: 16_000)
        let processor = try SystemAudioChunkProcessor(buffer: queue, inputSampleRate: 16_000, originHostTime: origin)
        [Float](repeating: 0.5, count: 128).withUnsafeBufferPointer { queue.ingest($0, hostTime: origin) }
        XCTAssertThrowsError(try processor.finish())
        let first = try XCTUnwrap(processor.take())
        XCTAssertEqual(first.source, .system)
        XCTAssertEqual(first.startFrame, 0)
        XCTAssertEqual(first.sequence, 0)
        XCTAssertFalse(first.isFinal)
        let final = try processor.finish()
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.sequence, 1)
        XCTAssertEqual(final.startFrame, Int64(first.samples.count))
        XCTAssertThrowsError(try processor.finish())
    }
}
