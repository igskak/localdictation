import XCTest
@testable import LocalDictation

/// What a language outside the verified four gets, and what it deliberately
/// does not.
///
/// Phase 7 lets a user select any of the hundred languages the engine knows.
/// The cleanup rules and half the risk signals are calibrated per language and
/// were measured on four of them, so the rest get recognition and silence
/// rather than rules aimed at a language nobody checked. Silence is the safe
/// direction: a mark that means nothing teaches the user that marks mean
/// nothing, which is the one failure `docs/PHASE_3.md` will not spend.
final class UnverifiedLanguageTests: XCTestCase {
    private var polish: SpeechLanguage!
    private var swedish: SpeechLanguage!

    override func setUpWithError() throws {
        polish = try XCTUnwrap(SpeechLanguage(rawValue: "pl"))
        swedish = try XCTUnwrap(SpeechLanguage(rawValue: "sv"))
    }

    // MARK: - The shape rule

    /// The vowel table is Latin-basic plus the German umlauts and the Ukrainian
    /// і/ї/є, so `łódź` reads as a word with no vowel in it. Running the rule
    /// anyway would mark ordinary Polish as mangled recognition.
    func testTheMalformedWordRuleIsSilentInALanguageItWasNotCalibratedFor() {
        let signal = MalformedWordSignal(lexicon: NothingIsKnownLexicon())

        let polishContext = RiskContext(raw: "łódź płynie", profile: LanguageProfile(polish), language: polish)
        XCTAssertEqual(signal.spans(in: polishContext).count, 0)

        let russianContext = RiskContext(raw: "ррверка прошла", profile: .russian, language: .russian)
        XCTAssertEqual(
            signal.spans(in: russianContext).count,
            1,
            "The verified four keep the rule they were measured with"
        )
    }

    // MARK: - Names

    /// The one heuristic that survives, because it rests on a single property
    /// of the language and that property is in the catalog.
    func testTheNameHeuristicSurvivesWhereverOnlyNamesAreCapitalized() {
        XCTAssertTrue(EntityRiskSignal.usesCapitalizationHeuristic(polish))
        XCTAssertTrue(EntityRiskSignal.usesCapitalizationHeuristic(.english))
        XCTAssertFalse(EntityRiskSignal.usesCapitalizationHeuristic(.german))
    }

    func testALanguageThatCapitalizesItsNounsIsNotOnlyGerman() throws {
        let luxembourgish = try XCTUnwrap(SpeechLanguage(rawValue: "lb"))

        XCTAssertFalse(EntityRiskSignal.usesCapitalizationHeuristic(luxembourgish))
    }

    func testACapitalizedWordMidSentenceIsStillANameInAnUnverifiedLanguage() {
        let context = RiskContext(raw: "spotkanie z Kowalskim jutro", profile: LanguageProfile(polish), language: polish)

        let marked = EntityRiskSignal().spans(in: context).map { String(Array(context.raw)[$0.range]) }

        XCTAssertEqual(marked, ["Kowalskim"])
    }

    // MARK: - Language switching

    /// `ö` means German among the four languages the letter rules were written
    /// for. It means nothing of the kind in Swedish.
    func testLetterEvidenceIsNotUsedOnceAnUnverifiedLanguageIsSelected() {
        let profile = LanguageProfile(swedish, .english)
        let context = RiskContext(raw: "arbetet för dig", profile: profile, language: swedish)

        XCTAssertEqual(LanguageSwitchRiskSignal().spans(in: context).count, 0)
    }

    func testLetterEvidenceStillWorksAcrossTheVerifiedFour() {
        let context = RiskContext(raw: "der Termin für morgen", profile: .germanEnglish, language: .english)

        let marked = LanguageSwitchRiskSignal().spans(in: context).map { String(Array(context.raw)[$0.range]) }

        XCTAssertEqual(marked, ["für"], "A German word inside an English sentence is exactly what this signal is for")
    }

    /// Script mismatch survives, because a script is a fact about the letters
    /// rather than about a language anybody measured.
    func testAScriptMismatchIsStillEvidenceInAnUnverifiedLanguage() {
        let profile = LanguageProfile(polish, .english)
        let context = RiskContext(raw: "spotkanie завтра", profile: profile, language: polish)

        let marked = LanguageSwitchRiskSignal().spans(in: context).map { String(Array(context.raw)[$0.range]) }

        XCTAssertEqual(marked, ["завтра"])
    }

    /// Before Phase 7 every language that was not Cyrillic was treated as
    /// Latin, which was true of four languages and is not true of a hundred.
    func testALanguageInAThirdScriptMakesTheQuestionUnanswerableRatherThanFalse() throws {
        let japanese = try XCTUnwrap(SpeechLanguage(rawValue: "ja"))
        let profile = LanguageProfile(japanese, .english)

        XCTAssertTrue(LanguageIdentifier.scriptMatches("завтра", profile: profile))
        XCTAssertTrue(LanguageIdentifier.scriptMatches("tomorrow", profile: profile))
        XCTAssertFalse(
            LanguageIdentifier.scriptMatches("tomorrow", profile: .russian),
            "A Latin word in a Russian-only profile is still the strong case"
        )
    }

    // MARK: - Cleanup

    func testFillerRemovalHasNothingToSayInALanguageWithNoFillerList() {
        let result = ConservativeCleanupService().clean("no to jest ee dobrze", language: polish, options: .default)

        XCTAssertEqual(
            result.cleaned,
            "No to jest ee dobrze.",
            "Capitalization and the closing stop are script-level; the Polish filler stays because nobody has listed one"
        )
    }
}

/// Every word is unknown, so only the shape rule decides. The opposite of the
/// fake `MalformedWordSignalTests` uses, and the point here is the gate before
/// both of them.
private struct NothingIsKnownLexicon: LexiconChecking {
    func supports(_ language: SpeechLanguage) -> Bool { true }
    func isKnownWord(_ word: String, language: SpeechLanguage) -> Bool { false }
}
