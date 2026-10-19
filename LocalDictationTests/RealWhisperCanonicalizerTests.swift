import XCTest
@testable import Witness

final class RealWhisperCanonicalizerTests: XCTestCase {
    func testClosedCompoundsAndRawMap() {
        for (language, raw, canonical) in [
            (SpeechLanguage.russian, "во - первых", "во-первых"),
            (.russian, "Во -первых", "Во-первых"),
            (.russian, "какой -то", "какой-то"),
            (.russian, "когда -нибудь", "когда-нибудь"),
            (.russian, "опять -таки", "опять-таки"),
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
        for raw in ["два - три", "да - нет", "x/во - первых", "во - первых@example.com"] {
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

    func testPercentageSpacingUsesLocaleAndProtectsIdentifiers() {
        let canonicalizer = RealWhisperCanonicalizer()
        XCTAssertEqual(canonicalizer.transform("20 %", language: .english, glossary: []).cleaned, "20%")
        for language in [SpeechLanguage.german, .russian, .ukrainian] {
            XCTAssertEqual(canonicalizer.transform("20 %", language: language, glossary: []).cleaned, "20 %")
        }
        for raw in ["id20 %", "v/20 %", "20 %foo"] {
            XCTAssertEqual(canonicalizer.transform(raw, language: .english, glossary: []).cleaned, raw)
        }
    }

    func testEnglishPrefixCurrencySpacingAndFences() {
        let canonicalizer = RealWhisperCanonicalizer()
        for (raw, expected) in [("$ 25", "$25"), ("£ 25.50", "£25.50")] {
            let result = canonicalizer.transform(raw, language: .english, glossary: [])
            XCTAssertEqual(result.cleaned, expected)
            XCTAssertEqual(result.map.rawRange(forCleaned: 0..<expected.count), 0..<raw.count)
            XCTAssertEqual(canonicalizer.transform(expected, language: .english, glossary: []).cleaned, expected)
        }
        for raw in ["id$ 25", "path/$ 25", "$ 25.123", "$ 25,000", "$ 25abc", "$ 25%"] {
            XCTAssertEqual(canonicalizer.transform(raw, language: .english, glossary: []).cleaned, raw)
        }
        XCTAssertEqual(canonicalizer.transform("$ 25", language: .german, glossary: []).cleaned, "$ 25")
    }

    func testCompleteTemperatureSpacingAndFences() {
        let canonicalizer = RealWhisperCanonicalizer()
        for language in [SpeechLanguage.english, .german, .russian, .ukrainian] {
            let raw = "20 ° C"
            let result = canonicalizer.transform(raw, language: language, glossary: [])
            XCTAssertEqual(result.cleaned, "20 °C")
            XCTAssertEqual(result.map.rawRange(forCleaned: 0..<result.cleaned.count), 0..<raw.count)
            XCTAssertEqual(canonicalizer.transform(result.cleaned, language: language, glossary: []).cleaned, result.cleaned)
        }
        for raw in ["id20 ° C", "path/20 ° C", "20 ° Celsius", "20 ° Cfoo", "-20 ° C"] {
            XCTAssertEqual(canonicalizer.transform(raw, language: .english, glossary: []).cleaned, raw)
        }
        let glossary = [GlossaryEntry(term: "20", language: .english)]
        XCTAssertEqual(canonicalizer.transform("20 ° C", language: .english, glossary: glossary).cleaned, "20 ° C")
    }

    func testCompleteUnitSpacingAndIdentifierFences() {
        let canonicalizer = RealWhisperCanonicalizer()
        for language in [SpeechLanguage.english, .german, .russian, .ukrainian] {
            for (raw, expected) in [("20km", "20 km"), ("2.5kg", "2.5 kg"), ("5ml", "5 ml")] {
                let result = canonicalizer.transform(raw, language: language, glossary: [])
                XCTAssertEqual(result.cleaned, expected, raw)
                XCTAssertEqual(result.map.rawRange(forCleaned: 0..<expected.count), 0..<raw.count)
                XCTAssertEqual(canonicalizer.transform(expected, language: language, glossary: []).cleaned, expected)
            }
        }
        for raw in ["id20km", "path/20km", "20kmfile", "-20km", "20km/next"] {
            XCTAssertEqual(canonicalizer.transform(raw, language: .english, glossary: []).cleaned, raw)
        }
        let glossary = [GlossaryEntry(term: "20km", language: .english)]
        XCTAssertEqual(canonicalizer.transform("20km", language: .english, glossary: glossary).cleaned, "20km")
    }

    func testNumericGlossaryEntryProtectsSurfaceValue() {
        let canonicalizer = RealWhisperCanonicalizer()
        let glossary = [GlossaryEntry(term: "25", language: .english)]
        XCTAssertEqual(canonicalizer.transform("$ 25", language: .english, glossary: glossary).cleaned, "$ 25")
        XCTAssertEqual(canonicalizer.transform("25 %", language: .english, glossary: glossary).cleaned, "25 %")
        let clockGlossary = [GlossaryEntry(term: "12", language: .english)]
        XCTAssertEqual(canonicalizer.transform("12 : 30", language: .english, glossary: clockGlossary).cleaned, "12 : 30")
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
