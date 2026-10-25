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

    func testTimelineTrustsTheSampleCountWithinTolerance() {
        var timeline = MeetingTimeline()
        _ = timeline.place(hostFrame: 1_000, frameCount: 160)

        let next = timeline.place(hostFrame: 1_160 + MeetingTimeline.driftToleranceFrames, frameCount: 160)

        XCTAssertEqual(next, .init(startFrame: 1_160, paddingFrames: 0, trimmedFrames: 0, correction: .none))
    }

    func testFastDeviceClockLosesTheOverlapInsteadOfEndingTheMeeting() {
        var timeline = MeetingTimeline()
        _ = timeline.place(hostFrame: 0, frameCount: 16_000)

        let next = timeline.place(hostFrame: 15_000, frameCount: 1_600)

        XCTAssertEqual(next, .init(startFrame: 16_000, paddingFrames: 0, trimmedFrames: 1_000,
                                   correction: .trimmed(frames: 1_000)))
        XCTAssertEqual(timeline.nextFrame, 16_600, "the timeline is back on host time")
    }

    func testSlowDeviceClockIsPaddedWithSilenceSoTheSentenceStaysInOneWindow() {
        var timeline = MeetingTimeline()
        _ = timeline.place(hostFrame: 0, frameCount: 16_000)

        let next = timeline.place(hostFrame: 17_000, frameCount: 1_600)

        XCTAssertEqual(next, .init(startFrame: 16_000, paddingFrames: 1_000, trimmedFrames: 0,
                                   correction: .padded(frames: 1_000)))
        XCTAssertEqual(timeline.nextFrame, 18_600)
    }

    func testLongHoleStartsAtHostTime() {
        var timeline = MeetingTimeline()
        _ = timeline.place(hostFrame: 0, frameCount: 160)

        let next = timeline.place(hostFrame: 32_000, frameCount: 160)

        XCTAssertEqual(next.startFrame, 32_000)
        XCTAssertEqual(next.correction, .gap(frames: 31_840))
    }

    func testChunkThatWasAlreadyHandedOutIsDroppedWithoutMovingTheTimeline() {
        var timeline = MeetingTimeline()
        _ = timeline.place(hostFrame: 0, frameCount: 16_000)

        let next = timeline.place(hostFrame: 8_000, frameCount: 1_600)

        XCTAssertEqual(next.trimmedFrames, 1_600)
        XCTAssertEqual(timeline.nextFrame, 16_000)
    }

    func testDeviceClockRestartKeepsTheAudioAndCorrectsOnlyOnce() {
        var timeline = MeetingTimeline()
        _ = timeline.place(hostFrame: 160_000, frameCount: 160)

        let reset = timeline.place(hostFrame: 0, frameCount: 160)
        let after = timeline.place(hostFrame: 160, frameCount: 160)

        XCTAssertEqual(reset, .init(startFrame: 160_160, paddingFrames: 0, trimmedFrames: 0,
                                    correction: .clockReset(frames: 160_160)))
        XCTAssertEqual(after, .init(startFrame: 160_320, paddingFrames: 0, trimmedFrames: 0, correction: .none))
    }

    /// 23.10: the microphone ran on its sample count for 29 minutes, then one
    /// host-time correction went backwards and the meeting ended.
    func testHalfHourOfFastDeviceClockStaysOrderedAndCloseToHostTime() {
        var timeline = MeetingTimeline()
        let chunk = 160
        let fast = 1.000_05
        var previousEnd: Int64?
        var deviceFrames = 0
        var corrections = 0
        for _ in 0..<(30 * 60 * 100) {
            let hostFrame = Int64((Double(deviceFrames) / fast).rounded())
            let placement = timeline.place(hostFrame: hostFrame, frameCount: chunk)
            if let previousEnd { XCTAssertEqual(placement.startFrame, previousEnd) }
            if placement.correction != .none { corrections += 1 }
            previousEnd = timeline.nextFrame
            XCTAssertLessThanOrEqual(abs(timeline.nextFrame! - (hostFrame + Int64(chunk))),
                                     MeetingTimeline.driftToleranceFrames + Int64(chunk))
            deviceFrames += chunk
        }
        XCTAssertGreaterThan(corrections, 0)
        XCTAssertLessThan(corrections, 300, "a 50 ppm clock needs one correction every few minutes")
    }

    func testProcessorTrimsAChunkThatClaimsEarlierAudioAndKeepsGoing() throws {
        let origin = AudioGetCurrentHostTime()
        let originNanos = AudioConvertHostTimeToNanos(origin)
        let early = AudioConvertNanosToHostTime(originNanos + 250_000_000 - 100_000_000)
        let queue = MeetingAudioBuffer(capacity: 2, maximumFrames: 4_096, sampleRate: 16_000)
        let processor = try SystemAudioChunkProcessor(buffer: queue, inputSampleRate: 16_000,
                                                      originHostTime: origin, source: .microphone)
        let frames = [Float](repeating: 0.5, count: 4_000)
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: origin) }
        frames.withUnsafeBufferPointer { queue.ingest($0, hostTime: early) }

        let first = try XCTUnwrap(processor.take())
        let second = try XCTUnwrap(processor.take())

        XCTAssertEqual(second.startFrame, first.startFrame + Int64(first.samples.count))
        XCTAssertLessThan(second.samples.count, 4_000)
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
