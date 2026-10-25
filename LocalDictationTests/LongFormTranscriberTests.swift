import XCTest
@testable import Witness

final class LongFormTranscriberTests: XCTestCase {
    func testWindowEndsInTheMiddleOfAPauseAndTheNextOneStartsThere() throws {
        var builder = smallBuilder()
        XCTAssertTrue(try builder.append(chunk(start: 0, values: speech(frames: 12))).isEmpty)

        let closed = try builder.append(chunk(start: 12 * 320, values: silence(frames: 3) + speech(frames: 5)))

        let first = try XCTUnwrap(closed.first)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(first.startFrame, 0)
        XCTAssertEqual(first.samples.count, 13 * 320)
        let tail = try XCTUnwrap(builder.finish())
        XCTAssertEqual(tail.startFrame, first.endFrame, "windows must neither overlap nor leave a hole")
        XCTAssertEqual(tail.samples.count, 7 * 320)
    }

    func testPauseBeforeTheMinimumDoesNotEndTheWindow() throws {
        var builder = smallBuilder()
        let early = speech(frames: 3) + silence(frames: 3) + speech(frames: 10)
        XCTAssertTrue(try builder.append(chunk(start: 0, values: early)).isEmpty)

        let closed = try builder.append(chunk(start: 16 * 320, values: silence(frames: 2)))

        XCTAssertEqual(closed.map(\.samples.count), [17 * 320])
    }

    func testSpeechWithoutAPauseIsCutAtItsQuietestStretchAtTheMaximum() throws {
        var builder = smallBuilder()
        let values = speech(frames: 20) + speech(frames: 2, level: 0.2) + speech(frames: 8)

        let windows = try builder.append(chunk(start: 0, values: values))

        XCTAssertEqual(windows.map(\.samples.count), [21 * 320])
        XCTAssertEqual(builder.finish()?.startFrame, 21 * 320)
    }

    func testBackwardOverlapIsTrimmedInsteadOfEndingTheMeeting() throws {
        var builder = smallBuilder()
        _ = try builder.append(chunk(start: 10, values: [1, 2]))

        XCTAssertNoThrow(try builder.append(chunk(start: 9, values: [7, 7, 7, 8])))
        XCTAssertTrue(try builder.append(chunk(start: 5, values: [7, 7])).isEmpty)

        let tail = try XCTUnwrap(builder.finish())
        XCTAssertEqual(tail.startFrame, 10)
        XCTAssertEqual(tail.samples, [1, 2, 8])
    }

    func testForwardMicrophoneGapClosesAWindowWithoutInventingSilence() throws {
        var builder = smallBuilder()
        _ = try builder.append(chunk(start: 0, values: [1, 2]))

        let closed = try builder.append(chunk(start: 9, values: [3]))

        XCTAssertEqual(closed.first?.startFrame, 0)
        XCTAssertEqual(closed.first?.samples, [1, 2])
        XCTAssertEqual(builder.finish()?.startFrame, 9)
    }

    func testSparseSystemAudioClosesAWindowWithoutInventingSilence() throws {
        var builder = smallBuilder(source: .system)
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

    func testDefaultLiveWindowWaitsEightSecondsAndThenForAPause() throws {
        var builder = MeetingWindowBuilder(source: .microphone)
        XCTAssertTrue(try builder.append(chunk(start: 0, values: speech(frames: 399, level: 0.1))).isEmpty)

        let first = try builder.append(chunk(start: 399 * 320, values: silence(frames: 20)))

        XCTAssertEqual(first.map(\.startFrame), [0])
        XCTAssertEqual(first.first?.samples.count, 406 * 320)
    }

    func testDefaultLiveWindowNeverExceedsTwentySecondsOfUnbrokenSpeech() throws {
        var builder = MeetingWindowBuilder(source: .microphone)
        var windows: [MeetingRecognitionAudio] = []
        for second in 0..<45 {
            windows += try builder.append(chunk(start: Int64(second) * 16_000, values: speech(frames: 50, level: 0.1)))
        }
        if let tail = builder.finish() { windows.append(tail) }

        XCTAssertGreaterThanOrEqual(windows.count, 3)
        XCTAssertTrue(windows.dropLast().allSatisfy { (128_000...320_000).contains($0.samples.count) })
        XCTAssertEqual(windows.map(\.samples.count).reduce(0, +), 45 * 16_000)
        for (previous, next) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(next.startFrame, previous.endFrame)
        }
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

    /// Ten-frame minimum, thirty-frame maximum, two-frame pause.
    private func smallBuilder(source: MeetingAudioSource = .microphone) -> MeetingWindowBuilder {
        MeetingWindowBuilder(source: source, minimumFrames: 10 * 320, maximumFrames: 30 * 320, pauseFrames: 2 * 320)
    }

    private func speech(frames: Int, level: Float = 0.5) -> [Float] {
        (0..<(frames * 320)).map { $0.isMultiple(of: 2) ? level : -level }
    }

    private func silence(frames: Int) -> [Float] {
        [Float](repeating: 0, count: frames * 320)
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
