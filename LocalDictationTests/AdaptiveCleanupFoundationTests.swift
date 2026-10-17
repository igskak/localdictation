import XCTest
@testable import Witness

final class AdaptiveCleanupFoundationTests: XCTestCase {
    private let service = AdaptiveCleanupService()

    func testVerbatimIsAnIdentity() {
        let raw = "  uh hello comma  "
        let result = service.clean(raw, language: .english, options: CleanupOptions(level: .verbatim))
        XCTAssertEqual(result.cleaned, raw)
        XCTAssertFalse(result.map.hasEdits)
        XCTAssertTrue(result.edits.isEmpty)
    }

    func testConservativeHasExactParityWithTheExistingService() {
        let legacy = ConservativeCleanupService()
        for language in SpeechLanguage.verified {
            let raw = "  uh ähм ээ ее hello 1450 euro  "
            XCTAssertEqual(
                service.clean(raw, language: language, options: CleanupOptions(level: .conservative)),
                legacy.clean(raw, language: language)
            )
        }
    }

    func testCleanBeginsAsConservativeUntilMeasuredRulesLand() {
        let raw = "hello comma world"
        XCTAssertEqual(
            service.clean(raw, language: .english, options: CleanupOptions(level: .clean)),
            service.clean(raw, language: .english, options: CleanupOptions(level: .conservative))
        )
    }

    func testProtectedDetectorFindsFactsNegationGlossaryAndEntities() {
        let glossary = [GlossaryEntry(term: "Acme Cloud", language: .english)]
        let spans = ProtectedSpanDetector().detect(
            in: "Send not 20 euro to Acme Cloud on Friday",
            language: .english,
            glossary: glossary
        )
        XCTAssertTrue(spans.contains { $0.category == .negation && $0.text == "not" })
        XCTAssertTrue(spans.contains { $0.category == .number && $0.text == "20" })
        XCTAssertTrue(spans.contains { $0.category == .currency && $0.text == "euro" })
        XCTAssertTrue(spans.contains { $0.category == .glossary && $0.text == "Acme Cloud" })
        XCTAssertTrue(spans.contains { $0.category == .date && $0.text == "Friday" })
    }

    func testProtectedConflictAllowsOnlyAnOwningWholeSpanEdit() throws {
        let span = try XCTUnwrap(ProtectedSpanDetector().detect(in: "not", language: .english).first)
        XCTAssertFalse(ProtectedSpanDetector.allows(proposed: 0..<3, protected: [span]))
        XCTAssertFalse(ProtectedSpanDetector.allows(proposed: 0..<2, protected: [span], owningWholeSpan: .negation))
        XCTAssertTrue(ProtectedSpanDetector.allows(proposed: 0..<3, protected: [span], owningWholeSpan: .negation))
    }
}
