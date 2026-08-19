import XCTest
@testable import LocalDictation

final class StatusPresentationTests: XCTestCase {
    private let binding = HotkeyBinding.optionSpace

    func testDefaultBindingIsOptionSpace() {
        XCTAssertEqual(binding.displayString, "⌥Space")
        XCTAssertEqual(binding.keyCode, 49)
        XCTAssertEqual(binding.modifiers, .option)
    }

    func testReadyStateTellsTheUserWhatToPress() {
        let presentation = StatusPresentation(state: .ready, binding: binding)
        XCTAssertEqual(presentation.title, "Ready")
        XCTAssertTrue(presentation.detail.contains("⌥Space"))
        XCTAssertEqual(presentation.tint, .ready)
        XCTAssertFalse(presentation.showsPermissionRequest)
    }

    func testNotDeterminedOffersAnExplicitRequest() {
        let presentation = StatusPresentation(state: .needsPermission, binding: binding)
        XCTAssertTrue(presentation.showsPermissionRequest)
        XCTAssertFalse(presentation.showsSystemSettingsShortcut)
    }

    func testDeniedRoutesToSystemSettings() {
        let presentation = StatusPresentation(state: .permissionDenied(restricted: false), binding: binding)
        XCTAssertTrue(presentation.showsSystemSettingsShortcut)
        XCTAssertFalse(presentation.showsPermissionRequest)
        XCTAssertEqual(presentation.tint, .warning)
    }

    func testRestrictedExplainsThatTheUserCannotFixItAlone() {
        let presentation = StatusPresentation(state: .permissionDenied(restricted: true), binding: binding)
        XCTAssertEqual(presentation.title, "Microphone access restricted")
        XCTAssertTrue(presentation.detail.lowercased().contains("policy"))
    }

    /// A recording made while the model is still loading is kept, not dropped.
    /// Calling that wait "Transcribing" is what made a seven-minute first load
    /// read as a hang.
    func testWaitingForTheModelIsNotDisguisedAsTranscribing() {
        let waiting = StatusPresentation(
            state: .transcribing,
            binding: binding,
            modelState: .preparing(ModelPreparation(phase: .compilingForThisSystem))
        )
        XCTAssertEqual(waiting.title, "Waiting for the speech model")
        XCTAssertTrue(waiting.detail.lowercased().contains("memory"))

        let running = StatusPresentation(state: .transcribing, binding: binding, modelState: .ready)
        XCTAssertEqual(running.title, "Transcribing")
    }

    /// Each phase has to be distinguishable in the menu, and the download is
    /// the one phase where a real number exists.
    func testPreparationPhasesReadDifferently() {
        let downloading = TranscriptionModelState.preparing(
            ModelPreparation(phase: .downloading, progress: 0.42)
        )
        XCTAssertTrue(downloading.label.contains("42%"))
        XCTAssertTrue(downloading.label.lowercased().contains("download"))

        let loading = TranscriptionModelState.preparing(ModelPreparation(phase: .loading))
        XCTAssertFalse(loading.label.contains("%"))

        let compiling = TranscriptionModelState.preparing(
            ModelPreparation(phase: .compilingForThisSystem)
        )
        XCTAssertTrue(compiling.label.lowercased().contains("macos version"))
        XCTAssertNotEqual(compiling.label, loading.label)
    }

    func testRecordingStateIsVisuallyDistinct() {
        let recording = StatusPresentation(state: .recording, binding: binding)
        let ready = StatusPresentation(state: .ready, binding: binding)

        XCTAssertEqual(recording.tint, .active)
        XCTAssertNotEqual(recording.systemImage, ready.systemImage)
        XCTAssertTrue(recording.detail.contains("⌥Space"))
    }

    func testFailureOffersRecovery() {
        let presentation = StatusPresentation(state: .failed(.hotkeyRegistration("collision")), binding: binding)
        XCTAssertTrue(presentation.showsRecoveryAction)
        XCTAssertTrue(presentation.detail.contains("collision"))
    }

    /// The state that exists because the paste path waits for the target
    /// application to read the pasteboard.
    func testInsertingSaysWhereTheTextIsGoing() {
        let presentation = StatusPresentation(state: .inserting, binding: .optionSpace)

        XCTAssertEqual(presentation.title, "Inserting")
        XCTAssertEqual(presentation.tint, .active)
        XCTAssertFalse(presentation.showsRecoveryAction)
        XCTAssertFalse(presentation.showsPermissionRequest)
    }
}
