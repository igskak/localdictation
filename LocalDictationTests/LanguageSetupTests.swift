import AppKit
import SwiftUI
import XCTest
@testable import LocalDictation

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

    /// Closing the window is an answer. There is nothing to cancel into: the
    /// app has always had a profile, and the question is about replacing a
    /// default nobody chose.
    func testClosingTheWindowRecordsTheSelectionOnScreen() async throws {
        let store = InMemoryPreferencesStore()
        let coordinator = makeCoordinator(store)
        let controller = LanguageSetupWindowController(coordinator: coordinator)
        controller.presentIfNeeded()
        try await settle()

        controller.window?.close()
        try await settle()

        XCTAssertFalse(coordinator.needsLanguageSetup)
        XCTAssertTrue(store.stored.hasChosenLanguages)
        XCTAssertEqual(store.stored.languageProfile, .default, "The selection on screen was the one the app had")
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
