import XCTest
@testable import LocalDictation

/// Every signal is tested in isolation and without a model, which is the point
/// of building the deterministic ones first: these are pure functions over
/// text, so a test is a string and an expectation.
final class RiskSignalTests: XCTestCase {
    private func context(
        _ text: String,
        profile: LanguageProfile,
        language: SpeechLanguage? = nil,
        glossary: [GlossaryEntry] = [],
        edits: [TextEdit] = [],
        tokens: [TranscriptToken] = []
    ) -> RiskContext {
        RiskContext(
            raw: text,
            tokens: tokens,
            profile: profile,
            language: language ?? profile.primary,
            edits: edits,
            glossary: glossary
        )
    }

    private func marked(_ spans: [RawRiskSpan], in text: String) -> [String] {
        let characters = Array(text)
        return spans.map { String(characters[$0.range]) }
    }

    // MARK: - Numbers, amounts, dates

    func testDigitsAmountsAndSpelledOutNumbersAreMarked() {
        let text = "Bitte überweise 1450 Euro bis Freitag"
        let spans = NumberRiskSignal().spans(in: context(text, profile: .german))

        XCTAssertEqual(marked(spans, in: text), ["1450", "Euro"])
    }

    func testDatesAreMarkedInEveryLanguage() {
        let cases: [(String, SpeechLanguage, [String])] = [
            ("Der Termin am dritten März", .german, ["dritten", "März"]),
            ("The meeting on March third", .english, ["March", "third"]),
            ("Встреча третьего марта", .russian, ["третьего", "марта"]),
            ("Зустріч третього березня", .ukrainian, ["третього", "березня"]),
        ]

        for (text, language, expected) in cases {
            let spans = NumberRiskSignal().spans(
                in: context(text, profile: LanguageProfile(primary: language, secondary: nil))
            )
            XCTAssertEqual(marked(spans, in: text), expected, "date marking failed for \(language.rawValue)")
        }
    }

    func testCurrencySymbolsAndWordsAreMarkedAsAmounts() {
        let text = "Betrag 89 € und 200 гривень"
        let spans = NumberRiskSignal().spans(in: context(text, profile: .russian))

        XCTAssertEqual(marked(spans, in: text), ["89", "€", "200", "гривень"])
        XCTAssertTrue(spans.contains { $0.reason == .currency })
    }

    func testOrdinaryWordsAreNotMarked() {
        let text = "Der Termin ist bestätigt"
        XCTAssertTrue(NumberRiskSignal().spans(in: context(text, profile: .german)).isEmpty)
    }

    // MARK: - Named entities

    /// The heuristic that works in three languages, and the one that does not
    /// work in the fourth, are the whole point of this signal.
    func testCapitalizedMidSentenceWordsAreMarkedOutsideGerman() {
        let text = "Please transfer money to Miller by Friday"
        let spans = EntityRiskSignal().spans(in: context(text, profile: .english))

        XCTAssertEqual(marked(spans, in: text), ["Miller", "Friday"])
    }

    func testGermanNounsAreNotMarkedAsEntities() {
        // Every noun here is capitalized, and none of them is a name. Running
        // the capitalization heuristic would mark most of the sentence.
        let text = "Die Rechnung für die Prüfung der Verträge ist offen"
        let spans = EntityRiskSignal().spans(in: context(text, profile: .german))

        XCTAssertTrue(spans.isEmpty, "the capitalization heuristic must not run in German")
        XCTAssertFalse(EntityRiskSignal.usesCapitalizationHeuristic(.german))
    }

    /// German still gets the narrow rules that *are* valid there.
    func testGermanNamesAreMarkedWhenATitleAnnouncesThem() {
        let text = "Frau Schneider hat den Vertrag abgelehnt"
        let spans = EntityRiskSignal().spans(in: context(text, profile: .german))

        XCTAssertEqual(marked(spans, in: text), ["Schneider"])
    }

    func testAcronymsAreMarkedInEveryLanguage() {
        let text = "Die GmbH und die AG"
        let spans = EntityRiskSignal().spans(in: context(text, profile: .german))
        XCTAssertEqual(marked(spans, in: text), ["AG"])
    }

    func testEnglishPronounIIsNotAName() {
        let text = "Tomorrow I will send it"
        XCTAssertTrue(EntityRiskSignal().spans(in: context(text, profile: .english)).isEmpty)
    }

    func testASentenceInitialCapitalIsNotEvidence() {
        let text = "Переведи деньги. Счёт открыт"
        XCTAssertTrue(EntityRiskSignal().spans(in: context(text, profile: .russian)).isEmpty)
    }

    func testNumbersAreLeftToTheNumberSignal() {
        let text = "Invoice 1450 is open"
        XCTAssertTrue(EntityRiskSignal().spans(in: context(text, profile: .english)).isEmpty)
    }

    // MARK: - Glossary

    func testANearMissOnAGlossaryTermIsMarked() {
        let glossary = [GlossaryEntry(term: "Müller", language: .german)]
        let text = "Bitte an Miller überweisen"
        let spans = GlossaryRiskSignal().spans(in: context(text, profile: .german, glossary: glossary))

        XCTAssertEqual(marked(spans, in: text), ["Miller"])
        XCTAssertEqual(spans.first?.reason, .glossaryNearMiss(term: "Müller"))
    }

    func testAnExactGlossaryMatchIsNotMarked() {
        let glossary = [GlossaryEntry(term: "Müller", language: .german)]
        let text = "Bitte an Müller überweisen"

        XCTAssertTrue(
            GlossaryRiskSignal().spans(in: context(text, profile: .german, glossary: glossary)).isEmpty,
            "the term came out right; marking it would be a false warning"
        )
    }

    func testGlossaryTermsAreScopedByLanguage() {
        let glossary = [GlossaryEntry(term: "Мюллер", language: .russian)]
        let text = "Мюлер получил счёт"

        XCTAssertTrue(
            GlossaryRiskSignal().spans(in: context(text, profile: .german, glossary: glossary)).isEmpty,
            "a Russian term must not fire in a German-only profile"
        )
        XCTAssertEqual(
            marked(GlossaryRiskSignal().spans(in: context(text, profile: .russian, glossary: glossary)), in: text),
            ["Мюлер"]
        )
    }

    func testAnUnrelatedWordIsNotAGlossaryNearMiss() {
        let glossary = [GlossaryEntry(term: "Müller", language: .german)]
        let text = "Die Rechnung ist offen"

        XCTAssertTrue(GlossaryRiskSignal().spans(in: context(text, profile: .german, glossary: glossary)).isEmpty)
    }

    /// A short term must not match half the sentence.
    func testShortTermsUseATighterDistance() {
        let glossary = [GlossaryEntry(term: "Ada", language: .english)]
        let text = "and the idea"

        XCTAssertTrue(GlossaryRiskSignal().spans(in: context(text, profile: .english, glossary: glossary)).isEmpty)
        XCTAssertEqual(GlossaryRiskSignal.allowedDistance(forTermLength: 3), 1)
    }

    // MARK: - Cleanup edits

    func testEveryCleanupEditProducesASpan() {
        let cleanup = ConservativeCleanupService().clean("ähm der termin", language: .german)
        let spans = CleanupEditRiskSignal().spans(
            in: context(cleanup.raw, profile: .german, edits: cleanup.edits)
        )

        XCTAssertEqual(spans.count, cleanup.edits.count)
        XCTAssertTrue(spans.contains { $0.reason == .cleanupEdit(.fillerRemoval) })
    }

    // MARK: - Language switching

    func testAWordInTheWrongScriptIsMarked() {
        let text = "Счёт открыт meeting завтра"
        let spans = LanguageSwitchRiskSignal().spans(in: context(text, profile: .russian))

        XCTAssertEqual(marked(spans, in: text), ["meeting"])
    }

    func testTheSecondLanguageOfAMixedProfileIsNotAScriptMismatch() {
        let text = "Счёт открыт meeting завтра"
        let spans = LanguageSwitchRiskSignal().spans(in: context(text, profile: .russianEnglish))

        XCTAssertTrue(spans.isEmpty, "an English word is what a RU+EN profile is for")
    }

    /// Same-script pairs are separated by letters that exist in one language of
    /// the pair and not the other.
    func testUkrainianLettersAreEvidenceInsideARussianProfile() {
        let text = "Рахунок відкритий"
        let spans = LanguageSwitchRiskSignal().spans(in: context(text, profile: .russian, language: .russian))

        XCTAssertEqual(marked(spans, in: text), ["відкритий"])
        XCTAssertEqual(spans.first?.reason, .languageSwitch(.ukrainian))
    }

    func testNumbersCarryNoLanguageEvidence() {
        let text = "Счёт 1450 открыт"
        XCTAssertTrue(LanguageSwitchRiskSignal().spans(in: context(text, profile: .russian)).isEmpty)
    }

    // MARK: - Model confidence

    func testLowConfidenceTokensProduceSpans() {
        let transcript = Transcript.fixture(text: "Der Termin steht", confidence: nil)
        let tokens = [
            TranscriptToken(text: "Der", range: 0..<3, start: 0, end: 0.3, confidence: 0.9),
            TranscriptToken(text: "Termin", range: 4..<10, start: 0.3, end: 0.7, confidence: 0.2),
            TranscriptToken(text: "steht", range: 11..<16, start: 0.7, end: 1, confidence: 0.95),
        ]
        _ = transcript

        let spans = ConfidenceRiskSignal(threshold: 0.5).spans(
            in: context("Der Termin steht", profile: .german, tokens: tokens)
        )

        XCTAssertEqual(marked(spans, in: "Der Termin steht"), ["Termin"])
        XCTAssertEqual(spans.first?.reason, .lowConfidence(0.2))
    }

    func testTokensWithoutAConfidenceSignalProduceNothing() {
        let tokens = [TranscriptToken(text: "Der", range: 0..<3, start: 0, end: 0.3, confidence: nil)]
        XCTAssertTrue(
            ConfidenceRiskSignal().spans(in: context("Der", profile: .german, tokens: tokens)).isEmpty
        )
    }
}
