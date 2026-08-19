import XCTest
@testable import LocalDictation

/// Cleanup is only allowed to do four things, and the acceptance criterion is
/// that it never changes wording, numbers, or meaning. Most of these tests are
/// therefore assertions about what cleanup leaves alone.
final class ConservativeCleanupServiceTests: XCTestCase {
    private let service = ConservativeCleanupService()

    private func words(_ text: String, _ language: SpeechLanguage) -> [String] {
        WordScanner.words(in: text).map(\.text)
    }

    // MARK: - What it does

    func testSentencesAreCapitalizedAndClosed() {
        let result = service.clean("bitte überweise den betrag", language: .german)

        // Only the sentence-initial letter. German capitalizes "Betrag" too,
        // but knowing that it is a noun needs a tagged model — the engine's
        // job, not a conservative pass's.
        XCTAssertEqual(result.cleaned, "Bitte überweise den betrag.")
        XCTAssertEqual(Set(result.edits.map(\.kind)), [.capitalization, .punctuation])
    }

    func testWhitespaceIsCollapsedAndTrimmed() {
        let result = service.clean("  Der   Termin ist offen.  ", language: .german)

        XCTAssertEqual(result.cleaned, "Der Termin ist offen.")
        XCTAssertTrue(result.edits.allSatisfy { $0.kind == .spacing })
    }

    func testSpaceBeforePunctuationIsRemovedAndAddedAfterIt() {
        let result = service.clean("Der Termin ist offen .Müller wartet", language: .german)

        XCTAssertEqual(result.cleaned, "Der Termin ist offen. Müller wartet.")
    }

    func testFillersAreRemovedWithTheirAdjacentSpace() throws {
        let result = service.clean("Ich äh brauche die Rechnung", language: .german)

        XCTAssertEqual(result.cleaned, "Ich brauche die Rechnung.")
        let removal = try XCTUnwrap(result.edits.first { $0.kind == .fillerRemoval })
        XCTAssertEqual(removal.rawText, "äh ")
    }

    /// After a leading filler disappears, the word that becomes the first word
    /// is the one that gets capitalized.
    func testCapitalizationFollowsFillerRemoval() {
        let result = service.clean("ähm der termin steht", language: .german)

        XCTAssertEqual(result.cleaned, "Der termin steht.")
    }

    // MARK: - What it must not do

    func testNumbersAndAmountsAreNeverReformatted() {
        for text in ["Betrag 1450 Euro", "Betrag 1.450,00 Euro", "um 12:30 Uhr", "89 €"] {
            let result = service.clean(text, language: .german)
            XCTAssertEqual(
                words(result.cleaned, .german).filter { CriticalTokens.containsDigit($0) },
                words(text, .german).filter { CriticalTokens.containsDigit($0) },
                "cleanup rewrote a number in \(text)"
            )
        }
    }

    func testWordSequenceIsPreservedExceptForRemovedFillers() {
        let cases: [(String, SpeechLanguage)] = [
            ("bitte überweise 1450 euro bis freitag an müller", .german),
            ("переведи 1450 евро мюллеру до пятницы", .russian),
            ("переказати 1450 євро мюллеру до п'ятниці", .ukrainian),
            ("please transfer 1450 euro to miller by friday", .english),
        ]

        for (text, language) in cases {
            let result = service.clean(text, language: language)
            XCTAssertEqual(
                words(result.cleaned, language).map { $0.lowercased() },
                words(text, language).map { $0.lowercased() },
                "cleanup changed the words of \(language.rawValue)"
            )
        }
    }

    /// German capitalizes nouns and Russian does not. Cleanup never lowercases
    /// anything, so an engine that capitalized correctly is left alone in both.
    func testCapitalizationIsNeverRemoved() {
        let german = service.clean("die Rechnung über 89 Euro ist offen", language: .german)
        XCTAssertTrue(german.cleaned.contains("Rechnung"))
        XCTAssertTrue(german.cleaned.contains("Euro"))

        let russian = service.clean("Счёт открыт", language: .russian)
        XCTAssertEqual(russian.cleaned, "Счёт открыт.")
    }

    func testNegationIsNeverTouched() {
        for (text, language) in [
            ("wir liefern nicht vor dem fünfzehnten april", SpeechLanguage.german),
            ("мы не отгрузим раньше пятнадцатого апреля", .russian),
            ("ми не відвантажимо раніше п'ятнадцятого квітня", .ukrainian),
        ] {
            let result = service.clean(text, language: language)
            for negation in ["nicht", "не"] where text.contains(negation) {
                XCTAssertTrue(result.cleaned.contains(negation), "cleanup dropped “\(negation)”")
            }
        }
    }

    /// Russian «ну» and «вот» are ordinary words. A filler list that swallowed
    /// them would silently change what the user said.
    func testAmbiguousRussianWordsAreNotTreatedAsFillers() {
        let result = service.clean("ну вот и всё", language: .russian)
        XCTAssertEqual(result.cleaned, "Ну вот и всё.")
    }

    func testFillersAreLanguageKeyed() {
        // "um" is an English filler and an ordinary German preposition.
        let english = service.clean("I um need the invoice", language: .english)
        XCTAssertEqual(english.cleaned, "I need the invoice.")

        let german = service.clean("bitten um Geduld", language: .german)
        XCTAssertEqual(german.cleaned, "Bitten um Geduld.")
    }

    func testAlreadyCleanTextProducesNoEdits() {
        let result = service.clean("Der Termin steht.", language: .german)

        XCTAssertEqual(result.cleaned, result.raw)
        XCTAssertTrue(result.edits.isEmpty)
        XCTAssertFalse(result.didChangeText)
    }

    func testTextThatAlreadyEndsInPunctuationGainsNoPeriod() {
        for text in ["Ist der Termin bestätigt?", "Sofort!", "Und dann…"] {
            let result = service.clean(text, language: .german)
            XCTAssertFalse(result.edits.contains { $0.kind == .punctuation }, "added punctuation to \(text)")
        }
    }

    func testEmptyInputIsUnchanged() {
        let result = service.clean("", language: .german)
        XCTAssertEqual(result.cleaned, "")
        XCTAssertTrue(result.edits.isEmpty)
    }

    // MARK: - Options

    func testEveryRuleCanBeSwitchedOff() {
        let result = service.clean("  ähm der termin  ", language: .german, options: .none)

        XCTAssertEqual(result.cleaned, "  ähm der termin  ")
        XCTAssertTrue(result.edits.isEmpty)
    }

    // MARK: - Edit bookkeeping

    /// Every edit has to be applicable: the raw text it claims to have replaced
    /// must be what is actually there, and the cleaned text it claims to have
    /// produced must be what came out.
    func testEveryEditDescribesTheCharactersItActuallyChanged() {
        let raw = "  ähm bitte überweise 1450 euro .Müller wartet  "
        let result = service.clean(raw, language: .german)
        let rawCharacters = Array(result.raw)
        let cleanedCharacters = Array(result.cleaned)

        XCTAssertFalse(result.edits.isEmpty)
        for edit in result.edits {
            XCTAssertEqual(String(rawCharacters[edit.rawRange]), edit.rawText)
            XCTAssertEqual(String(cleanedCharacters[edit.cleanedRange]), edit.cleanedText)
        }
    }

    func testRawTextIsNeverMutated() {
        let raw = "  ähm der termin  "
        let result = service.clean(raw, language: .german)

        XCTAssertEqual(result.raw, raw, "the raw transcript must stay recoverable verbatim")
    }
}
