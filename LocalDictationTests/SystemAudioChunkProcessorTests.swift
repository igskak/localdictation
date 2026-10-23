import CoreAudio
import XCTest
@testable import Witness

final class SystemAudioChunkProcessorTests: XCTestCase {
    func testBothSourcesShareTheSameHostTimeOrigin() throws {
        let origin = AudioGetCurrentHostTime()
        let oneSecondLater = AudioConvertNanosToHostTime(AudioConvertHostTimeToNanos(origin) + 1_000_000_000)
        let systemQueue = MeetingAudioBuffer(capacity: 1, maximumFrames: 512, sampleRate: 16_000)
        let microphoneQueue = MeetingAudioBuffer(capacity: 1, maximumFrames: 512, sampleRate: 16_000)
        let system = try SystemAudioChunkProcessor(buffer: systemQueue, inputSampleRate: 16_000,
                                                   originHostTime: origin, source: .system)
        let microphone = try SystemAudioChunkProcessor(buffer: microphoneQueue, inputSampleRate: 16_000,
                                                       originHostTime: origin, source: .microphone)
        let frames = [Float](repeating: 0.5, count: 128)
        frames.withUnsafeBufferPointer { systemQueue.ingest($0, hostTime: origin) }
        frames.withUnsafeBufferPointer { microphoneQueue.ingest($0, hostTime: oneSecondLater) }

        let systemChunk = try XCTUnwrap(system.take())
        let microphoneChunk = try XCTUnwrap(microphone.take())
        XCTAssertEqual(systemChunk.source, .system)
        XCTAssertEqual(microphoneChunk.source, .microphone)
        XCTAssertLessThanOrEqual(abs(systemChunk.startFrame), 1)
        XCTAssertLessThanOrEqual(abs(microphoneChunk.startFrame - 16_000), 1)
    }

    func testIntentionalPauseKeepsTheResumedChunkOnTheHostTimeline() throws {
        let origin = AudioGetCurrentHostTime()
        let resumed = AudioConvertNanosToHostTime(AudioConvertHostTimeToNanos(origin) + 2_000_000_000)
        let queue = MeetingAudioBuffer(capacity: 2, maximumFrames: 512, sampleRate: 16_000)
        let processor = try SystemAudioChunkProcessor(buffer: queue, inputSampleRate: 16_000,
                                                      originHostTime: origin, source: .system)
        let frames = [Float](repeating: 0.5, count: 128)
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: origin) }
        _ = try XCTUnwrap(processor.take())

        processor.prepareForResume()
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: resumed) }
        let resumedChunk = try XCTUnwrap(processor.take())

        XCTAssertLessThanOrEqual(abs(resumedChunk.startFrame - 32_000), 1)
    }

    func testSparseSystemTapReanchorsAfterSilenceWithoutEndingCapture() throws {
        let origin = AudioGetCurrentHostTime()
        let twoSecondsLater = AudioConvertNanosToHostTime(AudioConvertHostTimeToNanos(origin) + 2_000_000_000)
        let queue = MeetingAudioBuffer(capacity: 2, maximumFrames: 512, sampleRate: 16_000)
        let processor = try SystemAudioChunkProcessor(
            buffer: queue,
            inputSampleRate: 16_000,
            originHostTime: origin,
            source: .system
        )
        let frames = [Float](repeating: 0.5, count: 128)
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: origin) }
        _ = try XCTUnwrap(processor.take())
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: twoSecondsLater) }

        let resumed = try XCTUnwrap(processor.take())

        XCTAssertLessThanOrEqual(abs(resumed.startFrame - 32_000), 1)
    }

    func testMicrophoneTimestampJumpReanchorsWithoutEndingCapture() throws {
        let origin = AudioGetCurrentHostTime()
        let twoSecondsLater = AudioConvertNanosToHostTime(AudioConvertHostTimeToNanos(origin) + 2_000_000_000)
        let queue = MeetingAudioBuffer(capacity: 2, maximumFrames: 512, sampleRate: 16_000)
        let processor = try SystemAudioChunkProcessor(
            buffer: queue,
            inputSampleRate: 16_000,
            originHostTime: origin,
            source: .microphone
        )
        let frames = [Float](repeating: 0.5, count: 128)
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: origin) }
        _ = try XCTUnwrap(processor.take())
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: twoSecondsLater) }

        let resumed = try XCTUnwrap(processor.take())

        XCTAssertLessThanOrEqual(abs(resumed.startFrame - 32_000), 1)
    }

    func testDroppedCallbackPreservesTheGapAndContinues() throws {
        let origin = AudioGetCurrentHostTime()
        let oneSecondLater = AudioConvertNanosToHostTime(AudioConvertHostTimeToNanos(origin) + 1_000_000_000)
        let queue = MeetingAudioBuffer(capacity: 1, maximumFrames: 512, sampleRate: 16_000)
        let processor = try SystemAudioChunkProcessor(buffer: queue, inputSampleRate: 16_000, originHostTime: origin)
        let frames = [Float](repeating: 0.5, count: 128)
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: origin) }
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: origin) }
        _ = try processor.take()
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: oneSecondLater) }

        let resumed = try XCTUnwrap(processor.take())

        XCTAssertLessThanOrEqual(abs(resumed.startFrame - 16_000), 1)
        XCTAssertEqual(queue.snapshot().droppedCallbacks, 1)
    }

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
