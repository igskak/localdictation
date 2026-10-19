import XCTest
@testable import Witness

final class AdaptiveCleanupStructureTests: XCTestCase {
    private let service = AdaptiveCleanupService()

    func testOrderedListsRequireAColonAndTwoExplicitMarkers() {
        let fixtures: [(SpeechLanguage, String, String)] = [
            (.english, "shopping colon first apples second pears", "Shopping:\n1. Apples\n2. Pears."),
            (.german, "einkauf doppelpunkt erstens äpfel zweitens birnen", "Einkauf:\n1. Äpfel\n2. Birnen."),
            (.russian, "покупки двоеточие во-первых яблоки во-вторых груши", "Покупки:\n1. Яблоки\n2. Груши."),
            (.ukrainian, "покупки двокрапка по-перше яблука по-друге груші", "Покупки:\n1. Яблука\n2. Груші."),
        ]
        for (language, raw, expected) in fixtures {
            let result = clean(raw, language)
            XCTAssertEqual(result.cleaned, expected, language.rawValue)
            XCTAssertTrue(result.edits.contains { $0.kind == .listFormatting })
        }
        XCTAssertFalse(clean("first apples second pears", .english).edits.contains { $0.kind == .listFormatting })
        XCTAssertFalse(clean("shopping colon first apples", .english).edits.contains { $0.kind == .listFormatting })
    }

    func testCommasAroundOrderedMarkersAndLiteralCounterexamples() {
        let fixtures: [(SpeechLanguage, String, String)] = [
            (.english, "shopping: first, apples, second, pears", "Shopping:\n1. Apples\n2. Pears."),
            (.german, "einkauf: erstens, äpfel, zweitens, birnen", "Einkauf:\n1. Äpfel\n2. Birnen."),
            (.russian, "покупки: во - первых, яблоки, во - вторых, груши", "Покупки:\n1. Яблоки\n2. Груши."),
            (.ukrainian, "покупки: по - перше, яблука, по - друге, груші", "Покупки:\n1. Яблука\n2. Груші."),
        ]
        for (language, raw, expected) in fixtures {
            XCTAssertEqual(clean(raw, language).cleaned, expected, language.rawValue)
        }
        for raw in ["notes: the first version is ready second draft follows", "shopping: first apples third pears second oranges"] {
            XCTAssertFalse(clean(raw, .english).edits.contains { $0.kind == .listFormatting }, raw)
        }
    }

    func testUnorderedListsRequireAColonAndTwoExplicitMarkers() {
        let fixtures: [(SpeechLanguage, String, String)] = [
            (.english, "shopping colon bullet apples bullet pears", "Shopping:\n- apples\n- pears."),
            (.german, "einkauf doppelpunkt aufzählungspunkt äpfel aufzählungspunkt birnen", "Einkauf:\n- äpfel\n- birnen."),
            (.russian, "покупки двоеточие маркер яблоки маркер груши", "Покупки:\n- яблоки\n- груши."),
            (.ukrainian, "покупки двокрапка маркер яблука маркер груші", "Покупки:\n- яблука\n- груші."),
        ]
        for (language, raw, expected) in fixtures {
            XCTAssertEqual(clean(raw, language).cleaned, expected, language.rawValue)
        }
        XCTAssertFalse(clean("bullet apples bullet pears", .english).edits.contains { $0.kind == .listFormatting })
        XCTAssertFalse(clean("shopping colon bullet apples", .english).edits.contains { $0.kind == .listFormatting })
    }

    func testTypedValueFamiliesProduceRecords() {
        let fixtures: [(String, TextEdit.Kind, String)] = [
            ("twenty", .numberFormatting, "20."),
            ("twenty percent", .percentageFormatting, "20%"),
            ("twenty dollars", .currencyFormatting, "$20."),
            ("twenty kilometers", .unitFormatting, "20 km."),
            ("meet at twelve thirty", .timeFormatting, "Meet at 12:30."),
            ("due April fifteen", .dateFormatting, "Due April 15."),
        ]
        for (raw, kind, expected) in fixtures {
            let result = clean(raw, .english)
            XCTAssertEqual(result.cleaned, expected, raw)
            XCTAssertNotNil(result.edits.first { $0.kind == kind }?.typedValue)
        }
    }

    func testPercentageFormattingInEveryVerifiedLanguage() {
        let fixtures: [(SpeechLanguage, String)] = [
            (.english, "twenty percent"), (.german, "zwanzig prozent"),
            (.russian, "двадцать процентов"), (.ukrainian, "двадцять відсотків"),
        ]
        for (language, raw) in fixtures {
            XCTAssertEqual(clean(raw, language).cleaned, "20%", language.rawValue)
        }
    }

    func testAlreadyNumericAndIdentifierLikeValuesStayUnchanged() {
        for raw in ["version 2.1.4", "account 123456", "phone 555 0100", "phone one two three", "20 km"] {
            let result = clean(raw, .english)
            XCTAssertFalse(result.edits.contains { $0.typedValue != nil }, raw)
        }
    }

    func testRenderedTypedValuesRoundTripTheirCanonicalValue() throws {
        let formatter = TypedValueFormatter()
        let phrases = [
            "twenty", "twenty percent", "twenty dollars",
            "twenty kilometers", "at twelve thirty", "April fifteen",
        ]
        for phrase in phrases {
            let result = clean(phrase, .english)
            let edit = try XCTUnwrap(result.edits.first { $0.typedValue != nil }, phrase)
            let typed = try XCTUnwrap(edit.typedValue, phrase)
            let parsed = formatter.parseRendered(edit.cleanedText, category: typed.category)
            XCTAssertEqual(parsed, typed.canonicalValue, phrase)
        }
    }

    func testEveryTypedValueGrammarRoundTripsInEveryVerifiedLanguage() throws {
        let fixtures: [SpeechLanguage: [(String, TypedValueRecord.Category)]] = [
            .english: [("twenty", .number), ("twenty percent", .percentage), ("twenty dollars", .currency), ("twenty kilometers", .unit), ("at twelve thirty", .time), ("April fifteen", .date)],
            .german: [("zwanzig", .number), ("zwanzig prozent", .percentage), ("zwanzig euro", .currency), ("zwanzig kilometer", .unit), ("um zwölf dreißig", .time), ("fünfzehnte april", .date)],
            .russian: [("двадцать", .number), ("двадцать процентов", .percentage), ("двадцать рублей", .currency), ("двадцать километров", .unit), ("в двенадцать тридцать", .time), ("пятнадцатое апреля", .date)],
            .ukrainian: [("двадцять", .number), ("двадцять відсотків", .percentage), ("двадцять гривень", .currency), ("двадцять кілометрів", .unit), ("о дванадцять тридцять", .time), ("п'ятнадцяте квітня", .date)],
        ]
        let formatter = TypedValueFormatter()
        for (language, languageFixtures) in fixtures {
            for (phrase, category) in languageFixtures {
                let result = clean(phrase, language)
                let edit = try XCTUnwrap(result.edits.first { $0.typedValue?.category == category }, "\(language.rawValue): \(phrase)")
                let typed = try XCTUnwrap(edit.typedValue)
                XCTAssertEqual(formatter.parseRendered(edit.cleanedText, category: category), typed.canonicalValue, "\(language.rawValue): \(phrase)")
            }
        }
    }

    func testTypedEditOwnsTheCompleteProtectedSpan() throws {
        let result = clean("twenty dollars", .english)
        let edit = try XCTUnwrap(result.edits.first { $0.kind == .currencyFormatting })
        XCTAssertEqual(edit.rawText, "twenty dollars")
        XCTAssertEqual(edit.typedValue?.canonicalValue, "20:$")
        XCTAssertEqual(String(Array(result.cleaned)[edit.cleanedRange]), "$20")
    }

    private func clean(_ raw: String, _ language: SpeechLanguage) -> CleanupResult {
        service.clean(raw, language: language, options: CleanupOptions(level: .clean))
    }
}
