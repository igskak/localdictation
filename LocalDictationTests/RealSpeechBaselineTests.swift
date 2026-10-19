import XCTest
@testable import Witness

/// Synthetic shapes only: these contain no captured user speech.
final class RealSpeechBaselineTests: XCTestCase {
    private let fixtures: [(SpeechLanguage, String)] = [
        (.english, "shopping: first, apples, second, pears"),
        (.german, "betrag 20 % und 25 €"),
        (.russian, "покупки: во - первых яблоки, во - вторых груши"),
        (.ukrainian, "покупки: по - перше яблука, по - друге груші"),
        (.english, "meet at 12 : 30"),
        (.english, "the first version arrives on Tuesday"),
    ]

    func testLegacyAndCleanBaselinePreserveRawAndAreDeterministic() {
        let legacy = ConservativeCleanupService()
        let clean = AdaptiveCleanupService()
        var lines: [String] = []
        for (language, raw) in fixtures {
            let conservative = legacy.clean(raw, language: language)
            let result = clean.clean(raw, language: language, options: CleanupOptions(level: .clean))
            XCTAssertEqual(conservative.raw, raw)
            XCTAssertEqual(result.raw, raw)
            XCTAssertEqual(conservative, legacy.clean(raw, language: language))
            XCTAssertEqual(result, clean.clean(raw, language: language, options: CleanupOptions(level: .clean)))
            let secondPass = legacy.clean(conservative.cleaned, language: language)
            let stable = secondPass.cleaned == conservative.cleaned
            let lexical = lexicalSequence(raw) == lexicalSequence(conservative.cleaned)
            lines.append("\(language.rawValue) | \(raw) | \(conservative.cleaned) | \(result.cleaned.replacingOccurrences(of: "\n", with: "<br>")) | \(lexical) | \(stable)")
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "phase91-baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func lexicalSequence(_ text: String) -> [String] {
        WordScanner.words(in: text).map(\.lowercased)
    }
}
