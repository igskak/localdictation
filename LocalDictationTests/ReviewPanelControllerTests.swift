import AppKit
import XCTest
@testable import LocalDictation

/// Drives the floating panel through real AppKit layout.
///
/// This exists because the first version of the panel crashed the app the first
/// time a review appeared, and every unit test still passed. The panel resized
/// its own window from inside the layout pass — an `NSHostingController` with
/// `sizingOptions` — while the controller forced another layout pass to
/// position it, and AppKit eventually threw
/// "more Update Constraints in Window passes than there are views in the
/// window". Nothing that avoids a window can catch that, so this test uses one.
///
/// An AppKit exception here takes the test process down rather than failing
/// politely. That is the point: a crash in the suite is a crash caught before
/// the user sees it.
@MainActor
final class ReviewPanelControllerTests: XCTestCase {
    private struct Harness {
        let coordinator: DictationCoordinator
        let hotkey: FakeHotkeyService
        let controller: ReviewPanelController
    }

    private func makeHarness(transcript: Transcript) -> Harness {
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
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: engine,
            glossaryStore: InMemoryGlossaryStore(.empty),
            fragmentPlayer: FakeAudioFragmentPlayer(),
            accessibilityService: FakeAccessibilityPermissionService(authorization: .trusted),
            insertionService: FakeTextInsertionService(),
            languageProfile: .german
        )
        let controller = ReviewPanelController(coordinator: coordinator)
        coordinator.activate()
        return Harness(coordinator: coordinator, hotkey: hotkey, controller: controller)
    }

    /// Lets AppKit run the display cycle the exception would be thrown in.
    private func settle(_ turns: Int = 6) async throws {
        for _ in 0..<turns {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static let riskyTranscript = Transcript.fixture(
        text: "bitte überweise 1450 euro an frau schneider",
        profile: .german,
        secondsPerWord: 0.2
    )

    private static let quietTranscript = Transcript.fixture(
        text: "der bericht ist fertig",
        profile: .german,
        secondsPerWord: 0.2
    )

    func testAReviewPanelSurvivesBeingShownAndResized() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }
        harness.coordinator.openReview()
        try await waitUntil("panel is on screen") { harness.controller.isShowingReviewPanel }
        try await settle()

        let size = try XCTUnwrap(harness.controller.reviewPanelContentSize)
        XCTAssertGreaterThan(size.height, 40, "a collapsed panel means the content was measured too early")
        XCTAssertGreaterThan(size.width, 400)

        // The one thing that changes the panel's height while it is open, and
        // therefore the path that resizes a window that is already on screen.
        harness.coordinator.prefersRawTranscript = true
        try await settle()
        harness.coordinator.prefersRawTranscript = false
        try await settle()

        XCTAssertTrue(harness.controller.isShowingReviewPanel)
    }

    func testThePanelGoesAwayWhenTheReviewEnds() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("attention is offered") { harness.coordinator.attentionIsPending }
        harness.coordinator.openReview()
        try await waitUntil("panel is on screen") { harness.controller.isShowingReviewPanel }
        try await settle()

        harness.coordinator.closeReview()
        try await waitUntil("panel is gone") { !harness.controller.isShowingReviewPanel }
    }

    /// The review must never appear on its own. Everything this phase is for
    /// rests on that: the text goes in, and the panel waits to be asked.
    func testNoPanelAppearsOnItsOwnHoweverRiskyTheTextIs() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }
        try await settle()

        XCTAssertTrue(harness.coordinator.attentionIsPending, "the indicator is lit")
        XCTAssertFalse(harness.controller.isShowingReviewPanel, "but the review is not open")
    }

    /// The chip is the same machinery as the notice, in the same corner, and
    /// the same AppKit crash was available to it.
    func testTheAttentionChipSurvivesBeingShown() async throws {
        let harness = makeHarness(transcript: Self.riskyTranscript)

        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("chip is on screen") { harness.controller.isShowingNotice }
        try await settle()

        XCTAssertTrue(harness.controller.isShowingNotice)
    }

    /// A successful insertion with nothing flagged says nothing at all.
    func testAQuietResultShowsNoPanelOfAnyKind() async throws {
        let harness = makeHarness(transcript: Self.quietTranscript)
        harness.hotkey.emit(.pressed)
        harness.hotkey.emit(.released)
        try await waitUntil("insertion finished") { harness.coordinator.lastInsertion != nil }
        try await settle()

        XCTAssertFalse(harness.coordinator.attentionIsPending)
        XCTAssertFalse(harness.controller.isShowingNotice)
        XCTAssertFalse(harness.controller.isShowingReviewPanel)
    }
}
