import XCTest
@testable import Witness

/// The punctuation numbers decide which engine and which prompt ship, so the
/// counting itself has to be pinned down without audio.
final class PunctuationScorerTests: XCTestCase {
    func testWordsCarryTheMarkThatFollowsThem() {
        let words = PunctuationScorer.punctuatedWords("Привет, ты придёшь завтра?", language: .russian)

        XCTAssertEqual(words.map(\.word), ["привет", "ты", "придешь", "завтра"])
        XCTAssertEqual(words.map(\.mark), [.comma, .unmarked, .unmarked, .question])
    }

    func testTheStrongestMarkInAClusterWins() {
        let words = PunctuationScorer.punctuatedWords("Really?! Yes...", language: .english)

        XCTAssertEqual(words.map(\.mark), [.question, .period])
    }

    func testAMarkBetweenDigitsBelongsToTheNumber() {
        let words = PunctuationScorer.punctuatedWords("Treffen um 12:30, Betrag 1.450 Euro.", language: .german)

        XCTAssertEqual(words.map(\.word), ["treffen", "um", "12", "30", "betrag", "1", "450", "euro"])
        XCTAssertEqual(words.map(\.mark), [.unmarked, .unmarked, .unmarked, .comma, .unmarked, .unmarked, .unmarked, .period])
    }

    func testWordsSplitWhereTheWERNormalizerSplitsThem() {
        let text = "«Так» — сказала она; з'їзд/виїзд, e-mail."
        let words = PunctuationScorer.punctuatedWords(text, language: .ukrainian)

        XCTAssertEqual(words.map(\.word), TextNormalizer.default.words(text, language: .ukrainian))
    }

    func testALineBreakMarksAParagraphButNotAtTheEnd() {
        let words = PunctuationScorer.punctuatedWords("Добрый день.\n\nСпасибо за ответ.\n", language: .russian)

        XCTAssertEqual(words.map(\.paragraphBreak), [false, true, false, false, false])
    }

    func testAQuestionWrittenAsAStatementIsAMissAndAFalsePeriod() {
        let score = PunctuationScorer.score(
            reference: "Ты придёшь завтра?",
            hypothesis: "Ты придёшь завтра.",
            language: .russian
        )

        XCTAssertEqual(score.count(reference: .question, hypothesis: .period), 1)
        XCTAssertEqual(try XCTUnwrap(score.recall(.question)), 0)
        XCTAssertNil(score.precision(.question), "nothing was marked as a question")
        XCTAssertEqual(try XCTUnwrap(score.precision(.period)), 0)
        XCTAssertEqual(try XCTUnwrap(score.sentenceBoundaryRecall), 1, "the sentence did end there")
    }

    func testAMissingFinalMarkIsAMissedBoundary() {
        let score = PunctuationScorer.score(
            reference: "Ты придёшь завтра?",
            hypothesis: "ты придёшь завтра",
            language: .russian
        )

        XCTAssertEqual(score.count(reference: .question, hypothesis: .unmarked), 1)
        XCTAssertEqual(try XCTUnwrap(score.sentenceBoundaryRecall), 0)
    }

    func testRecognitionErrorsDoNotShiftTheMarks() {
        // "завтра" misheard as "затра": the question mark still sits on the
        // aligned word, so punctuation is scored as right.
        let score = PunctuationScorer.score(
            reference: "Ты придёшь завтра? Я жду.",
            hypothesis: "Ты придёшь затра? Я жду.",
            language: .russian
        )

        XCTAssertEqual(try XCTUnwrap(score.recall(.question)), 1)
        XCTAssertEqual(try XCTUnwrap(score.recall(.period)), 1)
        XCTAssertEqual(try XCTUnwrap(score.f1(.question)), 1)
    }

    func testADroppedWordTakesItsMarkWithIt() {
        let score = PunctuationScorer.score(
            reference: "Kommst du morgen?",
            hypothesis: "Kommst du",
            language: .german
        )

        XCTAssertEqual(score.count(reference: .question, hypothesis: .unmarked), 1)
        XCTAssertEqual(score.support(.question), 1)
    }

    func testParagraphsAreScoredOnAlignedBoundaries() {
        let score = PunctuationScorer.score(
            reference: "Guten Tag.\n\nDanke für die Antwort.",
            hypothesis: "Guten Tag. Danke für die Antwort.\nBis bald.",
            language: .german
        )

        XCTAssertEqual(score.paragraphMisses, 1)
        XCTAssertEqual(score.paragraphFalseAlarms, 1, "the break before an inserted sentence was not asked for")
        XCTAssertEqual(try XCTUnwrap(score.paragraphRecall), 0)
    }

    func testScoresPoolByAddition() {
        let first = PunctuationScorer.score(reference: "Are you there?", hypothesis: "Are you there?", language: .english)
        let second = PunctuationScorer.score(reference: "Is it done?", hypothesis: "Is it done.", language: .english)

        let pooled = first + second
        XCTAssertEqual(pooled.support(.question), 2)
        XCTAssertEqual(try XCTUnwrap(pooled.recall(.question)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(pooled.precision(.question)), 1, accuracy: 0.0001)
    }

    func testFinalMark() {
        XCTAssertEqual(PunctuationScorer.finalMark("Чи ти вдома?", language: .ukrainian), .question)
        XCTAssertEqual(PunctuationScorer.finalMark("чи ти вдома", language: .ukrainian), .unmarked)
        XCTAssertEqual(PunctuationScorer.finalMark("", language: .ukrainian), .unmarked)
    }
}
