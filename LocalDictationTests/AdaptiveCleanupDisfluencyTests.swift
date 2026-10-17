import XCTest
@testable import Witness

final class AdaptiveCleanupDisfluencyTests: XCTestCase {
    private let service = AdaptiveCleanupService()

    func testExplicitCorrectionMarkersInEveryVerifiedLanguage() {
        let fixtures: [(SpeechLanguage, String, String)] = [
            (.english, "send it Tuesday correction Thursday", "Send it Thursday."),
            (.german, "schick es Dienstag Korrektur Donnerstag", "Schick es Donnerstag."),
            (.russian, "отправь во вторник поправка четверг", "Отправь во четверг."),
            (.ukrainian, "надішли у вівторок виправлення четвер", "Надішли у четвер."),
        ]
        for (language, raw, expected) in fixtures {
            let result = service.clean(raw, language: language, options: CleanupOptions(level: .clean))
            XCTAssertEqual(result.cleaned, expected, language.rawValue)
            XCTAssertTrue(result.edits.contains { $0.kind == .explicitCorrection })
        }
    }

    func testCorrectionRefusesToDeleteProtectedValueForOrdinaryReplacement() {
        let result = service.clean(
            "send 20 correction parcels",
            language: .english,
            options: CleanupOptions(level: .clean)
        )
        XCTAssertEqual(result.cleaned, "Send 20 correction parcels.")
        XCTAssertFalse(result.edits.contains { $0.kind == .explicitCorrection })
    }

    func testBareMarkerLikeWordsStayLiteral() {
        let fixtures: [(SpeechLanguage, String)] = [
            (.english, "actually this works"),
            (.german, "eigentlich funktioniert das"),
            (.russian, "нет это слово"),
            (.ukrainian, "точніше це слово"),
        ]
        for (language, raw) in fixtures {
            let result = service.clean(raw, language: language, options: CleanupOptions(level: .clean))
            XCTAssertTrue(result.cleaned.lowercased().contains(WordScanner.words(in: raw)[0].lowercased))
            XCTAssertFalse(result.edits.contains { $0.kind == .explicitCorrection })
        }
    }

    func testAdjacentExactTokenAndNGramRepetitionsAreRemoved() {
        XCTAssertEqual(clean("the the report"), "The report.")
        XCTAssertEqual(clean("we should we should leave"), "We should leave.")
    }

    func testEmphasisSentenceBoundariesAndProtectedValuesRemain() {
        XCTAssertEqual(clean("very very good"), "Very very good.")
        XCTAssertEqual(clean("go. go"), "Go. Go.")
        XCTAssertEqual(clean("20 20"), "20 20.")
        XCTAssertEqual(clean("not not ready"), "Not not ready.")
    }

    private func clean(_ raw: String) -> String {
        service.clean(raw, language: .english, options: CleanupOptions(level: .clean)).cleaned
    }
}
