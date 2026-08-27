import WhisperKit
import XCTest
@testable import LocalDictation

/// The catalog is data, and data that nobody checks drifts.
///
/// The important assertion is the first one: the app's language list and the
/// engine's language list are the same list. A WhisperKit upgrade that adds a
/// language, or renames a code, fails here rather than in a picker that offers
/// a language the decoder then refuses.
final class LanguageCatalogTests: XCTestCase {
    func testTheCatalogIsExactlyWhatTheEngineKnows() {
        XCTAssertEqual(
            Set(LanguageCatalog.all.map(\.code)),
            Constants.languageCodes,
            "The picker must not offer a language the decoder cannot be pinned to, or hide one it can"
        )
    }

    func testEveryCodeAppearsOnce() {
        let codes = LanguageCatalog.all.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count, "Whisper's table carries aliases; the catalog must not")
    }

    func testEveryEntryIsNamedInBothPlaces() {
        for entry in LanguageCatalog.all {
            XCTAssertFalse(entry.englishName.isEmpty, "\(entry.code) has no English name")
            XCTAssertFalse(entry.nativeName.isEmpty, "\(entry.code) has no native name")
        }
    }

    /// The picker shows the catalog in order and does not sort it itself.
    func testTheCatalogIsSortedByEnglishName() {
        XCTAssertEqual(
            LanguageCatalog.all.map(\.englishName),
            LanguageCatalog.all.map(\.englishName).sorted()
        )
    }

    func testTheVerifiedTierIsTheFourLanguagesTheProductMeasures() throws {
        XCTAssertEqual(Set(SpeechLanguage.verified), [.german, .english, .russian, .ukrainian])
        XCTAssertTrue(SpeechLanguage.verified.allSatisfy(\.isVerified))
        XCTAssertFalse(try XCTUnwrap(SpeechLanguage(rawValue: "pl")).isVerified)
    }

    func testTheFlagsThatAreThisProductsOwnPointAtRealLanguages() {
        let codes = Set(LanguageCatalog.all.map(\.code))
        XCTAssertTrue(LanguageCatalog.verifiedCodes.isSubset(of: codes))
        XCTAssertTrue(LanguageCatalog.nounCapitalizingCodes.isSubset(of: codes))
        XCTAssertTrue(SpeechLanguage.german.capitalizesNouns)
        XCTAssertFalse(SpeechLanguage.english.capitalizesNouns)
    }

    func testScriptsSeparateTheOnlyTwoTheRulesCanRead() {
        XCTAssertEqual(SpeechLanguage.russian.script, .cyrillic)
        XCTAssertEqual(SpeechLanguage.ukrainian.script, .cyrillic)
        XCTAssertEqual(SpeechLanguage.german.script, .latin)
        XCTAssertEqual(SpeechLanguage(rawValue: "ja")?.script, .other)
        XCTAssertEqual(SpeechLanguage(rawValue: "bg")?.script, .cyrillic)
    }

    // MARK: - The type over the catalog

    func testACodeTheEngineDoesNotKnowIsNotALanguage() {
        XCTAssertNil(SpeechLanguage(rawValue: "klingon"))
        XCTAssertNil(SpeechLanguage(rawValue: ""))
        XCTAssertNil(SpeechLanguage(rawValue: "DE"), "Codes are lowercase, and the decoder is not asked to guess")
    }

    /// Terms saved since Phase 3 carry a bare code. A struct that encoded
    /// itself as an object would orphan every one of them.
    func testALanguageEncodesAsItsBareCode() throws {
        let data = try JSONEncoder().encode(SpeechLanguage.ukrainian)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"uk\"")
        XCTAssertEqual(try JSONDecoder().decode(SpeechLanguage.self, from: data), .ukrainian)
    }

    func testDecodingAnUnknownCodeSaysWhatIsWrong() throws {
        let data = Data("\"klingon\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SpeechLanguage.self, from: data)) { error in
            guard case let DecodingError.dataCorrupted(context) = error else {
                return XCTFail("Expected a data-corrupted error, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("klingon"))
        }
    }

    func testLanguagesSortByTheNameTheUserReads() {
        XCTAssertEqual([SpeechLanguage.ukrainian, .german, .russian].sorted(), [.german, .russian, .ukrainian])
    }
}
