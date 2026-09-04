import XCTest
@testable import Witness

/// The whole of the language choice, without a model.
///
/// `LanguageClampTests` covers what this rule inherited from Phase 6 — the
/// ranking is trusted, but only inside the set the user chose. These are the
/// cases that set could not have had when it was always a pair of one primary
/// and one secondary.
final class LanguageDecisionTests: XCTestCase {
    private func choose(
        _ profile: LanguageProfile,
        _ probabilities: [String: Float],
        previous: SpeechLanguage? = nil
    ) -> LanguageDecision {
        LanguageDecision.choose(profile: profile, probabilities: probabilities, previous: previous)
    }

    func testOneSelectedLanguageIsNeverDetected() {
        let decision = choose(.german, ["ru": 0.99])

        XCTAssertEqual(decision.language, .german)
        XCTAssertEqual(decision.reason, .onlyLanguage)
    }

    func testAClearLeaderSettlesIt() {
        let decision = choose(LanguageProfile(.russian, .english, .ukrainian), ["ru": 0.1, "en": 0.85, "uk": 0.05])

        XCTAssertEqual(decision.language, .english)
        XCTAssertEqual(decision.reason, .confident)
    }

    /// The reason three languages are safe to select: the ranking is read
    /// inside the set, so a fourth language leading it changes nothing.
    func testALanguageTheUserDidNotSelectCannotWinHoweverLikelyItIs() {
        let decision = choose(LanguageProfile(.russian, .english, .ukrainian), ["pl": 0.94, "en": 0.75, "ru": 0.02])

        XCTAssertEqual(decision.language, .english)
    }

    func testNoSelectedLanguageInTheDistributionFallsBackToThePreferredOne() {
        let decision = choose(LanguageProfile(.ukrainian, .english), ["pl": 0.6, "cs": 0.3])

        XCTAssertEqual(decision.language, .ukrainian)
        XCTAssertEqual(decision.reason, .noEvidence)
    }

    // MARK: - The two-word answer

    /// The failure a Russian-and-Ukrainian user actually meets. One word of
    /// audio does not separate two closely related languages, and the sentence
    /// before it is the best evidence in the room.
    func testAnAmbiguousUtteranceContinuesThePreviousLanguage() {
        let decision = choose(
            LanguageProfile(.russian, .english, .ukrainian),
            ["ru": 0.44, "uk": 0.40, "en": 0.02],
            previous: .ukrainian
        )

        XCTAssertEqual(decision.language, .ukrainian)
        XCTAssertEqual(decision.reason, .continuedFromPrevious)
    }

    func testAConfidentUtteranceIsNotOverruledByThePreviousLanguage() {
        let decision = choose(
            LanguageProfile(.russian, .ukrainian),
            ["ru": 0.05, "uk": 0.92],
            previous: .russian
        )

        XCTAssertEqual(decision.language, .ukrainian)
        XCTAssertEqual(decision.reason, .confident, "Switching language costs one clear sentence, never a setting")
    }

    func testAPreviousLanguageThatIsNotInContentionDoesNotWin() {
        let decision = choose(
            LanguageProfile(.russian, .english, .ukrainian),
            ["ru": 0.45, "uk": 0.42, "en": 0.03],
            previous: .english
        )

        XCTAssertEqual(decision.language, .russian)
        XCTAssertEqual(decision.reason, .fellBackToPreferred)
    }

    func testAmbiguityWithoutAPreviousLanguageFallsBackToThePreferredOne() {
        let decision = choose(LanguageProfile(.ukrainian, .russian), ["ru": 0.47, "uk": 0.44])

        XCTAssertEqual(decision.language, .ukrainian)
        XCTAssertEqual(decision.reason, .fellBackToPreferred)
    }

    /// Preferred is a tie-break, not a veto: it only speaks when it is one of
    /// the two languages actually in contention.
    func testThePreferredLanguageDoesNotWinWhenItIsNotInContention() {
        let decision = choose(
            LanguageProfile(.english, .russian, .ukrainian),
            ["ru": 0.46, "uk": 0.43, "en": 0.01]
        )

        XCTAssertEqual(decision.language, .russian)
        XCTAssertEqual(decision.reason, .leadWithoutMargin)
    }

    /// The margin is what separates "the engine knows" from "the engine is
    /// guessing", and it is the only reason the previous language ever gets a
    /// say. Both sides of it are asserted away from the knife edge: a
    /// difference of exactly 0.2 is not a thing `Float` can be asked about.
    func testTheMarginIsWhatDecidesBetweenTheEngineAndTheContext() {
        let clear = LanguageDecision.choose(
            profile: LanguageProfile(.russian, .ukrainian),
            probabilities: ["ru": 0.25, "uk": 0.55],
            previous: .russian,
            margin: 0.2
        )
        XCTAssertEqual(clear.language, .ukrainian)
        XCTAssertEqual(clear.reason, .confident)

        let close = LanguageDecision.choose(
            profile: LanguageProfile(.russian, .ukrainian),
            probabilities: ["ru": 0.35, "uk": 0.45],
            previous: .russian,
            margin: 0.2
        )
        XCTAssertEqual(close.language, .russian)
        XCTAssertEqual(close.reason, .continuedFromPrevious)
    }

    /// Two languages the engine cannot separate at all are separated by the
    /// user's own order rather than by whichever came out of a dictionary
    /// first — and the same input always gives the same answer.
    func testAnExactTieIsBrokenByThePreferredOrder() {
        XCTAssertEqual(choose(LanguageProfile(.ukrainian, .russian), ["ru": 0.5, "uk": 0.5]).language, .ukrainian)
        XCTAssertEqual(choose(LanguageProfile(.russian, .ukrainian), ["ru": 0.5, "uk": 0.5]).language, .russian)
    }

    func testTheRankingIsRestrictedToTheProfileAndOrderedByLikelihood() {
        let ranked = LanguageDecision.rank(
            profile: LanguageProfile(.russian, .english, .ukrainian),
            probabilities: ["pl": 0.9, "ru": 0.1, "uk": 0.4]
        )

        XCTAssertEqual(ranked.map(\.language), [.ukrainian, .russian])
    }
}
