import XCTest
@testable import Witness

/// The queue that lets dictation and the Notetaker share one loaded speech
/// model. A dictation and a meeting window must never run on the engine at
/// once, and neither may be skipped or reordered.
final class InferenceTurnsTests: XCTestCase {
    func testSavedModelSelectionAndUnknownValues() throws {
        let suite = "WitnessModelSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DictationEngineChoice.saved(in: defaults), .whisper)
        for choice in DictationEngineChoice.allCases {
            defaults.set(choice.rawValue, forKey: DictationEngineChoice.defaultsKey)
            XCTAssertEqual(DictationEngineChoice.saved(in: defaults), choice)
        }
        defaults.set("unknown-model", forKey: DictationEngineChoice.defaultsKey)
        XCTAssertEqual(DictationEngineChoice.saved(in: defaults), .whisper)
    }

    func testBothWhisperSelectionsShareOneEngineAndKeepMeetingContextSeparate() throws {
        for choice in [DictationEngineChoice.whisper, .whisperLarge] {
            let clients = choice.makeClients()
            let dictation = try XCTUnwrap(clients.dictation as? WhisperKitTranscriptionService)
            let meeting = try XCTUnwrap(clients.meeting as? WhisperKitMeetingClient)
            XCTAssertTrue(meeting.service === dictation)
            XCTAssertEqual(dictation.displayName, choice.title)
        }
        XCTAssertNotEqual(DictationEngineChoice.fullWhisperVariant, WhisperKitTranscriptionService.defaultModelVariant)
    }

    func testBothParakeetSelectionsShareOneEngineAcrossEntryPoints() throws {
        for choice in [DictationEngineChoice.parakeetUltra, .parakeetV3] {
            let clients = choice.makeClients()
            let dictation = try XCTUnwrap(clients.dictation as? ParakeetTranscriptionService)
            let meeting = try XCTUnwrap(clients.meeting as? ParakeetTranscriptionService)
            XCTAssertTrue(meeting === dictation)
            XCTAssertEqual(dictation.identifier, choice.rawValue)
        }
    }

    func testParakeetDoesNotPretendToSupportAllWhisperLanguages() {
        for choice in DictationEngineChoice.allCases {
            XCTAssertTrue(choice.supports(LanguageProfile(.russian, .english, .ukrainian, .german)))
        }
        let unsupported = LanguageProfile(SpeechLanguage(rawValue: "ja")!)
        XCTAssertFalse(DictationEngineChoice.parakeetUltra.supports(unsupported))
        XCTAssertFalse(DictationEngineChoice.parakeetV3.supports(unsupported))
        XCTAssertTrue(DictationEngineChoice.whisper.supports(unsupported))
        XCTAssertTrue(DictationEngineChoice.whisperLarge.supports(unsupported))
    }

    func testRestartCannotInterruptEitherRecording() {
        for state in [RecordingState.starting, .recording, .finishing, .transcribing, .inserting] {
            XCTAssertFalse(DictationEngineChoice.allowsRestart(dictation: state, meetingIsActive: false))
        }
        XCTAssertFalse(DictationEngineChoice.allowsRestart(dictation: .ready, meetingIsActive: true))
        XCTAssertTrue(DictationEngineChoice.allowsRestart(dictation: .ready, meetingIsActive: false))
    }

    func testInstalledTurboThroughBothEntryPoints() async throws { try await smoke(.whisper) }
    func testInstalledFullLargeThroughBothEntryPoints() async throws { try await smoke(.whisperLarge) }
    func testInstalledParakeetUltraThroughBothEntryPoints() async throws { try await smoke(.parakeetUltra) }
    func testInstalledParakeetV3ThroughBothEntryPoints() async throws { try await smoke(.parakeetV3) }

    /// Explicitly opt-in: uses synthetic local corpus audio and installed weights
    /// only. Both callers arrive together to exercise the shared inference queue.
    private func smoke(_ choice: DictationEngineChoice) async throws {
        guard let path = ProcessInfo.processInfo.environment["WITNESS_MODEL_SMOKE_CORPUS"] else {
            throw XCTSkip("Set WITNESS_MODEL_SMOKE_CORPUS to a local synthetic corpus to test installed models")
        }
        executionTimeAllowance = 600
        let directory = URL(fileURLWithPath: path)
        let corpus = try BenchmarkCorpus.load(from: directory)
        let sample = try XCTUnwrap(corpus.samples.first { $0.language == .english })
        let utterance = try corpus.utterance(for: sample, in: directory)
        let clients = choice.makeClients()
        let state = await clients.dictation.modelState(for: sample.languageProfile)
        guard state.isReady || state.canPrepareUnattended else {
            throw XCTSkip("Selected model is not installed; this smoke test never downloads weights")
        }
        try await clients.dictation.prepare(for: sample.languageProfile)
        async let first = clients.dictation.transcribe(utterance, profile: sample.languageProfile)
        async let second = clients.meeting.transcribe(utterance, profile: sample.languageProfile)
        let (dictation, meeting) = try await (first, second)
        XCTAssertFalse(dictation.text.isEmpty)
        XCTAssertFalse(dictation.tokens.isEmpty)
        XCTAssertEqual(dictation.text, meeting.text)
        XCTAssertEqual(dictation.engineIdentifier, clients.dictation.identifier)
        XCTAssertEqual(meeting.engineIdentifier, clients.dictation.identifier)
        for token in meeting.tokens {
            XCTAssertGreaterThanOrEqual(token.start, 0)
            XCTAssertGreaterThanOrEqual(token.end, token.start)
        }
    }

    func testTheFirstCallerRunsAtOnce() {
        var turns = InferenceTurns<String>()

        XCTAssertTrue(turns.enter())
        XCTAssertTrue(turns.isBusy)
    }

    func testLaterCallersWaitAndRunInArrivalOrder() {
        var turns = InferenceTurns<String>()
        XCTAssertTrue(turns.enter(), "A meeting window takes the engine")

        XCTAssertFalse(turns.enter())
        turns.wait("dictation")
        XCTAssertFalse(turns.enter())
        turns.wait("next window")
        XCTAssertEqual(turns.waitingCount, 2)

        XCTAssertEqual(turns.leave(), "dictation")
        XCTAssertTrue(turns.isBusy, "The turn passes on without the engine going idle in between")
        XCTAssertEqual(turns.leave(), "next window")
        XCTAssertNil(turns.leave())
        XCTAssertFalse(turns.isBusy)
    }

    func testAFreedEngineIsTakenWithoutWaiting() {
        var turns = InferenceTurns<String>()
        XCTAssertTrue(turns.enter())
        XCTAssertNil(turns.leave())

        XCTAssertTrue(turns.enter())
        XCTAssertEqual(turns.waitingCount, 0)
    }

    func testTheMeetingClientUsesTheDictationEngine() {
        let speech = WhisperKitTranscriptionService()
        let client = speech.meetingClient

        XCTAssertTrue(client.service === speech, "A second engine would load the model a second time")
        XCTAssertEqual(client.identifier, speech.identifier)
    }
}
