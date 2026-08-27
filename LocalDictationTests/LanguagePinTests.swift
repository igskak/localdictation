import XCTest
@testable import LocalDictation

/// The temporary pin: one language for now, without changing the set.
@MainActor
final class LanguagePinTests: XCTestCase {
    private func makeCoordinator(
        profile: LanguageProfile = LanguageProfile(.russian, .english, .ukrainian)
    ) -> (DictationCoordinator, InMemoryPreferencesStore) {
        var stored = Preferences.default
        stored.languageProfile = profile
        stored.hasChosenLanguages = true
        let store = InMemoryPreferencesStore(stored)

        let coordinator = DictationCoordinator(
            permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(),
            captureService: FakeAudioCaptureService(),
            transcriptionService: FakeTranscriptionService(),
            preferencesStore: store
        )
        coordinator.activate()
        return (coordinator, store)
    }

    func testWithNoPinTheEngineIsAskedForTheWholeSet() {
        let (coordinator, _) = makeCoordinator()

        XCTAssertEqual(coordinator.effectiveProfile, LanguageProfile(.russian, .english, .ukrainian))
    }

    func testAPinNarrowsWhatTheEngineIsAskedForToOneLanguage() {
        let (coordinator, _) = makeCoordinator()

        coordinator.pinnedLanguage = .ukrainian

        XCTAssertEqual(coordinator.effectiveProfile, LanguageProfile(.ukrainian))
        XCTAssertFalse(coordinator.effectiveProfile.isMixed, "A pinned language is never detected")
    }

    /// The set the user chose is what the app remembers. A temporary override
    /// that outlived a launch would quietly become the answer to a question
    /// they answered differently.
    func testAPinIsNeverWritten() {
        let (coordinator, store) = makeCoordinator()
        let writesBefore = store.saveCount

        coordinator.pinnedLanguage = .english

        XCTAssertEqual(store.saveCount, writesBefore)
        XCTAssertEqual(store.stored.languageProfile, LanguageProfile(.russian, .english, .ukrainian))
    }

    func testDeselectingThePinnedLanguageDropsThePin() {
        let (coordinator, _) = makeCoordinator()
        coordinator.pinnedLanguage = .ukrainian

        coordinator.languageProfile = LanguageProfile(.russian, .english)

        XCTAssertNil(coordinator.pinnedLanguage)
        XCTAssertEqual(coordinator.effectiveProfile, LanguageProfile(.russian, .english))
    }

    /// Belt and braces around the same rule: even if a pin survived somehow,
    /// the engine is never asked for a language the user does not speak.
    func testAPinOutsideTheSetIsIgnored() {
        let (coordinator, _) = makeCoordinator(profile: LanguageProfile(.german, .english))

        coordinator.pinnedLanguage = .russian

        XCTAssertEqual(coordinator.effectiveProfile, LanguageProfile(.german, .english))
    }
}
