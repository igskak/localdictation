import XCTest
@testable import Witness

final class AdaptiveCleanupCommandTests: XCTestCase {
    private let service = AdaptiveCleanupService()

    func testSpokenPunctuationInEveryVerifiedLanguage() {
        let fixtures: [(SpeechLanguage, String, String)] = [
            (.english, "hello comma world", "Hello, world."),
            (.german, "hallo komma welt", "Hallo, welt."),
            (.russian, "привет запятая мир", "Привет, мир."),
            (.ukrainian, "привіт кома світ", "Привіт, світ."),
        ]
        for (language, raw, expected) in fixtures {
            let result = service.clean(raw, language: language, options: CleanupOptions(level: .clean))
            XCTAssertEqual(result.cleaned, expected, language.rawValue)
            XCTAssertTrue(result.edits.contains { $0.kind == .spokenPunctuation })
        }
    }

    func testLineAndParagraphCommandsInEveryVerifiedLanguage() {
        let fixtures: [(SpeechLanguage, String, String)] = [
            (.english, "one new line two new paragraph three", "One\ntwo\n\nthree."),
            (.german, "eins neue zeile zwei neuer absatz drei", "Eins\nzwei\n\ndrei."),
            (.russian, "один новая строка два новый абзац три", "Один\nдва\n\nтри."),
            (.ukrainian, "один новий рядок два новий абзац три", "Один\nдва\n\nтри."),
        ]
        for (language, raw, expected) in fixtures {
            let result = service.clean(raw, language: language, options: CleanupOptions(level: .clean))
            XCTAssertEqual(result.cleaned, expected, language.rawValue)
            XCTAssertTrue(result.edits.contains { $0.kind == .lineBreak })
            XCTAssertTrue(result.edits.contains { $0.kind == .paragraphBreak })
        }
    }

    func testAmbiguousPeriodStaysLiteralOutsideCommandPosition() {
        let result = service.clean(
            "the trial period ends Friday",
            language: .english,
            options: CleanupOptions(level: .clean)
        )
        XCTAssertEqual(result.cleaned, "The trial period ends Friday.")
        XCTAssertFalse(result.edits.contains { $0.kind == .spokenPunctuation })
    }

    func testUnsupportedLanguageIsExactlyConservative() {
        let polish = try! XCTUnwrap(SpeechLanguage(rawValue: "pl"))
        let raw = "hello comma world"
        XCTAssertEqual(
            service.clean(raw, language: polish, options: CleanupOptions(level: .clean)),
            ConservativeCleanupService().clean(raw, language: polish)
        )
    }

    func testDictionaryCorrectionIsWholePhraseCaseInsensitiveAndLongestWins() {
        let glossary = [
            GlossaryEntry(term: "Acme", replacement: "ack me", language: .english),
            GlossaryEntry(term: "Acme Cloud", replacement: "ack me cloud", language: .english),
        ]
        let result = service.clean(
            "send ACK ME CLOUD today",
            language: .english,
            options: CleanupOptions(level: .clean, glossary: glossary)
        )
        XCTAssertEqual(result.cleaned, "Send Acme Cloud today.")
        XCTAssertEqual(result.edits.filter { $0.kind == .dictionaryCorrection }.count, 1)
        XCTAssertEqual(result.edits.first { $0.kind == .dictionaryCorrection }?.rawText, "ACK ME CLOUD")
    }

    func testGlossaryTermProtectsACommandPhrase() {
        let glossary = [GlossaryEntry(term: "Comma", language: .english)]
        let result = service.clean(
            "use comma",
            language: .english,
            options: CleanupOptions(level: .clean, glossary: glossary)
        )
        XCTAssertEqual(result.cleaned, "Use comma.")
    }
}
