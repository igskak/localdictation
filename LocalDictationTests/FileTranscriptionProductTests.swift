import AppKit
import AVFoundation
import XCTest
@testable import Witness

final class TranscriptExportTests: XCTestCase {
    private func manifest(names: [String: String] = ["speaker-1": "Frau Becker", "speaker-2": "Herr Krüger"]) -> MeetingManifest {
        MeetingManifest(title: "Interview", startedAt: Date(timeIntervalSince1970: 0), selectedLanguages: [.german],
                        sourcePlatform: .file, speakerDisplayNames: names)
    }

    private func record(_ speaker: String, from start: Double, to end: Double, _ text: String,
                        uncertain: Bool = false) -> MeetingTranscriptRecord {
        MeetingTranscriptRecord(
            source: .system, speakerID: speaker,
            startFrame: Int64(start * 16_000), endFrame: Int64(end * 16_000),
            text: text, rawText: text, meanConfidence: 0.9, minimumConfidence: uncertain ? 0.1 : 0.8,
            hasConfidenceSignal: true, riskEvidence: uncertain ? ["low-confidence recognition"] : []
        )
    }

    func testSubtitleCuesAreNumberedTimedAndWrappedToTwoShortLines() {
        let long = "Das ist ein ziemlich langer Satz, den niemand als einzelnen Untertitel lesen möchte, weil er viel zu lang ist."
        let srt = MeetingExportRenderer.subtitles(
            manifest: manifest(),
            records: [record("speaker-1", from: 1, to: 9, long), record("speaker-2", from: 9.5, to: 11, "Ja.")]
        )
        let blocks = srt.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")

        XCTAssertEqual(blocks.compactMap { $0.components(separatedBy: "\n").first }, (1...blocks.count).map(String.init))
        XCTAssertTrue(blocks[0].contains("00:00:01,000 --> "))
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            XCTAssertTrue(lines[1].contains(" --> "))
            let text = lines.dropFirst(2)
            XCTAssertLessThanOrEqual(text.count, 2)
            XCTAssertTrue(text.allSatisfy { $0.count <= 42 + "Frau Becker: ".count })
        }
        XCTAssertTrue(srt.contains("Frau Becker: Das ist"), "a second speaker means every cue names its speaker")
        XCTAssertTrue(srt.contains("Herr Krüger: Ja."))
        XCTAssertTrue(srt.contains("00:00:09,000"), "the long row's cues end where the row ends")
    }

    func testSingleSpeakerSubtitlesCarryNoSpeakerPrefix() {
        let srt = MeetingExportRenderer.subtitles(manifest: manifest(names: ["others": "Speaker"]),
                                                  records: [record("others", from: 0, to: 2, "Guten Tag.")])
        XCTAssertEqual(srt, "1\n00:00:00,000 --> 00:00:02,000\nGuten Tag.\n")
    }

    func testSubtitleTimesRoundToMillisecondsAndCarryHours() {
        XCTAssertEqual(MeetingExportRenderer.srtTime(3_725.0456), "01:02:05,046")
        XCTAssertEqual(MeetingExportRenderer.srtTime(0), "00:00:00,000")
    }

    func testTimestampedTextPutsTheStampAtTheStartOfEachTurn() {
        let text = MeetingExportRenderer.timestampedText(
            manifest: manifest(),
            records: [record("speaker-1", from: 83.47, to: 90, "Guten Tag."), record("speaker-2", from: 3_600, to: 3_601, "Hallo.")]
        )
        XCTAssertEqual(text, "Frau Becker: #00:01:23-4# Guten Tag.\nHerr Krüger: #01:00:00-0# Hallo.\n")
    }

    func testUncertainPassagesKeepAVisibleMarkInTextAndWordButNotInSubtitles() throws {
        let uncertain = record("speaker-1", from: 0, to: 3, "Wir zahlen 1450 Euro.", uncertain: true)
        let plain = MeetingExportRenderer.text(manifest: manifest(), records: [uncertain], notes: MeetingNotes(), format: .plainText)
        let stamped = MeetingExportRenderer.text(manifest: manifest(), records: [uncertain], notes: MeetingNotes(), format: .timestampedText)
        let srt = MeetingExportRenderer.text(manifest: manifest(), records: [uncertain], notes: MeetingNotes(), format: .srt)

        XCTAssertTrue(plain.contains(MeetingExportRenderer.uncertaintyMark()))
        XCTAssertTrue(stamped.contains(MeetingExportRenderer.uncertaintyMark()))
        XCTAssertFalse(srt.contains(MeetingExportRenderer.uncertaintyMark()), "a mark in a subtitle would be shown on screen")

        let docx = try MeetingExportRenderer.docx(manifest: manifest(), records: [uncertain], notes: MeetingNotes())
        let text = try readDocx(docx).string
        XCTAssertTrue(text.contains(MeetingExportRenderer.uncertaintyMark()))
    }

    func testDocxIsAZipThatWordCanReadBackWithSpeakerNamesAndText() throws {
        let data = try MeetingExportRenderer.docx(
            manifest: manifest(),
            records: [record("speaker-1", from: 5, to: 8, "Guten Tag."), record("speaker-2", from: 9, to: 10, "Servus.")],
            notes: MeetingNotes(text: "Rückruf vereinbart")
        )

        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "an OOXML package is a zip")
        let string = try readDocx(data).string
        for expected in ["Interview", "Frau Becker", "00:00:05", "Guten Tag.", "Herr Krüger", "Servus.", "Rückruf vereinbart"] {
            XCTAssertTrue(string.contains(expected), expected)
        }
    }

    func testUnnamedNumberedSpeakerFallsBackToSpeakerAndItsNumber() {
        XCTAssertEqual(MeetingExportRenderer.displayName(for: "speaker-3", in: manifest(names: [:])),
                       "\(L10n.string("Speaker")) 3")
        XCTAssertEqual(MeetingExportRenderer.displayName(for: "speaker-1", in: manifest()), "Frau Becker")
    }

    func testStoreExportsDocxAsBytesAndRefusesItAsText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileMeetingStore(rootURL: root)
        let note = manifest()
        try await store.createMeeting(note)
        try await store.appendTranscript(record("speaker-1", from: 0, to: 2, "Hallo."), meetingID: note.id)

        let data = try await store.exportData(meetingID: note.id, format: .docx)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B])
        let srt = try await store.exportData(meetingID: note.id, format: .srt)
        XCTAssertTrue(String(decoding: srt, as: UTF8.self).contains("00:00:00,000 --> 00:00:02,000"))
        do {
            _ = try await store.export(meetingID: note.id, format: .docx)
            XCTFail("DOCX is not text")
        } catch {
            XCTAssertEqual(error as? MeetingStoreError, .unreadable("docx is not text"))
        }
    }

    func testEveryFormatHasADistinctPurposeAndAKnownExtension() {
        XCTAssertEqual(MeetingExportFormat.allCases.map(\.fileExtension).sorted(), ["docx", "md", "srt", "txt", "txt"])
    }

    func testAFileNoteKeepsItsSourceAndAnOldManifestStillDecodes() throws {
        let file = MeetingSourceFile(name: "interview.m4a", path: "/Users/x/interview.m4a", durationSeconds: 3_600)
        var note = manifest()
        note = MeetingManifest(id: note.id, title: note.title, startedAt: note.startedAt, selectedLanguages: [.german],
                               sourcePlatform: .file, sourceFile: file)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MeetingManifest.self, from: encoder.encode(note)).sourceFile, file)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(note)) as? [String: Any])
        json.removeValue(forKey: "sourceFile")
        let old = try decoder.decode(MeetingManifest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.sourceFile)
    }

    private func readDocx(_ data: Data) throws -> NSAttributedString {
        try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                               documentAttributes: nil)
    }
}

final class PCMWaveTests: XCTestCase {
    func testHeaderDescribesSixteenKilohertzMonoSixteenBit() {
        let data = PCMWave.data(samples: [0, 0.5, -0.5, 1, -1], sampleRate: 16_000)

        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(data.count, 44 + 5 * 2)
        func le32(_ offset: Int) -> UInt32 { data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        func le16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
        XCTAssertEqual(le32(4), UInt32(data.count - 8))
        XCTAssertEqual(le16(20), 1)
        XCTAssertEqual(le16(22), 1)
        XCTAssertEqual(le32(24), 16_000)
        XCTAssertEqual(le32(28), 32_000)
        XCTAssertEqual(le16(34), 16)
        XCTAssertEqual(le32(40), 10)
    }

    func testSamplesAreClippedRatherThanWrapped() {
        let data = PCMWave.data(samples: [2, -2], sampleRate: 16_000)
        let loud = Int16(bitPattern: UInt16(data[44]) | UInt16(data[45]) << 8)
        let low = Int16(bitPattern: UInt16(data[46]) | UInt16(data[47]) << 8)
        XCTAssertEqual(loud, Int16.max)
        XCTAssertEqual(low, -Int16.max)
    }

    func testAPassageOfTheOriginalFileIsDecodedFromItsTimeRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = 160_000
        let pointer = try XCTUnwrap(buffer.floatChannelData?[0])
        // Silence for five seconds, then a tone: the range must start inside the tone.
        for index in 0..<160_000 { pointer[index] = index < 80_000 ? 0 : 0.5 * sin(Float(index) * 0.1) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

        let samples = try await FileFragmentPlayer.decode(url: url, startFrame: 96_000, endFrame: 112_000)

        XCTAssertEqual(samples.count, 16_000, accuracy: 400)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.3)
    }

    @MainActor
    func testReplayOfAMovedFileIsAnErrorNotSilence() async {
        let player = FileFragmentPlayer()
        let gone = MeetingSourceFile(name: "x.m4a", path: "/nonexistent/x.m4a", durationSeconds: 10)
        do {
            try await player.play(file: gone, startFrame: 0, endFrame: 16_000)
            XCTFail("a missing file cannot be played")
        } catch {
            XCTAssertEqual(error as? FragmentReplayError, .fileMissing)
        }
    }
}

@MainActor
final class FileTranscriptionCoordinatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOnlyAudioAndVideoTypesAreAccepted() {
        let (coordinator, _, _) = make()
        for name in ["a.m4a", "a.MP3", "a.wav", "a.aiff", "a.aif", "a.caf", "a.mp4", "a.mov"] {
            XCTAssertTrue(coordinator.accepts(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.pdf", "a.docx", "a.txt", "a"] {
            XCTAssertFalse(coordinator.accepts(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        XCTAssertFalse(coordinator.accepts(URL(string: "https://example.com/a.mp3")!), "a link is not a file")
    }

    func testAFinishedFileOpensItsNoteCountsAsUseAndFreesTheEngine() async throws {
        let (coordinator, host, engine) = make()
        engine.setResult(transcript("Text."))
        var opened: [UUID] = []
        coordinator.openResult = { opened.append($0) }

        coordinator.start(url: URL(fileURLWithPath: "/tmp/interview.m4a"))
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertTrue(host.fileRunning, "dictation must be told before the first window is recognised")
        try await waitUntil { !coordinator.isRunning }

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(opened.count, 1)
        XCTAssertFalse(host.fileRunning)
        XCTAssertEqual(host.producedText, 1)
        let notes = try await FileMeetingStore(rootURL: root).listMeetings()
        XCTAssertEqual(notes.map(\.id), opened)
        XCTAssertEqual(notes.first?.sourceFile?.name, "interview.m4a")
        XCTAssertEqual(notes.first?.title, "interview")
    }

    func testTelemetryReportsStartThenCompletionWithALengthBucketAndNothingElse() async throws {
        let (coordinator, host, engine) = make()
        engine.setResult(transcript("Text."))

        coordinator.start(url: URL(fileURLWithPath: "/tmp/secret-name.m4a"))
        try await waitUntil { !coordinator.isRunning }

        XCTAssertEqual(host.events, [.fileTranscriptionStarted, .fileTranscriptionCompleted(.underFiveMinutes)])
        for event in host.events {
            XCTAssertTrue(event.isTransmitted)
            XCTAssertFalse((event.qualifier ?? "").contains("secret"))
        }
    }

    func testTelemetryReportsAFailureKindButNeverACancelOrARefusal() async throws {
        let (failing, failingHost, _) = make(source: { _ in ScriptedFileSource(openError: .protectedContent) })
        failing.start(url: URL(fileURLWithPath: "/tmp/a.m4a"))
        try await waitUntil { !failing.isRunning }
        XCTAssertEqual(failingHost.events, [.fileTranscriptionStarted, .fileTranscriptionFailed(.protectedContent)])

        let (refused, refusedHost, _) = make()
        refused.start(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        refusedHost.dictationBusy = true
        refused.dismissFailure()
        refused.start(url: URL(fileURLWithPath: "/tmp/a.m4a"))
        XCTAssertEqual(refusedHost.events, [], "a refusal happens before a file is touched")
        XCTAssertNil(FileTranscriptionFailure.cancelled.telemetryReason)
    }

    func testFileLengthBucketsAndFailureKindsAreClosedSets() {
        XCTAssertEqual(TelemetryEvent.FileLength(seconds: 299), .underFiveMinutes)
        XCTAssertEqual(TelemetryEvent.FileLength(seconds: 300), .underThirtyMinutes)
        XCTAssertEqual(TelemetryEvent.FileLength(seconds: 3_600), .underTwoHours)
        XCTAssertEqual(TelemetryEvent.FileLength(seconds: 10_800), .overTwoHours)
        XCTAssertEqual(TelemetryEvent.FileFailure.allCases.count, 7)
    }

    func testWhileTheModelCompilesTheWindowHasTheStepAndAClockThatStopsAtTheFirstPassage() async throws {
        // The coordinator holds its host weakly, so the test has to hold it.
        let (coordinator, host, engine) = make()
        defer { withExtendedLifetime(host) {} }
        engine.setResult(transcript("Text."))
        engine.setModelState(.preparing(ModelPreparation(phase: .compilingForThisSystem)))
        let gate = engine.blockNextPreparation()

        coordinator.start(url: URL(fileURLWithPath: "/tmp/interview.m4a"))
        try await waitUntil("the model wait to appear") { coordinator.modelWait != nil }
        let wait = try XCTUnwrap(coordinator.modelWait)
        XCTAssertEqual(wait.preparation.phase, .compilingForThisSystem)
        XCTAssertNil(wait.fraction, "Core ML reports no percentage, so none is invented")
        XCTAssertTrue(wait.message.contains("macOS"))

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(coordinator.modelWait?.since, wait.since, "the clock keeps its start while the step lasts")

        gate.open()
        try await waitUntil("the run to finish") { !coordinator.isRunning }
        XCTAssertNil(coordinator.modelWait)
    }

    func testADownloadInFlightShowsARealFraction() {
        let wait = FileModelWait(preparation: ModelPreparation(phase: .downloading, progress: 0.4), since: Date())
        XCTAssertEqual(wait.fraction ?? 0, 0.4, accuracy: 0.001)
        XCTAssertNil(FileModelWait(preparation: ModelPreparation(phase: .loading), since: Date()).fraction)
    }

    func testAModelThatIsAlreadyPreparingIsJoinedNotRefused() async throws {
        let (coordinator, host, engine) = make()
        engine.setResult(transcript("Text."))
        engine.setModelState(.preparing(ModelPreparation(phase: .loading)))

        coordinator.start(url: URL(fileURLWithPath: "/tmp/a.m4a"))
        try await waitUntil { !coordinator.isRunning }

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(host.producedText, 1)
        XCTAssertGreaterThanOrEqual(engine.prepareCount, 1)
    }

    func testALockedMacShowsThePaywallAndRunsNothing() {
        let (coordinator, host, engine) = make()
        host.locked = true

        coordinator.start(url: URL(fileURLWithPath: "/tmp/a.m4a"))

        XCTAssertEqual(host.paywallRequests, 1)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(host.fileRunning)
        XCTAssertEqual(engine.transcribeCount, 0)
    }

    func testARunningDictationOrMeetingRefusesTheFile() {
        let (coordinator, host, _) = make()
        host.dictationBusy = true
        coordinator.start(url: URL(fileURLWithPath: "/tmp/a.m4a"))
        XCTAssertEqual(coordinator.phase, .failed(.busy))

        coordinator.dismissFailure()
        host.dictationBusy = false
        host.meetingActive = true
        coordinator.start(url: URL(fileURLWithPath: "/tmp/a.m4a"))
        XCTAssertEqual(coordinator.phase, .failed(.busy))
    }

    func testUnsupportedTypeAndMissingEngineAreNamedFailures() {
        let (coordinator, host, _) = make()
        coordinator.start(url: URL(fileURLWithPath: "/tmp/a.pdf"))
        XCTAssertEqual(coordinator.phase, .failed(.unsupportedType))

        coordinator.dismissFailure()
        host.engine = nil
        coordinator.start(url: URL(fileURLWithPath: "/tmp/a.m4a"))
        XCTAssertEqual(coordinator.phase, .failed(.modelUnavailable))
    }

    func testUnreadableFileEndsInAFailureThatNamesTheKindOfProblemOnly() async throws {
        let (coordinator, host, _) = make(source: { _ in ScriptedFileSource(openError: .noAudioTrack) })

        coordinator.start(url: URL(fileURLWithPath: "/tmp/silent.mov"))
        try await waitUntil { !coordinator.isRunning }

        XCTAssertEqual(coordinator.phase, .failed(.file(.noAudioTrack)))
        XCTAssertFalse(coordinator.phase == .idle)
        XCTAssertFalse(host.fileRunning)
        XCTAssertEqual(host.producedText, 0)
        XCTAssertFalse(FileTranscriptionFailure.file(.noAudioTrack).message.contains("silent"), "the message never carries the file name")
    }

    func testCancellingReturnsToIdleWithoutANoteOrAFailure() async throws {
        let (coordinator, host, engine) = make()
        engine.setResult(transcript("Text."))
        let gate = engine.blockNextTranscription()
        var opened = 0
        coordinator.openResult = { _ in opened += 1 }

        coordinator.start(url: URL(fileURLWithPath: "/tmp/long.m4a"))
        try await waitUntil { engine.transcribeCount > 0 }
        coordinator.cancel()
        gate.open()
        try await waitUntil { !coordinator.isRunning }

        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(host.fileRunning)
        let notes = try await FileMeetingStore(rootURL: root).listMeetings()
        XCTAssertTrue(notes.isEmpty)
    }

    func testEveryFailureHasAMessageThatIsNotEmpty() {
        let all: [FileTranscriptionFailure] = [
            .file(.unreadable), .file(.noAudioTrack), .file(.protectedContent), .file(.empty),
            .modelUnavailable, .recognitionStopped, .storageFailed, .cancelled, .unsupportedType, .busy,
        ]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
        XCTAssertTrue(all.allSatisfy { !$0.message.isEmpty })
    }

    // MARK: -

    private func make(source: @escaping (URL) -> any AudioFileReading = { _ in ScriptedFileSource() })
        -> (FileTranscriptionCoordinator, FakeFileHost, FakeTranscriptionService) {
        let engine = FakeTranscriptionService()
        let host = FakeFileHost(engine: engine)
        let coordinator = FileTranscriptionCoordinator(
            host: host, store: FileMeetingStore(rootURL: root), makeSource: source
        )
        return (coordinator, host, engine)
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(text: text, tokens: [], profile: .english, detectedLanguage: .english,
                   audioDuration: 1, processingDuration: 0, engineIdentifier: "fake")
    }

    private func waitUntil(_ what: String = "the condition", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class FakeFileHost: FileTranscriptionHost {
    var engine: (any TranscriptionService)?
    var locked = false
    var dictationBusy = false
    var meetingActive = false
    private(set) var paywallRequests = 0
    private(set) var fileRunning = false
    private(set) var producedText = 0

    init(engine: any TranscriptionService) { self.engine = engine }

    var sharedEngine: (any TranscriptionService)? { engine }
    var languageProfile: LanguageProfile { .english }
    var isDictationBusy: Bool { dictationBusy }
    var isLocked: Bool { locked }
    var isMeetingActive: Bool { meetingActive }
    func showPaywall() { paywallRequests += 1 }
    func setFileRunning(_ running: Bool) { fileRunning = running }
    func noteFileProducedText() { producedText += 1 }
    private(set) var events: [TelemetryEvent] = []
    func report(_ event: TelemetryEvent) { events.append(event) }
}

/// Two minutes of tone with a pause every ten seconds, or a named open failure.
private final class ScriptedFileSource: AudioFileReading, @unchecked Sendable {
    private let openError: AudioFileError?
    private let lock = NSLock()
    private var delivered = 0

    init(openError: AudioFileError? = nil) { self.openError = openError }

    func open() async throws -> AudioFileInfo {
        if let openError { throw openError }
        return AudioFileInfo(estimatedFrames: 120 * 16_000)
    }

    func nextChunk() throws -> MeetingAudioChunk? {
        lock.withLock {
            guard delivered < 120 else { return nil }
            let second = delivered
            delivered += 1
            let samples = (0..<16_000).map { second % 11 == 10 ? Float(0) : ($0.isMultiple(of: 2) ? 0.2 : -0.2) }
            return MeetingAudioChunk(source: .system, sequence: UInt64(second), startFrame: Int64(second) * 16_000,
                                     sampleRate: 16_000, samples: samples, isFinal: delivered == 120)
        }
    }

    func close() {}
}

@MainActor
final class FilePressDuringTranscriptionTests: XCTestCase {
    func testAPressWhileAFileRunsRecordsNothingAndSaysWhy() async throws {
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: FakeTranscriptionService()
        )
        coordinator.activate()
        coordinator.setFileTranscriptionRunning(true)

        hotkey.emit(.pressed)
        hotkey.emit(.released)

        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(coordinator.speechModelNotice, .transcribingFile)

        coordinator.setFileTranscriptionRunning(false)
        XCTAssertNil(coordinator.speechModelNotice, "the notice goes when the file is done")

        hotkey.emit(.pressed)
        let deadline = Date().addingTimeInterval(5)
        while capture.startCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(capture.startCount, 1, "dictation works again afterwards")
    }

    func testTheNoticeNamesNoContent() {
        XCTAssertEqual(SpeechModelNotice.transcribingFile.logLabel, "model:busyWithFile")
        XCTAssertFalse(SpeechModelNotice.transcribingFile.message.isEmpty)
    }
}

@MainActor
final class FileTranscriptionCompositionTests: XCTestCase {
    private func compose(_ availability: FileTranscriptionAvailability) -> ApplicationComposition {
        ApplicationComposition.make(
            notetakerAvailability: .disabled,
            fileTranscriptionAvailability: availability,
            makeDictationCoordinator: {
                DictationCoordinator(
                    permissionService: FakeMicrophonePermissionService(authorization: .authorized),
                    hotkeyService: FakeHotkeyService(),
                    captureService: FakeAudioCaptureService(),
                    transcriptionService: FakeTranscriptionService()
                )
            },
            makeAvailableNotetaker: { _ in UnavailableNotetakerFacade() }
        )
    }

    func testADisabledBuildConstructsNoFileFeatureAndTheMeetingGateStaysOff() {
        let composition = compose(.disabled)
        XCTAssertNil(composition.fileTranscription)
        XCTAssertNil(composition.notetaker.menuBarItem, "file transcription must not switch the meeting feature on")
    }

    func testAnEnabledBuildHasFilesWithoutHavingMeetings() {
        let composition = compose(.enabled)
        XCTAssertNotNil(composition.fileTranscription)
        XCTAssertNil(composition.notetaker.menuBarItem)
        XCTAssertNil(composition.notetaker.historyMenuItem)
        XCTAssertEqual(NotetakerAvailability.liveDefault, .disabled)
    }
}
