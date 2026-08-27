import Foundation

/// Which alphabet a word is written in.
enum TextScript: String, Sendable, Equatable {
    case latin
    case cyrillic
    /// Digits, symbols, or a mixture — carries no language evidence.
    case neutral
}

/// Deterministic, per-word language evidence.
///
/// This is deliberately not a language classifier. It answers one narrow
/// question — "does this word carry evidence of a language the profile does not
/// name?" — and answers `nil` whenever it has no evidence, which is most of the
/// time. A confident wrong answer here would spend the false-warning budget on
/// nothing.
///
/// Two kinds of evidence are used, both exact:
///
/// 1. **Script.** Cyrillic against Latin separates {ru, uk} from {de, en}
///    perfectly, which is what the RU+EN and UK+EN profiles need.
/// 2. **Letters that exist in one language of a same-script pair and not the
///    other.** Ukrainian has `і ї є ґ` and Russian does not; Russian has
///    `ы ъ э ё` and Ukrainian does not; German has `ä ö ü ß` and English does
///    not. Nothing distinguishes an English word from a German one that happens
///    to use no umlaut, so DE+EN is only half-separable and the identifier says
///    so by returning `nil`.
enum LanguageIdentifier {
    private static let russianExclusive: Set<Character> = ["ы", "ъ", "э", "ё"]
    private static let ukrainianExclusive: Set<Character> = ["і", "ї", "є", "ґ"]
    private static let germanExclusive: Set<Character> = ["ä", "ö", "ü", "ß"]

    static func script(of word: String) -> TextScript {
        var sawLatin = false
        var sawCyrillic = false

        for character in word.lowercased() where character.isLetter {
            for scalar in character.unicodeScalars {
                switch scalar.value {
                case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F:
                    sawLatin = true
                case 0x0400...0x04FF, 0x0500...0x052F:
                    sawCyrillic = true
                default:
                    break
                }
            }
        }

        switch (sawLatin, sawCyrillic) {
        case (true, false): return .latin
        case (false, true): return .cyrillic
        default: return .neutral
        }
    }

    /// The language a word is evidence for, or `nil` when there is none.
    static func language(of word: String) -> SpeechLanguage? {
        let lowercased = word.lowercased()

        switch script(of: word) {
        case .cyrillic:
            let isRussian = lowercased.contains { russianExclusive.contains($0) }
            let isUkrainian = lowercased.contains { ukrainianExclusive.contains($0) }
            // A word carrying both is a spelling neither language uses; refuse
            // to guess rather than pick the first match.
            if isRussian, !isUkrainian { return .russian }
            if isUkrainian, !isRussian { return .ukrainian }
            return nil

        case .latin:
            return lowercased.contains { germanExclusive.contains($0) } ? .german : nil

        case .neutral:
            return nil
        }
    }

    /// Whether the word's script is compatible with any language in the profile.
    ///
    /// Script mismatch is the strong case: a Latin word inside a Russian-only
    /// profile is either a real language switch or a misrecognition, and both
    /// are worth seeing.
    ///
    /// A language written in neither script — Japanese, Arabic, Greek — makes
    /// the question unanswerable rather than false, so a profile naming one
    /// reports a match and this signal stays quiet. Before Phase 7 every
    /// non-Cyrillic language was treated as Latin, which was true of the four
    /// languages that existed then and is not true of a hundred.
    static func scriptMatches(_ word: String, profile: LanguageProfile) -> Bool {
        let script = script(of: word)
        guard script != .neutral else { return true }
        return profile.languages.contains { language in
            switch language.script {
            case .latin: script == .latin
            case .cyrillic: script == .cyrillic
            case .other: true
            }
        }
    }
}
