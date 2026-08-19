import Foundation

/// One word located in a piece of text, with the offsets a risk span needs.
///
/// Offsets are `Character` counts, matching the Phase 2 token convention, so
/// German umlauts and Cyrillic are ordinary text rather than an edge case.
struct TextWord: Sendable, Equatable {
    /// Position in the scanned sequence, counting words only.
    let index: Int
    let text: String
    let range: Range<Int>
    /// First word of the text, or the first word after a sentence terminator.
    ///
    /// This is the only place capitalization may be judged from: a capitalized
    /// word here says nothing, while a capitalized word elsewhere is a signal
    /// in English, Russian, and Ukrainian — and still says nothing in German.
    let isSentenceInitial: Bool

    var lowercased: String { text.lowercased() }
}

/// Splits text into words with exact character offsets.
///
/// Written rather than borrowed from `TextNormalizer` because normalization
/// deliberately destroys offsets — it lowercases, strips punctuation, and
/// collapses whitespace. The risk engine has to point at real characters in
/// the text the user will read, so it needs the positions preserved.
enum WordScanner {
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Characters that join a word rather than ending it. Apostrophes and
    /// hyphens carry meaning inside words in all four MVP languages — German
    /// compounds, Ukrainian `з'їзд`, English contractions.
    private static let joiners: Set<Character> = ["'", "\u{2019}", "\u{02BC}", "-", "\u{2011}"]

    private static let currencySymbols: Set<Character> = ["€", "$", "£", "₴", "₽", "¥"]

    static func words(in text: String) -> [TextWord] {
        let characters = Array(text)
        var words: [TextWord] = []
        var index = 0
        var sentenceIsOpen = false
        var position = 0

        while position < characters.count {
            let character = characters[position]

            guard isWordStart(character) else {
                if sentenceTerminators.contains(character) { sentenceIsOpen = false }
                position += 1
                continue
            }

            let start = position
            position += 1
            while position < characters.count, isWordContinuation(characters, at: position) {
                position += 1
            }

            let word = String(characters[start..<position])
            words.append(
                TextWord(
                    index: index,
                    text: word,
                    range: start..<position,
                    isSentenceInitial: !sentenceIsOpen
                )
            )
            index += 1
            sentenceIsOpen = true
        }

        return words
    }

    private static func isWordStart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || currencySymbols.contains(character)
    }

    private static func isWordContinuation(_ characters: [Character], at position: Int) -> Bool {
        let character = characters[position]
        if isWordStart(character) { return true }
        if joiners.contains(character) {
            // A trailing hyphen or apostrophe belongs to punctuation, not to the
            // word: "Meyer- " must not swallow the space that follows it.
            let next = position + 1
            return next < characters.count && isWordStart(characters[next])
        }
        // A separator inside a number is part of it: 1.450, 1,450, 12:30.
        if character == "." || character == "," || character == ":" {
            let previous = position - 1
            let next = position + 1
            return previous >= 0 && characters[previous].isNumber
                && next < characters.count && characters[next].isNumber
        }
        return false
    }

    /// Offsets of every sentence-initial word, for the capitalization rule.
    static func sentenceStarts(in text: String) -> [Int] {
        words(in: text).filter(\.isSentenceInitial).map(\.range.lowerBound)
    }
}
