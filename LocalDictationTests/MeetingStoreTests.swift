import XCTest
@testable import Witness

final class MeetingStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testInitializationDoesNotCreateStorage() async {
        _ = FileMeetingStore(rootURL: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRoundTripUsesVersionedOwnerOnlyFilesAndNeverCreatesAudio() async throws {
        let store = FileMeetingStore(rootURL: root)
        let manifest = makeManifest()
        try await store.createMeeting(manifest)
        let first = makeRecord(text: "Hello", start: 0)
        let second = makeRecord(source: .system, text: "Привіт", start: 16_000)
        try await store.appendTranscript(first, meetingID: manifest.id)
        try await store.appendTranscript(second, meetingID: manifest.id)
        try await store.saveNotes(MeetingNotes(text: "Decision: ship locally."), meetingID: manifest.id)

        let loadedManifest = try await store.loadManifest(id: manifest.id)
        let loadedTranscript = try await store.loadTranscript(meetingID: manifest.id)
        let loadedNotes = try await store.loadNotes(meetingID: manifest.id)
        XCTAssertEqual(loadedManifest, manifest)
        XCTAssertEqual(loadedTranscript, [first, second])
        XCTAssertEqual(loadedNotes.text, "Decision: ship locally.")

        let directory = root.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        XCTAssertEqual(try permissions(directory), 0o700)
        for name in ["manifest.json", "transcript.ndjson", "notes.json"] {
            XCTAssertEqual(try permissions(directory.appendingPathComponent(name)), 0o600)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(names), Set(["manifest.json", "transcript.ndjson", "notes.json"]))
        XCTAssertFalse(names.contains { $0.localizedCaseInsensitiveContains("audio") || $0.hasSuffix(".wav") })
    }

    func testTornFinalLineIsIgnoredButCompleteCorruptionIsReported() async throws {
        let store = FileMeetingStore(rootURL: root)
        let manifest = makeManifest()
        let record = makeRecord(text: "kept", start: 0)
        try await store.createMeeting(manifest)
        try await store.appendTranscript(record, meetingID: manifest.id)
        let url = transcriptURL(manifest.id)
        try append(Data("{\"id\":".utf8), to: url)
        let recovered = try await store.loadTranscript(meetingID: manifest.id)
        XCTAssertEqual(recovered, [record])

        try Data("broken but complete\n".utf8).write(to: url, options: .atomic)
        do {
            _ = try await store.loadTranscript(meetingID: manifest.id)
            XCTFail("A corrupt complete line must not be hidden")
        } catch let MeetingStoreError.corruptTranscript(id, line) {
            XCTAssertEqual(id, manifest.id)
            XCTAssertEqual(line, 1)
        }
    }

    func testAppendOrderIsPreserved() async throws {
        let store = FileMeetingStore(rootURL: root)
        let manifest = makeManifest()
        try await store.createMeeting(manifest)
        let records = (0..<20).map { makeRecord(text: "row \($0)", start: Int64($0 * 16_000)) }
        for record in records { try await store.appendTranscript(record, meetingID: manifest.id) }
        let loaded = try await store.loadTranscript(meetingID: manifest.id)
        XCTAssertEqual(loaded, records)
    }

    func testUnknownFutureFieldsAreIgnored() async throws {
        let store = FileMeetingStore(rootURL: root)
        let manifest = makeManifest()
        try await store.createMeeting(manifest)

        let manifestURL = root.appendingPathComponent(manifest.id.uuidString).appendingPathComponent("manifest.json")
        var manifestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifestJSON["future_field"] = ["nested": true]
        try JSONSerialization.data(withJSONObject: manifestJSON).write(to: manifestURL, options: .atomic)
        let loadedManifest = try await store.loadManifest(id: manifest.id)
        XCTAssertEqual(loadedManifest, manifest)

        let record = makeRecord(text: "future-proof", start: 0)
        var recordJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        recordJSON["future_field"] = 42
        var line = try JSONSerialization.data(withJSONObject: recordJSON)
        line.append(0x0A)
        try line.write(to: transcriptURL(manifest.id), options: .atomic)
        let loadedTranscript = try await store.loadTranscript(meetingID: manifest.id)
        XCTAssertEqual(loadedTranscript, [record])
    }

    func testFutureSchemaIsRejected() async throws {
        let store = FileMeetingStore(rootURL: root)
        let manifest = makeManifest()
        try await store.createMeeting(manifest)
        let url = root.appendingPathComponent(manifest.id.uuidString).appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
        await XCTAssertThrowsErrorAsync(try await store.loadManifest(id: manifest.id)) { error in
            XCTAssertEqual(error as? MeetingStoreError, .unsupportedSchema(999))
        }
    }

    func testSearchMatchesTitleAndTranscriptWithoutCaseSensitivity() async throws {
        let store = FileMeetingStore(rootURL: root)
        let planning = makeManifest(title: "Launch Planning", startedAt: Date(timeIntervalSince1970: 10))
        let retro = makeManifest(title: "Weekly Retro", startedAt: Date(timeIntervalSince1970: 20))
        try await store.createMeeting(planning)
        try await store.createMeeting(retro)
        try await store.appendTranscript(makeRecord(text: "Budget approved", start: 0), meetingID: retro.id)

        let titleMatches = try await store.search("launch")
        XCTAssertEqual(titleMatches.map(\.manifest.id), [planning.id])
        let content = try await store.search("BUDGET")
        XCTAssertEqual(content.map(\.manifest.id), [retro.id])
        XCTAssertEqual(content.first?.matchingTranscriptIDs.count, 1)
        let all = try await store.search("")
        XCTAssertEqual(all.map(\.manifest.id), [retro.id, planning.id])
    }

    func testPlainTextAndMarkdownExportsKeepSourceAndTimestamp() async throws {
        let store = FileMeetingStore(rootURL: root)
        let manifest = makeManifest(title: "Local Call")
        try await store.createMeeting(manifest)
        try await store.appendTranscript(makeRecord(source: .microphone, text: "yes", start: 16_000), meetingID: manifest.id)
        try await store.appendTranscript(makeRecord(source: .system, text: "agreed", start: 32_000), meetingID: manifest.id)
        try await store.saveNotes(MeetingNotes(text: "No cloud."), meetingID: manifest.id)

        let text = try await store.export(meetingID: manifest.id, format: .plainText)
        XCTAssertTrue(text.contains("Local Call"))
        XCTAssertTrue(text.contains("[00:00:01] You: yes"))
        XCTAssertTrue(text.contains("[00:00:02] Others: agreed"))
        XCTAssertTrue(text.contains("Notes\nNo cloud."))

        let markdown = try await store.export(meetingID: manifest.id, format: .markdown)
        XCTAssertTrue(markdown.hasPrefix("# Local Call"))
        XCTAssertTrue(markdown.contains("## Notes\n\nNo cloud."))
    }

    func testDeleteRemovesEveryArtifact() async throws {
        let store = FileMeetingStore(rootURL: root)
        let manifest = makeManifest()
        try await store.createMeeting(manifest)
        try await store.appendTranscript(makeRecord(text: "private", start: 0), meetingID: manifest.id)
        let directory = root.appendingPathComponent(manifest.id.uuidString)
        try await store.deleteMeeting(id: manifest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let meetings = try await store.listMeetings()
        XCTAssertTrue(meetings.isEmpty)
    }

    func testFailedAtomicCreationLeavesNoPartialMeeting() async {
        let store = FileMeetingStore(rootURL: root, atomicWriter: { _, _ in throw TestFailure.expected })
        let manifest = makeManifest()
        await XCTAssertThrowsErrorAsync(try await store.createMeeting(manifest)) { error in
            XCTAssertEqual(error as? MeetingStoreError, .unwritable("atomicWrite"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(manifest.id.uuidString).path))
    }

    func testFailedAtomicReplacementPreservesPreviousManifest() async throws {
        let writer = AtomicWriteGate(failAtWrite: 3)
        let store = FileMeetingStore(rootURL: root, atomicWriter: writer.write)
        var manifest = makeManifest(title: "Original")
        try await store.createMeeting(manifest) // manifest + notes are writes one and two
        manifest.title = "Replacement"
        await XCTAssertThrowsErrorAsync(try await store.updateManifest(manifest))
        let loaded = try await store.loadManifest(id: manifest.id)
        XCTAssertEqual(loaded.title, "Original")
    }

    func testRecorderSurfacesAppendFailureWithoutDiscardingCallerRows() async throws {
        let store = FileMeetingStore(rootURL: root, appendWriter: { _, _ in throw TestFailure.expected })
        let recorder = MeetingPersistenceRecorder(store: store)
        let id = try await recorder.begin(title: "Failure", profile: .english, at: Date(timeIntervalSince1970: 0))
        let rows = [makeRow(text: "still visible")]
        await XCTAssertThrowsErrorAsync(try await recorder.persist(rows: rows))
        XCTAssertEqual(rows.map(\.text), ["still visible"])
        let stored = try await store.loadTranscript(meetingID: id)
        XCTAssertTrue(stored.isEmpty)
    }

    private enum TestFailure: Error { case expected }

    private func makeManifest(
        title: String = "Test Meeting",
        startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MeetingManifest {
        MeetingManifest(title: title, startedAt: startedAt, selectedLanguages: [.english], sourcePlatform: .manual)
    }

    private func makeRecord(
        source: MeetingAudioSource = .microphone,
        text: String,
        start: Int64
    ) -> MeetingTranscriptRecord {
        MeetingTranscriptRecord(
            source: source,
            speakerID: source == .microphone ? "you" : "others",
            startFrame: start,
            endFrame: start + 8_000,
            text: text,
            meanConfidence: 0.8,
            minimumConfidence: 0.7,
            hasConfidenceSignal: true
        )
    }

    private func makeRow(text: String) -> MeetingTranscriptRow {
        let transcript = Transcript.assemble(
            words: [.init(text, start: 0, end: 0.5, confidence: 0.8)],
            profile: .english,
            audioDuration: 0.5,
            processingDuration: 0.1,
            engineIdentifier: "test"
        )
        return MeetingTranscriptRow(source: .microphone, startFrame: 0, endFrame: 8_000, text: text, original: transcript)
    }

    private func transcriptURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("transcript.ndjson")
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        return value.intValue
    }
}

private final class AtomicWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private let failAtWrite: Int

    init(failAtWrite: Int) {
        self.failAtWrite = failAtWrite
    }

    func write(_ data: Data, to url: URL) throws {
        let shouldFail = lock.withLock {
            writes += 1
            return writes == failAtWrite
        }
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
