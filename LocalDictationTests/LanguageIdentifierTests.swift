import XCTest
@testable import Witness

/// The identifier is deliberately allowed to say "I don't know", and most of
/// these tests assert exactly that: a confident wrong answer would spend the
/// false-warning budget on nothing.
final class LanguageIdentifierTests: XCTestCase {
    func testScriptSeparatesCyrillicFromLatin() {
        XCTAssertEqual(LanguageIdentifier.script(of: "Rechnung"), .latin)
        XCTAssertEqual(LanguageIdentifier.script(of: "рахунок"), .cyrillic)
        XCTAssertEqual(LanguageIdentifier.script(of: "1450"), .neutral)
        XCTAssertEqual(LanguageIdentifier.script(of: "€"), .neutral)
    }

    func testExclusiveLettersIdentifyRussianAndUkrainian() {
        XCTAssertEqual(LanguageIdentifier.language(of: "открыт"), .russian)
        XCTAssertEqual(LanguageIdentifier.language(of: "відкритий"), .ukrainian)
        XCTAssertEqual(LanguageIdentifier.language(of: "п'ятниці"), .ukrainian)
    }

    func testGermanIsIdentifiedOnlyByItsOwnLetters() {
        XCTAssertEqual(LanguageIdentifier.language(of: "Müller"), .german)
        XCTAssertEqual(LanguageIdentifier.language(of: "Straße"), .german)
        XCTAssertNil(
            LanguageIdentifier.language(of: "Termin"),
            "a German word without an umlaut is indistinguishable from an English one"
        )
    }

    func testAWordSharedByBothLanguagesOfAPairYieldsNoEvidence() {
        XCTAssertNil(LanguageIdentifier.language(of: "тому"))
        XCTAssertNil(LanguageIdentifier.language(of: "meeting"))
    }

    func testScriptMatchingIsProfileAware() {
        XCTAssertTrue(LanguageIdentifier.scriptMatches("meeting", profile: .russianEnglish))
        XCTAssertFalse(LanguageIdentifier.scriptMatches("meeting", profile: .russian))
        XCTAssertTrue(LanguageIdentifier.scriptMatches("рахунок", profile: .russianUkrainian))
        XCTAssertFalse(LanguageIdentifier.scriptMatches("рахунок", profile: .germanEnglish))
        XCTAssertTrue(LanguageIdentifier.scriptMatches("1450", profile: .german), "digits carry no script evidence")
    }
}
