import XCTest
@testable import Witness

final class TextNormalizerTests: XCTestCase {
    func testPunctuationIsStrippedButWordInternalMarksSurvive() {
        let normalizer = TextNormalizer.default
        XCTAssertEqual(
            normalizer.words("Hello, world! It's fine.", language: .english),
            ["hello", "world", "it's", "fine"]
        )
    }

    func testTypographicApostrophesFoldToOneForm() {
        let normalizer = TextNormalizer.default
        XCTAssertEqual(
            normalizer.words("з\u{2019}їзд", language: .ukrainian),
            normalizer.words("з'їзд", language: .ukrainian)
        )
    }

    /// Russian `ё` is routinely written as `е`; treating them as different
    /// letters would inflate every Russian error rate.
    func testRussianYoFoldsToYe() {
        let normalizer = TextNormalizer.default
        XCTAssertEqual(normalizer.normalize("ёлка", language: .russian), "елка")
    }

    /// Ukrainian `і`, `ї`, and `є` are distinct letters, not variants.
    func testUkrainianLettersAreNotFolded() {
        let normalizer = TextNormalizer.default
        XCTAssertEqual(normalizer.normalize("їжа", language: .ukrainian), "їжа")
        XCTAssertNotEqual(
            normalizer.normalize("сіль", language: .ukrainian),
            normalizer.normalize("силь", language: .ukrainian)
        )
    }

    func testGermanUmlautsSurviveNormalization() {
        let normalizer = TextNormalizer.default
        XCTAssertEqual(normalizer.normalize("Größe prüfen.", language: .german), "größe prüfen")
    }

    func testCharactersDropWhitespaceSoCERMeasuresLetters() {
        let normalizer = TextNormalizer.default
        XCTAssertEqual(String(normalizer.characters("a b c", language: .english)), "abc")
    }
}

final class TranscriptionScorerTests: XCTestCase {
    func testIdenticalTextScoresZero() {
        let rate = TranscriptionScorer.wordErrorRate(
            reference: "the invoice is due friday",
            hypothesis: "the invoice is due friday",
            language: .english
        )
        XCTAssertEqual(rate.errors, 0)
        XCTAssertEqual(rate.rate, 0)
    }

    func testSubstitutionDeletionAndInsertionAreCountedSeparately() {
        // reference:  a b c d
        // hypothesis: a x c d e   -> 1 substitution (b→x), 1 insertion (e)
        let rate = TranscriptionScorer.wordErrorRate(
            reference: "a b c d",
            hypothesis: "a x c d e",
            language: .english
        )
        XCTAssertEqual(rate.substitutions, 1)
        XCTAssertEqual(rate.insertions, 1)
        XCTAssertEqual(rate.deletions, 0)
        XCTAssertEqual(rate.referenceCount, 4)
        XCTAssertEqual(try XCTUnwrap(rate.rate), 0.5, accuracy: 0.0001)
    }

    func testDeletionIsCounted() {
        let rate = TranscriptionScorer.wordErrorRate(
            reference: "a b c",
            hypothesis: "a c",
            language: .english
        )
        XCTAssertEqual(rate.deletions, 1)
        XCTAssertEqual(rate.substitutions, 0)
        XCTAssertEqual(rate.insertions, 0)
    }

    func testEmptyHypothesisDeletesEveryReferenceWord() {
        let rate = TranscriptionScorer.wordErrorRate(
            reference: "one two three",
            hypothesis: "",
            language: .english
        )
        XCTAssertEqual(rate.deletions, 3)
        XCTAssertEqual(try XCTUnwrap(rate.rate), 1.0, accuracy: 0.0001)
    }

    /// A rate against an empty reference is not a measurement, so it must not
    /// silently report a flattering zero.
    func testEmptyReferenceHasNoRate() {
        let rate = TranscriptionScorer.wordErrorRate(
            reference: "",
            hypothesis: "spurious words",
            language: .english
        )
        XCTAssertNil(rate.rate)
        XCTAssertEqual(rate.insertions, 2)
    }

    func testCharacterErrorRateIsFinerThanWordErrorRate() {
        let word = TranscriptionScorer.wordErrorRate(
            reference: "invoice",
            hypothesis: "invoces",
            language: .english
        )
        let character = TranscriptionScorer.characterErrorRate(
            reference: "invoice",
            hypothesis: "invoces",
            language: .english
        )

        XCTAssertEqual(try XCTUnwrap(word.rate), 1.0, accuracy: 0.0001)
        XCTAssertLessThan(try XCTUnwrap(character.rate), 0.5)
    }

    func testErrorRatesAddUpAcrossSamples() {
        let combined = ErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceCount: 4)
            + ErrorRate(substitutions: 0, deletions: 2, insertions: 1, referenceCount: 6)
        XCTAssertEqual(combined.errors, 4)
        XCTAssertEqual(combined.referenceCount, 10)
        XCTAssertEqual(try XCTUnwrap(combined.rate), 0.4, accuracy: 0.0001)
    }

    // MARK: - Product-critical selection

    /// The whole point of the product: a sentence can be almost perfect and
    /// still be wrong in the one place that matters.
    func testNumericErrorRateIsolatesTheAmountFromTheSentence() {
        let reference = "please transfer 1450 euro on monday"
        let hypothesis = "please transfer 1415 euro on monday"

        let overall = TranscriptionScorer.wordErrorRate(
            reference: reference,
            hypothesis: hypothesis,
            language: .english
        )
        let numeric = TranscriptionScorer.errorRate(
            reference: reference,
            hypothesis: hypothesis,
            language: .english,
            selecting: CriticalTokens.isNumeric
        )

        XCTAssertEqual(try XCTUnwrap(overall.rate), 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(numeric.referenceCount, 2, "1450 and euro are both critical tokens")
        XCTAssertEqual(numeric.substitutions, 1)
        XCTAssertEqual(try XCTUnwrap(numeric.rate), 0.5, accuracy: 0.0001)
    }

    func testNumericSelectionRecognizesSpelledOutNumbersInEveryLanguage() {
        XCTAssertTrue(CriticalTokens.isNumeric("fünfzig"))
        XCTAssertTrue(CriticalTokens.isNumeric("fifty"))
        XCTAssertTrue(CriticalTokens.isNumeric("пятьдесят"))
        XCTAssertTrue(CriticalTokens.isNumeric("п'ятдесят"))
        XCTAssertTrue(CriticalTokens.isNumeric("2026"))
        XCTAssertTrue(CriticalTokens.isNumeric("€99"))
        XCTAssertFalse(CriticalTokens.isNumeric("rechnung"))
    }

    func testSelectedRateIgnoresErrorsOutsideTheSelection() {
        let numeric = TranscriptionScorer.errorRate(
            reference: "invoice 42 attached",
            hypothesis: "invoyce 42 attached",
            language: .english,
            selecting: CriticalTokens.isNumeric
        )
        XCTAssertEqual(numeric.errors, 0)
        XCTAssertEqual(numeric.referenceCount, 1)
    }

    // MARK: - Calibration

    func testCalibrationSeparatesConfidentCorrectTokensFromWrongOnes() {
        let transcript = Transcript.fixture(
            words: [("the", 0.95), ("invoice", 0.93), ("is", 0.9), ("1415", 0.2)],
            profile: .english
        )

        let calibration = TranscriptionScorer.calibration(
            of: transcript,
            reference: "the invoice is 1450",
            language: .english,
            threshold: 0.5
        )

        XCTAssertEqual(calibration.correctCount, 3)
        XCTAssertEqual(calibration.incorrectCount, 1)
        XCTAssertEqual(try XCTUnwrap(calibration.recall), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(calibration.falseWarningRate), 0.0, accuracy: 0.0001)
        XCTAssertGreaterThan(try XCTUnwrap(calibration.separation), 0.5)
    }

    /// The disqualifying case: the engine is just as confident when it is wrong.
    /// Phase 3 would have nothing to point at, and the benchmark has to say so.
    func testFlatConfidenceProducesNoSeparation() {
        let transcript = Transcript.fixture(
            words: [("the", 0.9), ("invoice", 0.9), ("is", 0.9), ("1415", 0.9)],
            profile: .english
        )

        let calibration = TranscriptionScorer.calibration(
            of: transcript,
            reference: "the invoice is 1450",
            language: .english,
            threshold: 0.5
        )

        XCTAssertEqual(try XCTUnwrap(calibration.separation), 0.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(calibration.recall), 0.0, accuracy: 0.0001)
    }

    func testCalibrationIsUnavailableWithoutAConfidenceSignal() {
        let transcript = Transcript.fixture(
            words: [("the", nil), ("invoice", nil)],
            profile: .english
        )

        let calibration = TranscriptionScorer.calibration(
            of: transcript,
            reference: "the invoice",
            language: .english,
            threshold: 0.5
        )

        XCTAssertNil(calibration.separation)
        XCTAssertNil(calibration.recall)
        XCTAssertEqual(calibration.correctCount, 2)
    }

    /// A hallucinated extra word is an error with no reference position, and its
    /// confidence still has to participate in calibration.
    func testInsertedTokensCountAsIncorrect() {
        let transcript = Transcript.fixture(
            words: [("the", 0.9), ("invoice", 0.9), ("please", 0.3)],
            profile: .english
        )

        let calibration = TranscriptionScorer.calibration(
            of: transcript,
            reference: "the invoice",
            language: .english,
            threshold: 0.5
        )

        XCTAssertEqual(calibration.correctCount, 2)
        XCTAssertEqual(calibration.incorrectCount, 1)
        XCTAssertEqual(try XCTUnwrap(calibration.recall), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(calibration.falseWarningRate), 0.0, accuracy: 0.0001)
    }

    /// When the same word repeats, which copy counts as the insertion is
    /// genuinely ambiguous. The totals must still be right.
    func testRepeatedWordInsertionIsCountedOnceOverall() {
        let transcript = Transcript.fixture(
            words: [("the", 0.9), ("the", 0.3), ("invoice", 0.9)],
            profile: .english
        )

        let calibration = TranscriptionScorer.calibration(
            of: transcript,
            reference: "the invoice",
            language: .english,
            threshold: 0.5
        )

        XCTAssertEqual(calibration.correctCount, 2)
        XCTAssertEqual(calibration.incorrectCount, 1)
    }

    // MARK: - Alignment

    func testAlignmentMarksOnlyRealErrors() {
        let operations = TranscriptionScorer.align(
            reference: ["a", "b", "c"],
            hypothesis: ["a", "x", "c"]
        )
        XCTAssertEqual(operations.filter(\.isError).count, 1)
        XCTAssertEqual(operations.count, 3)
    }

    func testAlignmentHandlesTwoEmptySequences() {
        let operations = TranscriptionScorer.align(reference: [String](), hypothesis: [String]())
        XCTAssertTrue(operations.isEmpty)
    }
}
