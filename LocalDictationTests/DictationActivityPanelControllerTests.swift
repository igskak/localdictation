import AppKit
import XCTest
@testable import Witness

@MainActor
final class DictationActivityPanelControllerTests: XCTestCase {
    private struct UnavailableCaret: TextCaretLocating {
        func caretRect(for processIdentifier: pid_t) -> CGRect? { nil }
    }

    func testVisibleRecordingContinuesAsProcessingThenEnds() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(Transcript.fixture(text: "der bericht ist fertig", profile: .german, secondsPerWord: 0.2))
        let gate = engine.blockNextTranscription()
        let hotkey = FakeHotkeyService()
        let capture = FakeAudioCaptureService()
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: hotkey,
            captureService: capture,
            transcriptionService: engine,
            glossaryStore: InMemoryGlossaryStore(.empty),
            insertionService: FakeTextInsertionService(),
            languageProfile: .german
        )
        let panel = DictationActivityPanelController(coordinator: coordinator, caretLocator: UnavailableCaret())
        coordinator.activate()

        hotkey.emit(.pressed)
        try await waitUntil("recording indicator") { coordinator.state == .recording && panel.isVisible }
        XCTAssertTrue(panel.passesClicksThrough)

        hotkey.emit(.released)
        try await waitUntil("processing indicator") { coordinator.state == .transcribing && panel.isVisible }

        gate.open()
        try await waitUntil("indicator removed after insertion") { coordinator.state == .ready && !panel.isVisible }
        coordinator.deactivate()
    }

    func testOnlyActiveDictationStatesHaveAnIndicator() {
        XCTAssertNil(DictationActivity(state: .ready))
        XCTAssertNil(DictationActivity(state: .starting))
        XCTAssertEqual(DictationActivity(state: .recording), .recording)
        XCTAssertEqual(DictationActivity(state: .finishing), .processing)
        XCTAssertEqual(DictationActivity(state: .transcribing), .processing)
        XCTAssertEqual(DictationActivity(state: .inserting), .processing)
        XCTAssertNil(DictationActivity(state: .failed(.captureStart("test"))))
    }
}
