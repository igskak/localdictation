import Foundation

/// Which conservative rules run. Every one is separately switchable so a test
/// can exercise a single rule, and so a rule that turns out to be wrong for a
/// language can be turned off there instead of being deleted everywhere.
struct CleanupOptions: Sendable, Equatable {
    var collapsesWhitespace: Bool = true
    var fixesPunctuationSpacing: Bool = true
    var removesFillers: Bool = true
    var capitalizesSentences: Bool = true
    var addsTerminalPunctuation: Bool = true

    static let `default` = CleanupOptions()
    static let none = CleanupOptions(
        collapsesWhitespace: false,
        fixesPunctuationSpacing: false,
        removesFillers: false,
        capitalizesSentences: false,
        addsTerminalPunctuation: false
    )
}

/// Conservative cleanup boundary.
///
/// The contract is narrow on purpose: an implementation may not change wording,
/// word order, numbers, or meaning, and every change it does make must appear
/// in the returned edit list and map. Anything broader is a rewrite, which
/// `docs/PRODUCT_SCOPE.md` places after the MVP.
protocol CleanupService: Sendable {
    func clean(_ raw: String, language: SpeechLanguage, options: CleanupOptions) -> CleanupResult
}

extension CleanupService {
    func clean(_ raw: String, language: SpeechLanguage) -> CleanupResult {
        clean(raw, language: language, options: .default)
    }
}
