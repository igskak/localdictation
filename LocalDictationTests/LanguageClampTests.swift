import XCTest
@testable import LocalDictation

/// From the second live session: a Ukrainian utterance on a UK+EN profile came
/// back decoded as Polish, in Latin script — "Załeżek 2500 EUR" where the user
/// said "Залишок 2500 євро".
///
/// Free detection chooses from every language Whisper knows, not from the two
/// the user selected. These cover the pure half of the clamp; the decode path
/// itself needs the model and is exercised by the benchmark.
final class LanguageClampTests: XCTestCase {
    func testTheProfileLanguageWithTheHighestProbabilityWins() {
        let best = WhisperKitTranscriptionService.bestLanguage(
            in: .ukrainianEnglish,
            probabilities: ["uk": 0.31, "en": 0.52, "pl": 0.9]
        )

        XCTAssertEqual(best, .english, "Polish outranks both, and is exactly what must be ignored")
    }

    /// The reason the clamp does not simply pin the primary: a user who selected
    /// UK+EN and spoke English must not be re-decoded as Ukrainian.
    func testASpokenSecondaryLanguageIsNotOverriddenByThePrimary() {
        let best = WhisperKitTranscriptionService.bestLanguage(
            in: .ukrainianEnglish,
            probabilities: ["uk": 0.05, "en": 0.88]
        )

        XCTAssertEqual(best, .english)
    }

    func testThePrimaryWinsWhenItIsTheMostLikely() {
        let best = WhisperKitTranscriptionService.bestLanguage(
            in: .russianUkrainian,
            probabilities: ["ru": 0.7, "uk": 0.2, "bg": 0.95]
        )

        XCTAssertEqual(best, .russian)
    }

    func testFallsBackToThePrimaryWhenNoProfileLanguageIsRanked() {
        let best = WhisperKitTranscriptionService.bestLanguage(
            in: .germanEnglish,
            probabilities: ["pl": 0.6, "cs": 0.3]
        )

        XCTAssertEqual(best, .german, "a transcript in a selected language beats failing the recording")
    }

    func testAnEmptyDistributionStillYieldsAUsableLanguage() {
        XCTAssertEqual(
            WhisperKitTranscriptionService.bestLanguage(in: .russianEnglish, probabilities: [:]),
            .russian
        )
    }

    /// A stray language is detectable exactly, because Whisper names what it
    /// picked — no guessing from the text is involved.
    func testAStrayLanguageIsNotAMemberOfTheProfile() {
        XCTAssertNil(SpeechLanguage(rawValue: "pl"))
        XCTAssertFalse(LanguageProfile.ukrainianEnglish.contains(.russian))
        XCTAssertTrue(LanguageProfile.ukrainianEnglish.contains(.english))
    }
}
