import AVFoundation
import XCTest
@testable import Witness

final class FileTranscriptionSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-transcription-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testEveryFrameOfALongFileIsRecognisedAndNoIntervalIsLost() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Das ist ein Satz."))
        let store = FileMeetingStore(rootURL: root)
        let session = makeSession(source: SyntheticFileSource(seconds: 600), engine: engine, store: store)

        let result = try await session.run()

        XCTAssertEqual(result.metrics.audioSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(result.metrics.lostIntervals, 0)
        XCTAssertGreaterThan(engine.transcribeCount, 10, "ten minutes of speech cannot be one decode call")
        // The windows tile the file: the rows start at 0 and end at the last frame.
        XCTAssertEqual(result.rows.first?.startFrame, 0)
        XCTAssertEqual(result.rows.last?.endFrame, 600 * 16_000)
        for (previous, next) in zip(result.rows, result.rows.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.endFrame, next.startFrame, "rows must not overlap")
        }
    }

    func testResultIsStoredAsAFileNoteWithTranscriptOnly() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Hallo Welt."))
        let store = FileMeetingStore(rootURL: root)
        let session = makeSession(source: SyntheticFileSource(seconds: 60), engine: engine, store: store, title: "interview")

        let result = try await session.run()

        let manifests = try await store.listMeetings()
        XCTAssertEqual(manifests.map(\.id), [result.meetingID])
        XCTAssertEqual(manifests.first?.sourcePlatform, .file)
        XCTAssertEqual(manifests.first?.title, "interview")
        XCTAssertEqual(manifests.first?.completionState, .completed)
        let stored = try await store.loadTranscript(meetingID: result.meetingID)
        XCTAssertEqual(stored.count, result.rows.count)
        let directory = root.appendingPathComponent(result.meetingID.uuidString, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains("audio") || $0.hasSuffix(".wav") })
    }

    func testCancellingLeavesNoNoteBehind() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Text."))
        let gate = engine.blockNextTranscription()
        let store = FileMeetingStore(rootURL: root)
        let session = makeSession(source: SyntheticFileSource(seconds: 300), engine: engine, store: store)

        let running = Task { try await session.run() }
        while engine.transcribeCount == 0 { await Task.yield() }
        await session.cancel()
        running.cancel()
        gate.open()

        do {
            _ = try await running.value
            XCTFail("a cancelled run must not produce a result")
        } catch {
            XCTAssertEqual(error as? FileTranscriptionFailure, .cancelled)
        }
        let manifests = try await store.listMeetings()
        XCTAssertTrue(manifests.isEmpty)
    }

    func testEachFileErrorSurfacesAsItself() async throws {
        for expected in [AudioFileError.noAudioTrack, .protectedContent, .unreadable, .empty] {
            let store = FileMeetingStore(rootURL: root)
            let engine = FakeTranscriptionService()
            let session = makeSession(source: SyntheticFileSource(seconds: 10, openError: expected), engine: engine, store: store)
            do {
                _ = try await session.run()
                XCTFail("must fail")
            } catch {
                XCTAssertEqual(error as? FileTranscriptionFailure, .file(expected))
            }
            let manifests = try await store.listMeetings()
            XCTAssertTrue(manifests.isEmpty)
            XCTAssertEqual(engine.transcribeCount, 0)
        }
    }

    func testMidFileReadFailureEndsTheRunWithoutANote() async throws {
        let store = FileMeetingStore(rootURL: root)
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Text."))
        let session = makeSession(source: SyntheticFileSource(seconds: 120, failAfterChunks: 40), engine: engine, store: store)

        do {
            _ = try await session.run()
            XCTFail("a failing read must not look like a finished transcript")
        } catch {
            XCTAssertEqual(error as? FileTranscriptionFailure, .file(.unreadable))
        }
        let manifests = try await store.listMeetings()
        XCTAssertTrue(manifests.isEmpty)
    }

    func testUnavailableModelFailsBeforeTheFileIsOpened() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("not downloaded", needsUserAction: true))
        let source = SyntheticFileSource(seconds: 10)
        let session = makeSession(source: source, engine: engine, store: FileMeetingStore(rootURL: root))

        do {
            _ = try await session.run()
            XCTFail("an unavailable model cannot transcribe")
        } catch {
            XCTAssertEqual(error as? FileTranscriptionFailure, .modelUnavailable)
        }
        XCTAssertFalse(source.wasOpened)
    }

    func testFullQueueWaitsForARecognitionInsteadOfDroppingTheWindow() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Text."))
        let worker = LongFormTranscriber(engine: engine, profile: .english, capacity: 1, speechClassifier: { _ in true })
        let session = makeSession(source: SyntheticFileSource(seconds: 1), engine: engine, store: FileMeetingStore(rootURL: root))
        try await worker.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 0, samples: [0.1]))

        try await session.enqueueWaiting(MeetingRecognitionAudio(source: .system, startFrame: 1, samples: [0.1]), worker: worker)

        let metrics = await worker.metrics
        let queued = await worker.queuedCount()
        XCTAssertEqual(metrics.lostIntervals, 0)
        XCTAssertEqual(queued, 1, "the second window waits in the queue after the first was recognised")
        XCTAssertEqual(engine.transcribeCount, 1)
    }

    func testProgressIsMonotonicAndTheEstimateAppearsAfterThirtySeconds() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Text."))
        let seen = ProgressLog()
        let clock = TickingClock()
        let session = FileTranscriptionSession(
            source: SyntheticFileSource(seconds: 300), engine: engine, profile: .english,
            persistence: MeetingPersistenceRecorder(store: FileMeetingStore(rootURL: root)), title: "t",
            uptime: { clock.next() }, footprint: { 100 }, emit: { seen.append($0) }
        )

        _ = try await session.run()

        let values = seen.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.map(\.recognisedFrames), values.map(\.recognisedFrames).sorted())
        XCTAssertNil(values.first.flatMap { $0.recognisedFrames < 30 * 16_000 ? $0.remaining : nil })
        XCTAssertNotNil(values.last?.remaining)
        XCTAssertEqual(values.last?.fraction ?? 0, 1, accuracy: 0.05)
    }

    func testRemainingTimeExtrapolatesWallTimePerRecognisedSecond() {
        let remaining = FileTranscriptionSession.remaining(elapsed: 60, recognisedFrames: 120 * 16_000, totalFrames: 600 * 16_000)
        XCTAssertEqual(remaining ?? -1, 240, accuracy: 0.001)
        XCTAssertNil(FileTranscriptionSession.remaining(elapsed: 5, recognisedFrames: 20 * 16_000, totalFrames: 600 * 16_000))
        XCTAssertEqual(FileTranscriptionSession.remaining(elapsed: 90, recognisedFrames: 700 * 16_000, totalFrames: 600 * 16_000) ?? -1, 0)
    }

    func testFileWindowsStayInsideWhispersThirtySecondsAndOnWholeEnergyFrames() {
        for sizes in [FileWindowSizes.file, .live] {
            XCTAssertLessThanOrEqual(sizes.maximumFrames, 30 * 16_000)
            XCTAssertLessThanOrEqual(sizes.minimumFrames, sizes.maximumFrames)
            for value in [sizes.minimumFrames, sizes.maximumFrames, sizes.pauseFrames] {
                XCTAssertEqual(value % MeetingWindowBuilder.energyFrame, 0)
            }
        }
        XCTAssertGreaterThan(FileWindowSizes.file.maximumFrames, FileWindowSizes.live.maximumFrames)
    }

    func testSpeakersFromTheDiarizerLabelRowsAndAreNamedInTheManifest() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Text."))
        let store = FileMeetingStore(rootURL: root)
        let session = makeSession(source: SyntheticFileSource(seconds: 600), engine: engine, store: store,
                                  diarizer: ScriptedDiarizer())

        let result = try await session.run()

        XCTAssertTrue(result.speakersLabelled)
        XCTAssertEqual(Set(result.rows.map(\.speakerID)), ["speaker-1", "speaker-2"])
        XCTAssertTrue(result.rows.allSatisfy { $0.speakerAssignmentSource == .diarization })
        let manifest = try await store.loadManifest(id: result.meetingID)
        XCTAssertEqual(manifest.speakerDisplayNames["speaker-1"], "Speaker 1")
        XCTAssertEqual(manifest.speakerDisplayNames["speaker-2"], "Speaker 2")
        XCTAssertGreaterThan(result.diarization.processedAudioSeconds, 599)
    }

    func testDiarizerThatCannotPrepareLeavesTheTranscriptUnlabelled() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Text."))
        let store = FileMeetingStore(rootURL: root)
        let session = makeSession(source: SyntheticFileSource(seconds: 120), engine: engine, store: store,
                                  diarizer: ScriptedDiarizer(failPreparation: true))

        let result = try await session.run()

        XCTAssertFalse(result.speakersLabelled)
        XCTAssertEqual(Set(result.rows.map(\.speakerID)), ["others"])
        let manifest = try await store.loadManifest(id: result.meetingID)
        XCTAssertEqual(manifest.speakerDisplayNames, ["others": "Speaker"])
    }

    func testDiarizerFailingMidFileDropsEveryLabelRatherThanKeepingHalf() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript("Text."))
        let session = makeSession(source: SyntheticFileSource(seconds: 600), engine: engine,
                                  store: FileMeetingStore(rootURL: root), diarizer: ScriptedDiarizer(failAtSecond: 300))

        let result = try await session.run()

        XCTAssertFalse(result.speakersLabelled)
        XCTAssertEqual(Set(result.rows.map(\.speakerID)), ["others"])
        XCTAssertGreaterThan(result.rows.count, 10, "the transcript itself is unaffected")
    }

    // MARK: - Helpers

    private func makeSession(source: SyntheticFileSource, engine: FakeTranscriptionService, store: FileMeetingStore,
                             title: String = "file",
                             diarizer: (any StreamingSpeakerDiarizationService)? = nil) -> FileTranscriptionSession {
        FileTranscriptionSession(
            source: source, engine: engine, profile: .english,
            persistence: MeetingPersistenceRecorder(store: store), title: title,
            diarizer: diarizer,
            footprint: { 100 }
        )
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(text: text, tokens: [], profile: .english, detectedLanguage: .english,
                   audioDuration: 1, processingDuration: 0, engineIdentifier: "fake")
    }
}

/// Audio that alternates ten seconds of tone with one second of silence, in the
/// same one-second chunks the real reader produces.
private final class SyntheticFileSource: AudioFileReading, @unchecked Sendable {
    private let seconds: Int
    private let openError: AudioFileError?
    private let failAfterChunks: Int?
    private let lock = NSLock()
    private var delivered = 0
    private(set) var wasOpened = false

    init(seconds: Int, openError: AudioFileError? = nil, failAfterChunks: Int? = nil) {
        self.seconds = seconds
        self.openError = openError
        self.failAfterChunks = failAfterChunks
    }

    func open() async throws -> AudioFileInfo {
        lock.withLock { wasOpened = true }
        if let openError { throw openError }
        return AudioFileInfo(estimatedFrames: Int64(seconds) * 16_000)
    }

    func nextChunk() throws -> MeetingAudioChunk? {
        try lock.withLock {
            guard delivered < seconds else { return nil }
            if let failAfterChunks, delivered >= failAfterChunks { throw AudioFileError.unreadable }
            let second = delivered
            delivered += 1
            let quiet = second % 11 == 10
            let samples = (0..<16_000).map { quiet ? Float(0) : ($0.isMultiple(of: 2) ? 0.2 : -0.2) }
            return MeetingAudioChunk(source: .system, sequence: UInt64(second), startFrame: Int64(second) * 16_000,
                                     sampleRate: 16_000, samples: samples, isFinal: delivered == seconds)
        }
    }

    func close() {}
}

/// Two speakers who swap every minute, one turn per chunk.
private actor ScriptedDiarizer: StreamingSpeakerDiarizationService {
    private let failPreparation: Bool
    private let failAtSecond: Int64?
    private var metrics = DiarizationRuntimeMetrics()

    init(failPreparation: Bool = false, failAtSecond: Int64? = nil) {
        self.failPreparation = failPreparation
        self.failAtSecond = failAtSecond
    }

    func prepare() throws {
        if failPreparation { throw ProductionDiarizationError.bundledModelMissing }
    }

    func ingest(_ chunk: MeetingAudioChunk) throws -> [DiarizedSpeakerTurn] {
        let second = chunk.startFrame / 16_000
        if let failAtSecond, second >= failAtSecond { throw ProductionDiarizationError.notPrepared }
        metrics.processedAudioSeconds += Double(chunk.samples.count) / 16_000
        let speaker = (second / 60) % 2 + 1
        return [DiarizedSpeakerTurn(speakerID: "speaker-\(speaker)", startFrame: chunk.startFrame,
                                    endFrame: chunk.startFrame + Int64(chunk.samples.count), confidence: 0.9)]
    }

    func finish() -> [DiarizedSpeakerTurn] { [] }
    func metricsSnapshot() -> DiarizationRuntimeMetrics { metrics }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FileTranscriptionProgress] = []
    func append(_ value: FileTranscriptionProgress) { lock.withLock { storage.append(value) } }
    var values: [FileTranscriptionProgress] { lock.withLock { storage } }
}

/// Each reading advances one second, so elapsed time grows with the work done.
private final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func next() -> TimeInterval { lock.withLock { value += 1; return value } }
}

final class AudioFileSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testChunksAreOneSecondContiguousFromZeroAndTheLastOneIsMarkedFinal() async throws {
        let url = try writeTone(seconds: 3.5, sampleRate: 16_000, channels: 1, name: "tone.wav")
        let source = AVAssetAudioFileSource(url: url)
        let info = try await source.open()
        defer { source.close() }
        var chunks: [MeetingAudioChunk] = []
        while let chunk = try source.nextChunk() { chunks.append(chunk) }

        XCTAssertEqual(info.estimatedSeconds, 3.5, accuracy: 0.05)
        XCTAssertEqual(chunks.map(\.startFrame), [0, 16_000, 32_000, 48_000])
        XCTAssertEqual(chunks.map(\.samples.count), [16_000, 16_000, 16_000, 8_000])
        XCTAssertEqual(chunks.map(\.isFinal), [false, false, false, true])
        XCTAssertEqual(chunks.map(\.sequence), [0, 1, 2, 3])
        XCTAssertTrue(chunks.allSatisfy { $0.source == .system && $0.sampleRate == 16_000 })
        XCTAssertNil(try source.nextChunk(), "nothing follows the final chunk")
    }

    func testStereoAtCDRateIsDownmixedAndResampledToSixteenKilohertzMono() async throws {
        let url = try writeTone(seconds: 2, sampleRate: 44_100, channels: 2, name: "stereo.wav")
        let source = AVAssetAudioFileSource(url: url)
        _ = try await source.open()
        defer { source.close() }
        var frames = 0
        var peak: Float = 0
        while let chunk = try source.nextChunk() {
            frames += chunk.samples.count
            peak = max(peak, chunk.samples.map(abs).max() ?? 0)
        }

        XCTAssertEqual(Double(frames), 32_000, accuracy: 400)
        XCTAssertGreaterThan(peak, 0.1, "the tone survives the conversion")
    }

    func testAChunkEdgeEndingExactlyOnTheLastFrameStillMarksFinal() async throws {
        let url = try writeTone(seconds: 2, sampleRate: 16_000, channels: 1, name: "exact.wav")
        let source = AVAssetAudioFileSource(url: url)
        _ = try await source.open()
        defer { source.close() }
        var chunks: [MeetingAudioChunk] = []
        while let chunk = try source.nextChunk() { chunks.append(chunk) }

        XCTAssertEqual(chunks.map(\.isFinal), [false, true])
    }

    func testMissingFileAndNonAudioFileAreUnreadable() async throws {
        let missing = AVAssetAudioFileSource(url: directory.appendingPathComponent("missing.m4a"))
        await assertOpenFails(missing, .unreadable)

        let text = directory.appendingPathComponent("notes.mp3")
        try Data("this is not audio".utf8).write(to: text)
        await assertOpenFails(AVAssetAudioFileSource(url: text), .unreadable)
    }

    func testReadingBeforeOpeningFailsInsteadOfReturningSilence() {
        let source = AVAssetAudioFileSource(url: directory.appendingPathComponent("x.wav"))
        XCTAssertThrowsError(try source.nextChunk()) { XCTAssertEqual($0 as? AudioFileError, .unreadable) }
    }

    private func assertOpenFails(_ source: AVAssetAudioFileSource, _ expected: AudioFileError, line: UInt = #line) async {
        do {
            _ = try await source.open()
            XCTFail("must not open", line: line)
        } catch {
            XCTAssertEqual(error as? AudioFileError, expected, line: line)
        }
    }

    private func writeTone(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let pointer = try XCTUnwrap(buffer.floatChannelData?[channel])
            for index in 0..<Int(frames) {
                pointer[index] = 0.5 * sin(2 * .pi * 440 * Float(index) / Float(sampleRate))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
