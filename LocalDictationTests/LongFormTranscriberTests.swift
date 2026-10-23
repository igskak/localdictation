import XCTest
@testable import Witness

final class LongFormTranscriberTests: XCTestCase {
    func testWindowBoundariesOverlapAndFinalTail() throws {
        var builder = MeetingWindowBuilder(source: .microphone, windowFrames: 6, overlapFrames: 2)
        XCTAssertEqual(try builder.append(chunk(start: 0, values: [0, 1, 2])).count, 0)
        let first = try builder.append(chunk(start: 3, values: [3, 4, 5]))
        XCTAssertEqual(first.first?.samples, [0, 1, 2, 3, 4, 5])
        let second = try builder.append(chunk(start: 6, values: [6, 7, 8, 9]))
        XCTAssertEqual(second.first?.samples, [4, 5, 6, 7, 8, 9])
        XCTAssertNil(builder.finish())
    }

    func testForwardMicrophoneGapClosesAWindowWithoutInventingSilence() throws {
        var builder = MeetingWindowBuilder(source: .microphone, windowFrames: 10, overlapFrames: 2)
        _ = try builder.append(chunk(start: 0, values: [1, 2]))

        let closed = try builder.append(chunk(start: 9, values: [3]))

        XCTAssertEqual(closed.first?.startFrame, 0)
        XCTAssertEqual(closed.first?.samples, [1, 2])
        XCTAssertEqual(builder.finish()?.startFrame, 9)
    }

    func testBackwardAudioOverlapIsReportedBeforeDataIsAccepted() throws {
        var builder = MeetingWindowBuilder(source: .microphone, windowFrames: 10, overlapFrames: 2)
        _ = try builder.append(chunk(start: 10, values: [1, 2]))
        XCTAssertThrowsError(try builder.append(chunk(start: 1, values: [3]))) {
            XCTAssertEqual($0 as? LongFormTranscriptionError, .missingAudio)
        }
        XCTAssertEqual(builder.finish()?.samples, [1, 2])
    }

    func testDefaultLiveWindowEmitsAfterEightSeconds() throws {
        var builder = MeetingWindowBuilder(source: .microphone)
        let almostEightSeconds = [Float](repeating: 0.1, count: 127_999)

        XCTAssertTrue(try builder.append(chunk(start: 0, values: almostEightSeconds)).isEmpty)
        let first = try builder.append(chunk(start: 127_999, values: [0.1]))

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.samples.count, 128_000)
    }

    func testDefaultRollingWindowAddsFourSecondsOfLeftContextWithoutIncreasingUpdateCadence() throws {
        var builder = MeetingWindowBuilder(source: .microphone)
        let first = try builder.append(chunk(start: 0, values: [Float](repeating: 0.1, count: 128_000)))
        XCTAssertEqual(first.map(\.samples.count), [128_000])
        XCTAssertEqual(first.first?.startFrame, 0)

        let beforeNextUpdate = try builder.append(
            chunk(start: 128_000, values: [Float](repeating: 0.1, count: 127_999))
        )
        XCTAssertTrue(beforeNextUpdate.isEmpty)
        let next = try builder.append(chunk(start: 255_999, values: [0.1]))

        XCTAssertEqual(next.map(\.samples.count), [192_000])
        XCTAssertEqual(next.first?.startFrame, 64_000)
    }

    func testDefaultFinalTailIncludesFourSecondsOfPriorContext() throws {
        var builder = MeetingWindowBuilder(source: .microphone)
        _ = try builder.append(chunk(start: 0, values: [Float](repeating: 0.1, count: 128_000)))
        _ = try builder.append(chunk(start: 128_000, values: [0.2]))

        let tail = try XCTUnwrap(builder.finish())
        XCTAssertEqual(tail.startFrame, 64_000)
        XCTAssertEqual(tail.samples.count, 64_001)
        XCTAssertEqual(tail.samples.last, 0.2)
    }

    func testSparseSystemAudioClosesAWindowWithoutInventingSilence() throws {
        var builder = MeetingWindowBuilder(source: .system, windowFrames: 10, overlapFrames: 2)
        _ = try builder.append(chunk(source: .system, start: 0, values: [1, 2]))

        let closed = try builder.append(chunk(source: .system, start: 32_000, values: [3, 4]))

        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.startFrame, 0)
        XCTAssertEqual(closed.first?.samples, [1, 2])
        let tail = builder.finish()
        XCTAssertEqual(tail?.startFrame, 32_000)
        XCTAssertEqual(tail?.samples, [3, 4])
        XCTAssertNil(builder.finish())
    }

    func testBoundedQueueAndFairSourceOrder() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(Transcript(text: "hello", tokens: [], profile: .english, detectedLanguage: .english,
                                    audioDuration: 1, processingDuration: 0, engineIdentifier: "fake"))
        let service = LongFormTranscriber(engine: engine, profile: .english, capacity: 3,
                                          speechClassifier: { _ in true })
        try await service.enqueue(MeetingRecognitionAudio(source: .microphone, startFrame: 0, samples: [1]))
        try await service.enqueue(MeetingRecognitionAudio(source: .microphone, startFrame: 10, samples: [2]))
        try await service.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 1, samples: [3]))
        do {
            try await service.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 2, samples: [4]))
            XCTFail("full queue must reject input")
        } catch { XCTAssertEqual(error as? LongFormTranscriptionError, .backlogFull) }
        let first = try await service.drainOne()
        let second = try await service.drainOne()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        let rows = await service.assembler.rows
        XCTAssertEqual(rows.map(\.source), [.microphone, .system])
        let remaining = await service.queuedCount()
        XCTAssertEqual(remaining, 1)
    }

    func testModelFailureKeepsWindowAvailableForRecovery() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("test", needsUserAction: true))
        let service = LongFormTranscriber(engine: engine, profile: .english,
                                          speechClassifier: { _ in true })
        try await service.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 0, samples: [1]))
        do { _ = try await service.drainOne(); XCTFail("must refuse an unready model") }
        catch { XCTAssertEqual(error as? LongFormTranscriptionError, .modelNotReady) }
        let remaining = await service.queuedCount()
        XCTAssertEqual(remaining, 1)
    }

    func testMeasuredSilenceSkipsInferenceWithoutLosingTimelineProgress() async throws {
        let engine = FakeTranscriptionService()
        let service = LongFormTranscriber(engine: engine, profile: .english)
        let silence = MeetingRecognitionAudio(source: .system, startFrame: 32_000,
                                               samples: [Float](repeating: 0, count: 960))
        try await service.enqueue(silence)
        let madeProgress = try await service.drainOne()
        let queued = await service.queuedCount()
        let rows = await service.assembler.rows
        XCTAssertTrue(madeProgress)
        XCTAssertEqual(engine.transcribeCount, 0)
        XCTAssertEqual(queued, 0)
        let metrics = await service.metrics
        XCTAssertEqual(metrics.skippedSilentWindows, 1)
        XCTAssertEqual(metrics.skippedSilentAudioSeconds, 0.06, accuracy: 0.000_001)
        XCTAssertTrue(rows.isEmpty)
    }

    func testQueueDelayAndRealTimeFactorUseInjectedMonotonicClock() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(Transcript(text: "hello", tokens: [], profile: .english, detectedLanguage: .english,
                                    audioDuration: 1, processingDuration: 0, engineIdentifier: "fake"))
        let clock = TestMeetingClock(10)
        let service = LongFormTranscriber(engine: engine, profile: .english,
                                          speechClassifier: { _ in true }, uptime: { clock.value })
        try await service.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 0,
                                                          samples: [Float](repeating: 0.1, count: 16_000)))
        clock.value = 13
        let madeProgress = try await service.drainOne()
        XCTAssertTrue(madeProgress)
        let metrics = await service.metrics
        XCTAssertEqual(metrics.maximumQueueDelay, 3)
        XCTAssertEqual(metrics.inferenceSeconds, 0)
        XCTAssertEqual(metrics.transcribedAudioSeconds, 1)
        XCTAssertEqual(metrics.realTimeFactor, 0)
    }

    func testCancellationRejectsLateResultAndReleasesBoundedAudio() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(Transcript(text: "late", tokens: [], profile: .english, detectedLanguage: .english,
                                    audioDuration: 1, processingDuration: 0, engineIdentifier: "fake"))
        let gate = engine.blockNextTranscription()
        let service = LongFormTranscriber(engine: engine, profile: .english,
                                          speechClassifier: { _ in true })
        try await service.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 0, samples: [0.1]))
        let draining = Task { try await service.drainOne() }
        while engine.transcribeCount == 0 { await Task.yield() }
        await service.cancel()
        gate.open()
        do {
            _ = try await draining.value
            XCTFail("a result from a cancelled generation must not publish")
        } catch {
            XCTAssertEqual(error as? LongFormTranscriptionError, .cancelled)
        }
        let queued = await service.queuedCount()
        let rows = await service.assembler.rows
        let metrics = await service.metrics
        XCTAssertEqual(queued, 0)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(metrics.lostIntervals, 1)
    }

    private func chunk(
        source: MeetingAudioSource = .microphone,
        start: Int64,
        values: [Float]
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(source: source, sequence: 0, startFrame: start, sampleRate: 16_000, samples: values, isFinal: false)
    }
}

private final class TestMeetingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval
    init(_ value: TimeInterval) { storedValue = value }
    var value: TimeInterval {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
