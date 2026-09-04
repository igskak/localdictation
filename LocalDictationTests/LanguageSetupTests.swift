import AppKit
import SwiftUI
import XCTest
@testable import Witness

/// The first-run question, driven through real AppKit layout.
///
/// `ReviewPanelControllerTests` exists because a SwiftUI view crashed the app
/// the first time it appeared while every unit test passed. This is the same
/// risk in the same shape: a window nobody sees until a first run, holding a
/// hundred-row list, shown before anything else in the app has happened.
@MainActor
final class LanguageSetupTests: XCTestCase {
    private func makeCoordinator(_ store: any PreferencesStore) -> DictationCoordinator {
        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService(),
            transcriptionService: FakeTranscriptionService(),
            glossaryStore: InMemoryGlossaryStore(.empty),
            preferencesStore: store
        )
        coordinator.activate()
        return coordinator
    }

    @discardableResult
    private func render(_ view: some View, width: CGFloat = 520, height: CGFloat = 620) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.removeFromSuperview()
        return size
    }

    private func settle(_ turns: Int = 4) async throws {
        for _ in 0..<turns {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - The window

    func testTheQuestionLaysOutWithAHundredLanguagesInIt() {
        let model = LanguageSetupModel(selection: .default)
        let size = render(LanguageSetupView(model: model) {})

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testTheEditorLaysOutOnItsOwnAsSettingsShowsIt() {
        var profile = LanguageProfile(.russian, .english, .ukrainian)
        let size = render(
            LanguageSelectionEditor(selection: Binding(get: { profile }, set: { profile = $0 })),
            width: 520,
            height: 420
        )

        XCTAssertGreaterThan(size.height, 0)
    }

    func testTheWindowOpensOnlyWhileTheQuestionIsUnanswered() async throws {
        let coordinator = makeCoordinator(InMemoryPreferencesStore())
        let controller = LanguageSetupWindowController(coordinator: coordinator)

        controller.presentIfNeeded()
        try await settle()
        XCTAssertTrue(controller.isAsking)
        XCTAssertTrue(coordinator.needsLanguageSetup, "Showing the question is not answering it")

        // A second call must bring the same window forward rather than build
        // another one.
        let window = controller.window
        controller.presentIfNeeded()
        try await settle()
        XCTAssertIdentical(controller.window, window)

        controller.window?.close()
        try await settle()
    }

    /// From the first live launch: the window was closed without ever having
    /// been read, and closing used to count as an answer. It recorded German
    /// and English — which nobody had chosen — and never asked again.
    func testClosingTheWindowAnswersNothing() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator)
        controller.presentIfNeeded()
        try await settle()

        controller.window?.close()
        try await settle()

        XCTAssertTrue(coordinator.needsLanguageSetup, "The next launch has to ask again")
        XCTAssertFalse(store.stored.hasChosenLanguages)
        XCTAssertEqual(store.saveCount, 0, "A question nobody answered writes nothing")
    }

    func testContinueIsWhatRecordsTheAnswer() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator)
        controller.presentIfNeeded()
        try await settle()

        controller.confirmSelection()
        try await settle()

        XCTAssertFalse(coordinator.needsLanguageSetup)
        XCTAssertTrue(store.stored.hasChosenLanguages)
        XCTAssertEqual(store.stored.languageProfile, .default)
        XCTAssertFalse(controller.isAsking, "Answering closes the question")
        XCTAssertTrue(controller.isPresenting, "and hands the window to what to do next")

        controller.finish()
        try await settle()
        XCTAssertFalse(controller.isPresenting)
    }

    /// The half of the first run that used to be missing. A menu bar utility
    /// with no Dock icon and no window has to say what the hotkey is, or the
    /// person who just installed it has nothing to press.
    func testWhatToDoNextLaysOutAndNamesTheHotkey() async throws {
        let coordinator = makeCoordinator(InMemoryPreferencesStore())
        let size = render(FirstRunReadyView(coordinator: coordinator) {})

        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertEqual(coordinator.binding.displayString, "\u{2325}Space")
    }

    /// Closing the second screen is not an unanswered question, so it must not
    /// bring the first one back at the next launch.
    func testClosingAfterTheAnswerDoesNotReopenTheQuestion() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator)
        controller.presentIfNeeded()
        try await settle()

        controller.confirmSelection()
        controller.window?.close()
        try await settle()

        XCTAssertFalse(coordinator.needsLanguageSetup)
        XCTAssertTrue(store.stored.hasChosenLanguages)
    }

    /// Answering and then closing is one answer, not an answer followed by a
    /// question left open.
    func testAnsweringThenClosingRecordsOnce() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator)
        controller.presentIfNeeded()
        try await settle()

        controller.confirmSelection()
        controller.confirmSelection()
        try await settle()

        XCTAssertEqual(store.saveCount, 1)
        XCTAssertFalse(coordinator.needsLanguageSetup)
    }

    func testAnAnsweredQuestionIsNotAskedAgain() async throws {
        var stored = Preferences.default
        stored.hasChosenLanguages = true
        let coordinator = makeCoordinator(InMemoryPreferencesStore(stored))
        let controller = LanguageSetupWindowController(coordinator: coordinator)

        controller.presentIfNeeded()
        try await settle()

        XCTAssertFalse(controller.isAsking)
        XCTAssertNil(controller.window)
    }

    // MARK: - The selection itself

    func testTheQuestionOpensWithWhatTheAppAlreadyHad() {
        var stored = Preferences.default
        stored.languageProfile = .russianUkrainian
        let coordinator = makeCoordinator(InMemoryPreferencesStore(stored))

        let model = LanguageSetupModel(selection: coordinator.languageProfile)

        XCTAssertEqual(model.selection, .russianUkrainian)
    }
}
