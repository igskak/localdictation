import XCTest
@testable import LocalDictation

/// The signal that exists because of one complaint: "проверка" came back as
/// "ррверка" unmarked, while the correctly recognized name of a messenger three
/// words later was marked as risky.
///
/// Its two gates are tested separately, because the whole design rests on them
/// being independent. The shape rule is a fact about the characters and is
/// tested with no dictionary at all; the dictionary gate is tested against a
/// fake, so nothing here depends on which spelling files a Mac happens to have.
final class MalformedWordSignalTests: XCTestCase {
    private func marks(_ text: String, language: SpeechLanguage, glossary: [GlossaryEntry] = []) -> [String] {
        let context = RiskContext(
            raw: text,
            profile: LanguageProfile(primary: language, secondary: nil),
            language: language,
            glossary: glossary
        )
        let signal = MalformedWordSignal(lexicon: ShapeOnlyLexicon())
        let characters = Array(text)
        return signal.spans(in: context).map { String(characters[$0.range]) }
    }

    // MARK: - The shape rule

    func testADoubledConsonantAtTheStartOfAWordIsImpossible() {
        XCTAssertTrue(MalformedWordSignal.hasImpossibleShape("ррверка", language: .russian))
        XCTAssertTrue(MalformedWordSignal.hasImpossibleShape("пперевірка", language: .ukrainian))
        XCTAssertTrue(MalformedWordSignal.hasImpossibleShape("ttermin", language: .german), "German keeps this rule")
    }

    func testALongConsonantRunWithNoVowelIsImpossible() {
        XCTAssertTrue(MalformedWordSignal.hasImpossibleShape("схкртнвл", language: .russian))
        XCTAssertTrue(MalformedWordSignal.hasImpossibleShape("abkrtlnst", language: .english))
    }

    /// The measurement that shaped this signal. The system dictionary does not
    /// contain any of these, and marking them is the failure mode being fixed
    /// rather than the fix — so the shape rule has to let all of them through
    /// on its own.
    func testOrdinaryTechnicalVocabularyIsNotImpossible() {
        for word in ["деплой", "коммит", "бэкенд", "апи", "аутентификация", "Скаковский", "Флок"] {
            XCTAssertFalse(MalformedWordSignal.hasImpossibleShape(word, language: .russian), "\(word) is a word somebody says on purpose")
        }
        for word in ["webhook", "Kubernetes", "strengths"] {
            XCTAssertFalse(MalformedWordSignal.hasImpossibleShape(word, language: .english), "\(word) is a word somebody says on purpose")
        }
        XCTAssertFalse(MalformedWordSignal.hasImpossibleShape("бодрствовать", language: .russian))
    }

    /// German compounds pile consonants up at their seams, and they are
    /// correct doing it. The run rule is switched off there rather than tuned.
    func testGermanCompoundsAreNotImpossible() {
        for word in ["Angstschweiß", "Softwareentwicklungsprozess", "Verabredung", "Herbstwetter"] {
            XCTAssertFalse(MalformedWordSignal.hasImpossibleShape(word, language: .german), "\(word) is ordinary German")
        }
        XCTAssertFalse(MalformedWordSignal.usesConsonantRunRule(.german))
    }

    func testAWordWithNoVowelAtAllIsImpossible() {
        XCTAssertTrue(MalformedWordSignal.hasImpossibleShape("нстрм", language: .russian))
    }

    func testShortWordsAreNeverJudged() {
        for word in ["мы", "не", "in", "der", "тут"] {
            XCTAssertFalse(MalformedWordSignal.hasImpossibleShape(word, language: .russian))
        }
    }

    // MARK: - The signal

    func testTheOriginalComplaintIsMarked() {
        XCTAssertEqual(marks("ррверка прошла успешно", language: .russian), ["ррверка"])
    }

    func testTheWordItWasConfusedWithIsNotMarked() {
        XCTAssertTrue(marks("проверка прошла успешно", language: .russian).isEmpty)
    }

    /// The other half of the same complaint. A messenger's name is not a
    /// malformed word, and this signal must not become a second way to mark it.
    func testACorrectlyRecognizedNameIsNotMarked() {
        XCTAssertTrue(marks("обсуждение перенесли во Флок", language: .russian).isEmpty)
    }

    func testAcronymsAreLeftToTheEntitySignal() {
        XCTAssertTrue(marks("отправь через SMTP сегодня", language: .russian).isEmpty)
        XCTAssertTrue(marks("send it over SMTP today", language: .english).isEmpty)
    }

    func testNumbersAreLeftToTheNumberSignal() {
        XCTAssertTrue(marks("переведи 1450 евро", language: .russian).isEmpty)
    }

    /// A term the user typed into their dictionary is a word, whatever its
    /// shape and whatever a spelling file thinks.
    func testAGlossaryTermIsNeverMalformed() {
        let glossary = [GlossaryEntry(term: "Ррверк", language: .russian)]
        XCTAssertTrue(marks("проект Ррверк закрыт", language: .russian, glossary: glossary).isEmpty)
    }

    // MARK: - The dictionary gate

    /// Shape alone is not enough. A word the dictionary knows is a word, even
    /// if the shape rule dislikes it — which is what keeps the signal honest
    /// about the languages it cannot fully model.
    func testAKnownWordIsNeverMarkedHoweverOddItsShape() {
        struct KnowsEverything: LexiconChecking {
            func supports(_ language: SpeechLanguage) -> Bool { true }
            func isKnownWord(_ word: String, language: SpeechLanguage) -> Bool { true }
        }
        let context = RiskContext(raw: "ррверка прошла", profile: .russian, language: .russian)

        XCTAssertTrue(MalformedWordSignal(lexicon: KnowsEverything()).spans(in: context).isEmpty)
    }

    /// A missing dictionary is missing evidence, and the signal says nothing
    /// rather than guessing.
    func testNoDictionaryMeansNoMarks() {
        let context = RiskContext(raw: "ррверка прошла", profile: .russian, language: .russian)

        XCTAssertTrue(MalformedWordSignal(lexicon: EmptyLexicon()).spans(in: context).isEmpty)
    }

    // MARK: - Weighting

    /// The signal exists to be believed, so it is priced above the attention
    /// threshold: a word that is not a word is worth the triangle on its own.
    func testAMalformedWordEarnsTheIndicatorOnItsOwn() {
        XCTAssertGreaterThanOrEqual(
            RiskWeights.default.weight(for: .malformedWord, profile: .russian),
            ReviewPolicy.default.attentionThreshold
        )
    }
}
