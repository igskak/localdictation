import XCTest
@testable import LocalDictation

/// Regressions from the first live dictation session.
///
/// Both defects were English-only, which is why they survived a Russian and
/// Ukrainian review: those languages do not capitalize weekdays or months, so
/// the capitalization heuristic never reached them.
final class RiskFalsePositiveTests: XCTestCase {
    private let cleanup = ConservativeCleanupService()

    private func spans(
        _ raw: String,
        language: SpeechLanguage,
        profile: LanguageProfile
    ) -> [RiskSpan] {
        let result = cleanup.clean(raw, language: language)
        let transcript = Transcript.fixture(text: raw, profile: profile)
        return RiskEngine.standard().analyze(
            cleanup: result,
            tokens: transcript.tokens,
            profile: profile
        )
    }

    private func reasons(for word: String, in spans: [RiskSpan]) -> [String] {
        spans.filter { $0.text.trimmingCharacters(in: .punctuationCharacters) == word }
            .map(\.reason.label)
    }

    // MARK: - Weekdays are dates, not people

    /// "Please transfer €1450 to Miller by Friday." reported Friday as a Name.
    func testEnglishWeekdayIsADateNotAName() {
        let result = spans(
            "Please transfer €1450 to Miller by Friday.",
            language: .english,
            profile: .russianEnglish
        )

        XCTAssertEqual(reasons(for: "Friday", in: result), ["Date"])
        XCTAssertEqual(reasons(for: "Miller", in: result), ["Name"], "a real name must still be marked")
    }

    func testWeekdaysAreRecognizedInEveryLanguage() {
        XCTAssertTrue(CriticalTokens.isDate("Freitag"))
        XCTAssertTrue(CriticalTokens.isDate("Friday"))
        // Deadlines are spoken in the genitive: "до пятницы", "до п'ятниці".
        XCTAssertTrue(CriticalTokens.isDate("пятницы"))
        XCTAssertTrue(CriticalTokens.isDate("п'ятниці"))
        XCTAssertFalse(CriticalTokens.isDate("Rechnung"))
    }

    /// German capitalizes weekdays too, and its entity rule is switched off, so
    /// a weekday there was previously marked by nothing at all.
    func testGermanWeekdayIsMarkedAsADate() {
        let result = spans(
            "Bitte überweise 1450 Euro bis Freitag.",
            language: .german,
            profile: .germanEnglish
        )
        XCTAssertEqual(reasons(for: "Freitag", in: result), ["Date"])
    }

    // MARK: - One word, one reason

    /// "The meeting on March 3 was not confirmed." marked March twice — once as
    /// a Date and once as a Name.
    func testMonthIsNotAlsoReportedAsAName() {
        let result = spans(
            "The meeting on March 3 was not confirmed.",
            language: .english,
            profile: .russianEnglish
        )

        XCTAssertEqual(reasons(for: "March", in: result), ["Date"])
        XCTAssertEqual(
            result.filter { $0.text.contains("March") }.count, 1,
            "two labels on one word spend the false-warning budget to say the same thing twice"
        )
    }

    func testSuppressionOnlySilencesTheHeuristic() {
        let entity = RawRiskSpan(reason: .namedEntity, range: 0..<5)
        let date = RawRiskSpan(reason: .date, range: 0..<5)
        let number = RawRiskSpan(reason: .number, range: 10..<12)

        let kept = RiskEngine.suppressingRedundantEntities([entity, date, number])

        XCTAssertEqual(kept.count, 2)
        XCTAssertFalse(kept.contains { if case .namedEntity = $0.reason { return true } else { return false } })
    }

    /// Two specific signals disagreeing about one fragment is real information.
    /// Only the capitalization heuristic gives way.
    func testTwoSpecificSignalsOnOneFragmentBothSurvive() {
        let date = RawRiskSpan(reason: .date, range: 0..<5)
        let number = RawRiskSpan(reason: .number, range: 0..<5)

        XCTAssertEqual(RiskEngine.suppressingRedundantEntities([date, number]).count, 2)
    }

    func testAnUnexplainedNameIsStillMarked() {
        let entity = RawRiskSpan(reason: .namedEntity, range: 0..<6)
        let number = RawRiskSpan(reason: .number, range: 20..<24)

        XCTAssertEqual(RiskEngine.suppressingRedundantEntities([entity, number]).count, 2)
    }

    // MARK: - The languages that were already correct must stay correct

    func testRussianSentenceStillMarksExactlyTheRightThree() {
        let result = spans(
            "Переведи 1450 евро Мюллеру до пятницы.",
            language: .russian,
            profile: .russianEnglish
        )

        XCTAssertEqual(reasons(for: "1450", in: result), ["Number"])
        XCTAssertEqual(reasons(for: "евро", in: result), ["Amount"])
        XCTAssertEqual(reasons(for: "Мюллеру", in: result), ["Name"])
        XCTAssertEqual(reasons(for: "пятницы", in: result), ["Date"], "the deadline is a date now, not nothing")
    }

    func testUkrainianSentenceStillMarksExactlyTheRightThree() {
        let result = spans(
            "Зустріч 3 березня не підтверджена.",
            language: .ukrainian,
            profile: .russianUkrainian
        )

        XCTAssertEqual(reasons(for: "березня", in: result), ["Date"])
        XCTAssertEqual(reasons(for: "3", in: result), ["Number"])
        XCTAssertTrue(
            reasons(for: "підтверджена", in: result).isEmpty,
            "an ordinary lowercase word is not a name"
        )
    }
}
