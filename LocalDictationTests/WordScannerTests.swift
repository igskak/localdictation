import XCTest
@testable import LocalDictation

/// The scanner is what every risk signal stands on, and its offsets are what
/// the review strip highlights. A word located one character off would mark the
/// wrong fragment in a way no other test would notice.
final class WordScannerTests: XCTestCase {
    func testWordsCarryTheirCharacterOffsets() {
        let words = WordScanner.words(in: "Bitte 1450 Euro")

        XCTAssertEqual(words.map(\.text), ["Bitte", "1450", "Euro"])
        XCTAssertEqual(words.map(\.range), [0..<5, 6..<10, 11..<15])
    }

    /// Offsets are `Character` counts, so a multi-byte letter occupies exactly
    /// one position — the property Phase 3 spans depend on.
    func testUmlautsAndCyrillicCountAsSingleCharacters() {
        let german = WordScanner.words(in: "Müller zahlt")
        XCTAssertEqual(german[0].range, 0..<6)
        XCTAssertEqual(german[1].range, 7..<12)

        let text = "Переведи 1450 евро"
        let russian = WordScanner.words(in: text)
        XCTAssertEqual(russian.map(\.text), ["Переведи", "1450", "евро"])
        let characters = Array(text)
        for word in russian {
            XCTAssertEqual(String(characters[word.range]), word.text)
        }
    }

    func testNumberSeparatorsStayInsideTheNumber() {
        XCTAssertEqual(WordScanner.words(in: "Betrag 1.450,00 Euro").map(\.text), ["Betrag", "1.450,00", "Euro"])
        XCTAssertEqual(WordScanner.words(in: "um 12:30 Uhr").map(\.text), ["um", "12:30", "Uhr"])
    }

    func testSentencePunctuationDoesNotJoinWords() {
        let words = WordScanner.words(in: "Erstens. Zweitens")
        XCTAssertEqual(words.map(\.text), ["Erstens", "Zweitens"])
    }

    func testApostrophesAndHyphensStayInsideWords() {
        XCTAssertEqual(WordScanner.words(in: "з'їзд").map(\.text), ["з'їзд"])
        XCTAssertEqual(WordScanner.words(in: "don't stop").map(\.text), ["don't", "stop"])
        XCTAssertEqual(WordScanner.words(in: "Schmidt-Meyer kam").map(\.text), ["Schmidt-Meyer", "kam"])
    }

    /// A trailing hyphen belongs to punctuation, not to the word before it.
    func testATrailingJoinerIsNotPartOfTheWord() {
        let words = WordScanner.words(in: "Meyer- und Schmidt")
        XCTAssertEqual(words.map(\.text), ["Meyer", "und", "Schmidt"])
    }

    func testSentenceInitialIsOnlyTrueAfterATerminator() {
        let words = WordScanner.words(in: "Der Termin ist offen. Müller wartet")

        XCTAssertEqual(words.filter(\.isSentenceInitial).map(\.text), ["Der", "Müller"])
    }

    func testEmptyTextProducesNoWords() {
        XCTAssertTrue(WordScanner.words(in: "").isEmpty)
        XCTAssertTrue(WordScanner.words(in: "  … ").isEmpty)
    }
}
