import XCTest
@testable import Witness

/// The engine's own job: pricing a reason, placing a raw span in the cleaned
/// text, and attaching the audio window. The signals are tested elsewhere.
final class RiskEngineTests: XCTestCase {
    private let cleanup = ConservativeCleanupService()

    private func analyze(
        _ raw: String,
        language: SpeechLanguage,
        profile: LanguageProfile,
        glossary: [GlossaryEntry] = [],
        weights: RiskWeights = .default
    ) -> (CleanupResult, [RiskSpan]) {
        let result = cleanup.clean(raw, language: language)
        let transcript = Transcript.fixture(text: raw, profile: profile)
        let spans = RiskEngine.standard(weights: weights).analyze(
            cleanup: result,
            tokens: transcript.tokens,
            profile: profile,
            glossary: glossary
        )
        return (result, spans)
    }

    // MARK: - Placement

    /// The acceptance criterion: risky spans land on the correct characters in
    /// the *cleaned* text, which is not the text the signals looked at.
    func testSpansLandOnTheCorrectCharactersAfterCleanup() throws {
        let (result, spans) = analyze(
            "  ähm bitte überweise 1450 euro  ",
            language: .german,
            profile: .german
        )
        let cleanedCharacters = Array(result.cleaned)

        XCTAssertEqual(result.cleaned, "Bitte überweise 1450 euro.")
        for span in spans where span.hasExtentInCleanedText {
            XCTAssertEqual(
                String(cleanedCharacters[span.cleanedRange]),
                span.text,
                "a span's text does not match the characters it points at"
            )
        }
        let amount = try XCTUnwrap(spans.first { $0.reason == .number })
        XCTAssertEqual(amount.text, "1450")
    }

    func testSpansLandCorrectlyOnUmlautsAndCyrillic() {
        let (german, germanSpans) = analyze(
            "ähm müller schuldet 1450 euro für die prüfung",
            language: .german,
            profile: .german
        )
        for span in germanSpans where span.hasExtentInCleanedText {
            XCTAssertEqual(String(Array(german.cleaned)[span.cleanedRange]), span.text)
        }

        let (russian, russianSpans) = analyze(
            "переведи 1450 евро мюллеру до пятницы",
            language: .russian,
            profile: .russian
        )
        for span in russianSpans where span.hasExtentInCleanedText {
            XCTAssertEqual(String(Array(russian.cleaned)[span.cleanedRange]), span.text)
        }
        XCTAssertTrue(russianSpans.contains { $0.text == "1450" })
        XCTAssertTrue(russianSpans.contains { $0.text == "евро" })
    }

    // MARK: - Weighting

    func testDeterministicSignalsOutweighTheReviewThreshold() throws {
        let (_, spans) = analyze("bitte 1450 euro", language: .german, profile: .german)
        let amount = spans.first { $0.reason == .number }

        XCTAssertEqual(amount?.weight, RiskWeights.default.number)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(amount?.weight), ReviewPolicy.default.attentionThreshold)
    }

    /// Punctuation and capitalization happen on nearly every utterance. If they
    /// were priced like a deleted word, every utterance would light the
    /// indicator.
    func testRoutineCleanupEditsStayBelowTheAttentionThreshold() {
        let (_, spans) = analyze("der termin steht", language: .german, profile: .german)

        XCTAssertFalse(spans.isEmpty)
        for span in spans {
            XCTAssertLessThan(span.weight, ReviewPolicy.default.attentionThreshold, "\(span.reason) is too heavy")
        }
    }

    /// Deleting a word the user said must always be visible in the review —
    /// but a removed "ähm" is cleanup working as designed, not a recognition
    /// failure, and lighting the indicator for one would put a triangle on most
    /// spoken sentences. Visible, then, and not announced.
    func testRemovingASpokenWordIsAlwaysShownAndNeverAnnounced() throws {
        let (_, spans) = analyze("ähm der termin steht", language: .german, profile: .german)
        let removal = try XCTUnwrap(spans.first { $0.reason == .cleanupEdit(.fillerRemoval) })

        XCTAssertGreaterThanOrEqual(removal.weight, ReviewPolicy.default.displayThreshold)
        XCTAssertLessThan(removal.weight, ReviewPolicy.default.attentionThreshold)
    }

    /// `docs/PHASE_3.md` requires model confidence to arrive last, behind a
    /// weight that starts at zero.
    func testModelConfidenceContributesNothingUntilItIsWeighted() throws {
        XCTAssertEqual(RiskWeights.default.modelConfidence, 0)

        let cleanupResult = cleanup.clean("der termin steht", language: .german)
        let tokens = [
            TranscriptToken(text: "der", range: 0..<3, start: 0, end: 0.3, confidence: 0.05),
            TranscriptToken(text: "termin", range: 4..<10, start: 0.3, end: 0.7, confidence: 0.05),
            TranscriptToken(text: "steht", range: 11..<16, start: 0.7, end: 1, confidence: 0.05),
        ]
        let spans = RiskEngine.standard().analyze(cleanup: cleanupResult, tokens: tokens, profile: .german)
        let confidenceSpans = spans.filter { if case .lowConfidence = $0.reason { return true } else { return false } }

        XCTAssertEqual(confidenceSpans.count, 3, "the signal still runs and still reports")
        XCTAssertTrue(confidenceSpans.allSatisfy { $0.weight == 0 })
        XCTAssertEqual(ReviewCoordinator.decide(spans: spans), .quiet)
    }

    func testConfidenceCanBeEnabledByRaisingItsWeight() throws {
        var weights = RiskWeights.default
        weights.modelConfidence = 1

        let cleanupResult = cleanup.clean("der termin steht", language: .german)
        let tokens = [TranscriptToken(text: "termin", range: 4..<10, start: 0.3, end: 0.7, confidence: 0.1)]
        let spans = RiskEngine.standard(weights: weights)
            .analyze(cleanup: cleanupResult, tokens: tokens, profile: .german)
        let confidence = spans.first { if case .lowConfidence = $0.reason { return true } else { return false } }

        XCTAssertEqual(try XCTUnwrap(confidence?.weight), 0.8, accuracy: 0.0001)
    }

    func testLanguageSwitchWeightDependsOnTheProfile() {
        let (_, insideProfile) = analyze("счёт открыт meeting", language: .russian, profile: .russianEnglish)
        let (_, outsideProfile) = analyze("счёт открыт meeting", language: .russian, profile: .russian)

        XCTAssertTrue(insideProfile.filter { if case .languageSwitch = $0.reason { return true } else { return false } }.isEmpty)
        let switched = outsideProfile.first { if case .languageSwitch = $0.reason { return true } else { return false } }
        XCTAssertEqual(switched?.weight, RiskWeights.default.languageOutsideProfile)
    }

    // MARK: - Audio window

    func testASpanCarriesTheTimingOfEveryTokenItTouches() throws {
        let raw = "bitte überweise 1450 euro"
        let transcript = Transcript.fixture(text: raw, profile: .german, secondsPerWord: 0.5)
        let cleanupResult = cleanup.clean(raw, language: .german)
        let spans = RiskEngine.standard().analyze(
            cleanup: cleanupResult,
            tokens: transcript.tokens,
            profile: .german
        )

        let amount = try XCTUnwrap(spans.first { $0.text == "1450" })
        XCTAssertEqual(amount.start, 1.0)
        XCTAssertEqual(amount.end, 1.5)
        XCTAssertTrue(amount.isPlayable)
    }

    func testASpanWithNoOverlappingTokenIsNotPlayable() {
        let cleanupResult = cleanup.clean("bitte 1450 euro", language: .german)
        let spans = RiskEngine.standard().analyze(cleanup: cleanupResult, tokens: [], profile: .german)

        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(spans.allSatisfy { !$0.isPlayable })
    }

    // MARK: - Combination

    func testTwoSignalsAgreeingOnOneFragmentProduceOneMark() {
        let duplicate = RawRiskSpan(reason: .number, range: 0..<4)
        let engine = RiskEngine(
            signals: [
                StubRiskSignal(identifier: "a", produced: [duplicate]),
                StubRiskSignal(identifier: "b", produced: [duplicate]),
            ]
        )
        let spans = engine.analyze(cleanup: .unchanged("1450 euro", language: .german), profile: .german)

        XCTAssertEqual(spans.count, 1)
    }

    /// Narrowed after the first live session. The rule still holds for two
    /// *specific* signals — but not for the entity heuristic, which only ever
    /// means "this word is capitalized". When another signal has already
    /// explained the word, that adds nothing and costs a warning slot.
    /// `RiskFalsePositiveTests` covers the suppressed side.
    func testTwoSpecificReasonsOnOneFragmentAreBothKept() {
        let engine = RiskEngine(
            signals: [
                StubRiskSignal(identifier: "a", produced: [RawRiskSpan(reason: .number, range: 0..<4)]),
                StubRiskSignal(
                    identifier: "b",
                    produced: [RawRiskSpan(reason: .glossaryNearMiss(term: "1450"), range: 0..<4)]
                ),
            ]
        )
        let spans = engine.analyze(cleanup: .unchanged("1450 euro", language: .german), profile: .german)

        XCTAssertEqual(spans.count, 2, "different reasons for the same fragment are different things to say")
    }

    func testSpansComeBackInReadingOrder() {
        let (_, spans) = analyze(
            "переведи 1450 евро мюллеру до пятницы",
            language: .russian,
            profile: .russian
        )
        let starts = spans.map(\.cleanedRange.lowerBound)

        XCTAssertEqual(starts, starts.sorted())
    }

    func testEmptyTextProducesNoSpans() {
        let spans = RiskEngine.standard().analyze(cleanup: .unchanged("", language: .german), profile: .german)
        XCTAssertTrue(spans.isEmpty)
    }
}
