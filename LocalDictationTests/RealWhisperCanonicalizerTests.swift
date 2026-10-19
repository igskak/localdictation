import XCTest
@testable import Witness

final class RealWhisperCanonicalizerTests: XCTestCase {
    func testClosedCompoundsAndRawMap() {
        for (language, raw, canonical) in [
            (SpeechLanguage.russian, "во - первых", "во-первых"),
            (.russian, "во - вторых", "во-вторых"),
            (.ukrainian, "по - перше", "по-перше"),
            (.ukrainian, "по - друге", "по-друге"),
        ] {
            let result = RealWhisperCanonicalizer().transform(raw, language: language, glossary: [])
            XCTAssertEqual(result.raw, raw)
            XCTAssertEqual(result.cleaned, canonical)
            XCTAssertEqual(result.map.cleanedRange(forRaw: 0..<raw.count), 0..<canonical.count)
            XCTAssertEqual(result.map.rawRange(forCleaned: 0..<canonical.count), 0..<raw.count)
            XCTAssertEqual(result.edits.map(\.kind), [.surfaceNormalization])
            XCTAssertEqual(RealWhisperCanonicalizer().transform(result.cleaned, language: language, glossary: []).cleaned, canonical)
        }
    }

    func testLiteralDashesAndIdentifierFragmentsRemainLiteral() {
        for raw in ["два - три", "x/во - первых", "во - первых@example.com"] {
            XCTAssertEqual(RealWhisperCanonicalizer().transform(raw, language: .russian, glossary: []).cleaned, raw)
        }
    }

    func testCompleteSpacedClockAndIdentifierFences() {
        let service = AdaptiveCleanupService()
        for language in [SpeechLanguage.english, .german, .russian, .ukrainian] {
            let result = service.clean("12 : 30", language: language, options: CleanupOptions(level: .conservative))
            XCTAssertTrue(result.cleaned.contains("12:30"))
            XCTAssertEqual(result.raw, "12 : 30")
            XCTAssertEqual(result.edits.first?.kind, .surfaceNormalization)
        }
        let canonicalizer = RealWhisperCanonicalizer()
        for raw in ["24 : 30", "12 : 99", "1/12 : 30", "12 : 30.4", "id12 : 30"] {
            XCTAssertEqual(canonicalizer.transform(raw, language: .english, glossary: []).cleaned, raw)
        }
    }

    func testVerbatimRemainsExactAndConservativeDoesNotExecuteCommands() {
        let raw = "во - первых двоеточие"
        let service = AdaptiveCleanupService()
        XCTAssertEqual(service.clean(raw, language: .russian, options: CleanupOptions(level: .verbatim)).cleaned, raw)
        let result = service.clean(raw, language: .russian, options: CleanupOptions(level: .conservative))
        XCTAssertTrue(result.cleaned.lowercased().contains("во-первых"))
        XCTAssertTrue(result.cleaned.contains("двоеточие"))
        XCTAssertEqual(result.raw, raw)
    }
}
