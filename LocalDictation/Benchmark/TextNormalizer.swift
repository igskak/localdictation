import Foundation

/// Normalization applied to both reference and hypothesis before scoring.
///
/// Every option is explicit because the numbers move a lot depending on what is
/// folded away, and a benchmark that does not state its normalization is not
/// reproducible.
struct TextNormalizer: Sendable, Equatable {
    var lowercase: Bool
    var stripPunctuation: Bool
    var collapseWhitespace: Bool
    /// Folds Russian `ё` to `е`, which is how it is usually written.
    /// Ukrainian `ї`, `і`, and `є` are distinct letters and are never folded.
    var foldRussianYo: Bool

    static let `default` = TextNormalizer(
        lowercase: true,
        stripPunctuation: true,
        collapseWhitespace: true,
        foldRussianYo: true
    )

    /// Punctuation removed before scoring. Apostrophes and hyphens are kept
    /// because they carry meaning inside words in every supported language —
    /// German compounds, Ukrainian `з'їзд`, English contractions.
    private static let strippedPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "…", "\"", "«", "»", "„", "“", "”",
        "(", ")", "[", "]", "{", "}", "/", "\\", "*", "_", "—", "–",
    ]

    private static let apostrophes: Set<Character> = ["\u{2019}", "\u{02BC}", "\u{0060}", "\u{00B4}"]

    func normalize(_ text: String, language: SpeechLanguage) -> String {
        var result = text.precomposedStringWithCanonicalMapping

        if lowercase {
            result = result.lowercased()
        }

        var characters: [Character] = []
        characters.reserveCapacity(result.count)

        for character in result {
            if Self.apostrophes.contains(character) {
                characters.append("'")
                continue
            }
            if stripPunctuation, Self.strippedPunctuation.contains(character) {
                characters.append(" ")
                continue
            }
            if foldRussianYo, language == .russian, character == "ё" {
                characters.append("е")
                continue
            }
            characters.append(character)
        }

        result = String(characters)

        if collapseWhitespace {
            result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalized text split into scoring words.
    func words(_ text: String, language: SpeechLanguage) -> [String] {
        normalize(text, language: language)
            .split(separator: " ")
            .map(String.init)
    }

    /// Normalized text as scoring characters, with spaces removed so CER
    /// measures letters rather than tokenization.
    func characters(_ text: String, language: SpeechLanguage) -> [Character] {
        normalize(text, language: language).filter { !$0.isWhitespace }
    }
}
