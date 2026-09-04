import XCTest
@testable import Witness

/// The Phase 4 slice with fakes: a result that needs no review lands in the
/// application the user was typing in, a review stands in front of that, and
/// every path that cannot insert says where the text went instead.
///
/// No Accessibility call, no synthetic key event, and no write to the real
/// pasteboard happens anywhere in this file.
@MainActor
final class DictationCoordinatorInsertionTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let insertion: FakeTextInsertionService
        let accessibility: FakeAccessibilityPermissionService
    }

    private func makeHarness(
        transcript: Transcript,
        trust: AccessibilityAuthorization = .trusted
    ) -> Harness {
        let engine = FakeTranscriptionService()
        engine.setResult(transcript)
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        capture.setSnapshot(
            CaptureSnapshot(
                frameCount: 16_000,
                capacityFrames: 1_920_000,
                peakLevel: 0.42,
                sampleRate: AudioTargetFormat.sampleRate
            )
        )
        let accessibility = FakeAccessibilityPermissionService(authorization: trust)
        let insertion = FakeTextInsertionService()

        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: engine,
            glossaryStore: InMemoryGlossaryStore(.empty),
            fragmentPlayer: FakeAudioFragmentPlayer(),
            accessibilityService: accessibility,
            insertionService: insertion,
            languageProfile: .german
        )
        coordinator.activate()
        return Harness(coordinator: coordinator, hotkey: hotkey, insertion: insertion, accessibility: accessibility)
    }

    private func record(_ harness: Harness) {
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
    }

    /// Nothing worth checking: no amount, no name, no removed word.
    private static let quietTranscript = Transcript.fixture(
        text: "der termin steht",
        profile: .german,
        secondsPerWord: 0.2
    )
    /// Carries an amount, which is exactly what earns a review.
    private static let riskyTranscript = Transcript.fixture(
        text: "bitte überweise 1450 euro",
        profile: .german,
        secondsPerWord: 0.2
    )

    // MARK: - The quiet path is the phase

    func testAResultWithNothingWorthCheckingGoesStraightIntoTheTarget() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        XCTAssertEqual(harness.insertion.insertCount, 1)
        XCTAssertEqual(harness.insertion.insertedText, "Der termin steht.")
        XCTAssertEqual(harness.coordinator.lastInsertion, .inserted(.focusedElement))
        XCTAssertEqual(harness.coordinator.state, .ready)
        XCTAssertNil(
            harness.coordinator.lastInsertion?.message,
            "an insertion that worked must not put a sentence in front of the user"
        )
    }

    /// The decision that makes a wrong target impossible: the application is
    /// captured when the recording starts, before transcription and review had
    /// any chance to let the user move on.
    func testTheTargetIsCapturedWhenRecordingStartsNotWhenInserting() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)
        let captured = InsertionTarget(
            processIdentifier: 902,
            bundleIdentifier: "com.example.notes",
            applicationName: "Notes"
        )
        harness.insertion.targetToCapture = captured

        harness.hotkey.emit(.pressed)
        XCTAssertEqual(harness.insertion.captureCount, 1, "the target is read on the way in")
        // Whatever is in front now is irrelevant: the target was already taken.
        harness.insertion.targetToCapture = InsertionTarget(
            processIdentifier: 903,
            bundleIdentifier: "com.example.terminal",
            applicationName: "Terminal"
        )
        harness.hotkey.emit(.released)

        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }
        XCTAssertEqual(harness.insertion.lastAttempt?.target, captured)
    }

    func testAudioIsStillReleasedAtTheDecisionWhenTheTextIsInserted() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        XCTAssertFalse(harness.coordinator.hasRetainedAudio)
        XCTAssertEqual(harness.coordinator.retainedAudioFrameCount, 0)
    }

    // MARK: - Risk marks no longer stand in front of insertion

    /// The whole of Phase 5 in one test. A result carrying an amount used to
    /// wait for a panel to be answered; now it goes into the document and the
    /// checking is offered afterwards, to whoever wants it.
    func testAFlaggedResultIsInsertedWithoutWaitingForAnybody() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        XCTAssertEqual(harness.insertion.insertCount, 1)
        XCTAssertEqual(harness.insertion.insertedText, "Bitte überweise 1450 euro.")
        XCTAssertEqual(harness.coordinator.state, .ready)
        XCTAssertTrue(harness.coordinator.attentionIsPending, "the offer to check outlives the insertion")
        XCTAssertFalse(harness.coordinator.isShowingReview, "and it is an offer, not a window")
    }

    /// The cleaned text is what lands, always. The raw transcript is something
    /// the review can show and copy, and it is no longer able to change what
    /// went into the document — by the time anyone can ask for it, the text is
    /// already there.
    func testTheReviewCannotChangeWhatWasInserted() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        harness.coordinator.openReview()
        harness.coordinator.prefersRawTranscript = true
        harness.coordinator.closeReview()

        XCTAssertEqual(harness.insertion.insertCount, 1, "a review must never insert a second time")
        XCTAssertEqual(harness.insertion.insertedText, "Bitte überweise 1450 euro.")
    }

    /// A flagged result keeps its recording, because the review it offers may
    /// replay a fragment. That is the one place Phase 5 holds audio longer than
    /// Phase 3 did, and it is bounded by the review rather than unbounded.
    func testAFlaggedResultKeepsItsAudioAfterInsertion() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        XCTAssertTrue(harness.coordinator.hasRetainedAudio)
        XCTAssertTrue(harness.coordinator.canReplayFragments)
    }

    // MARK: - When automatic insertion is switched off

    func testWithAutomaticInsertionOffTheResultWaitsForTheUser() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)
        harness.coordinator.insertsAutomatically = false

        record(harness)
        try await waitUntil("result is published") { harness.coordinator.result != nil }

        XCTAssertEqual(harness.insertion.insertCount, 0)
        XCTAssertEqual(harness.coordinator.state, .ready)
        XCTAssertTrue(harness.coordinator.hasInsertableResult)

        harness.coordinator.insertCurrentResult()
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        XCTAssertEqual(harness.insertion.insertCount, 1)
        XCTAssertEqual(harness.insertion.insertedText, "Der termin steht.")
    }

    // MARK: - Outcomes the user is told about

    func testAnUntrustedInsertionSurfacesTheClipboardOutcome() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript, trust: .notTrusted)
        harness.insertion.outcome = .copiedToClipboard(.notTrusted)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        XCTAssertEqual(harness.coordinator.lastInsertion, .copiedToClipboard(.notTrusted))
        XCTAssertNotNil(harness.coordinator.lastInsertion?.message)
        XCTAssertTrue(harness.coordinator.needsAccessibilityTrust)
        XCTAssertEqual(harness.coordinator.state, .ready)
    }

    func testARefusalIsReportedAndLeavesTheTextInTheApp() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)
        harness.insertion.outcome = .refused(.secureField)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        XCTAssertEqual(harness.coordinator.lastInsertion, .refused(.secureField))
        XCTAssertFalse(harness.coordinator.lastInsertion?.isOnClipboard ?? true)
        XCTAssertNotNil(harness.coordinator.result, "the text stays here so the user can act on it")
    }

    func testDictatingWithNoOtherApplicationInFrontStillReachesTheService() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)
        harness.insertion.targetToCapture = nil
        harness.insertion.outcome = .copiedToClipboard(.noTarget)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        XCTAssertNil(harness.insertion.lastAttempt?.target)
        XCTAssertEqual(harness.coordinator.lastInsertion, .copiedToClipboard(.noTarget))
    }

    // MARK: - Superseding

    /// The paste path posts a key event and then waits for the target to read
    /// the pasteboard. A hotkey press inside that window starts the next
    /// dictation, and the outcome of the superseded one must never be reported:
    /// it describes a recording the user has already abandoned.
    func testANewDictationSupersedesAnInsertionStillSettling() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)
        let gate = AsyncGate()
        harness.insertion.gate = gate

        record(harness)
        try await waitUntil("insertion started") { harness.coordinator.state == .inserting }

        harness.hotkey.emit(.pressed)
        XCTAssertEqual(harness.coordinator.state, .starting)

        gate.open()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(
            harness.coordinator.lastInsertion,
            "the outcome of a superseded insertion must not be reported"
        )
    }

    // MARK: - Privacy

    /// Phase 3's rule was that no recognized word reaches a log line. Phase 4
    /// adds a second thing that must never be logged: what was typed into the
    /// other application. The identity of the application may be — a bundle
    /// identifier is not content, and compatibility cannot be debugged without
    /// it — but nothing derived from the utterance may travel with it.
    func testDiagnosticsRecordWhereTheTextWentAndNeverWhatItWas() async throws {
        let transcript = Transcript.fixture(
            text: "vertraulicher satz über etwas privates",
            profile: .german,
            secondsPerWord: 0.2
        )
        let harness = makeHarness(transcript: transcript)

        record(harness)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }

        let diagnostics = try XCTUnwrap(harness.coordinator.diagnostics.lastInsertion)
        XCTAssertEqual(diagnostics.outcome, "inserted:focusedElement")
        XCTAssertEqual(diagnostics.targetIdentity, "com.example.editor")

        let recorded = [diagnostics.outcome, diagnostics.targetIdentity ?? ""].joined(separator: " ")
        for word in ["vertraulicher", "satz", "privates"] {
            XCTAssertFalse(recorded.localizedCaseInsensitiveContains(word), "\(word) must not reach diagnostics")
        }
    }

    /// The target carries an application's identity and nothing from inside it.
    func testAnInsertionTargetCarriesNoContent() {
        let target = InsertionTarget(
            processIdentifier: 77,
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor"
        )

        XCTAssertEqual(target.logIdentity, "com.example.editor")
        XCTAssertEqual(target.displayName, "Editor")
        XCTAssertEqual(
            InsertionTarget(processIdentifier: 77, bundleIdentifier: nil, applicationName: nil).logIdentity,
            "pid:77"
        )
    }

    // MARK: - Noticing the grant

    /// The grant happens in System Settings, out of band, and macOS says
    /// nothing about it. A menu bar app with no Dock icon cannot rely on being
    /// activated afterwards either, so it has to look for itself.
    func testTheGrantIsNoticedWithoutAnyUserActionInTheApp() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript, trust: .notTrusted)
        XCTAssertTrue(harness.coordinator.needsAccessibilityTrust)

        // The user goes to System Settings and turns it on. Nothing tells the
        // app; nobody comes back and clicks anything.
        harness.accessibility.set(.trusted)

        try await waitUntil("the app notices the grant on its own") {
            harness.coordinator.accessibilityAuthorization == .trusted
        }
        XCTAssertFalse(harness.coordinator.needsAccessibilityTrust)
    }

    /// And it stops looking once it has the answer, rather than asking forever.
    func testTheAppStopsWatchingOnceTrustIsGranted() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript, trust: .trusted)

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(harness.coordinator.needsAccessibilityTrust)
        XCTAssertFalse(harness.coordinator.isWatchingForAccessibilityTrust)
    }
}
