import Foundation

/// Words the engine produced that no language could have produced.
///
/// This is the signal the app was missing, and the reason for it is a specific
/// complaint: dictating "проверка" and getting "ррверка" back, unmarked, while
/// a perfectly correct product name three words later was marked as a risky
/// one. The mark was on the word that was right and absent from the word that
/// was wrong — which is the review being worse than nothing, because it spends
/// the user's attention pointing away from the error.
///
/// The obvious fix — "mark every word the system spell checker does not know" —
/// was measured before it was written, and it does not work. On this Mac the
/// Russian dictionary does not contain `деплой`, `коммит`, `бэкенд`, `апи`, or
/// even `аутентификация`; the English one does not contain `webhook`. A signal
/// built on it would mark a large share of the ordinary working vocabulary of
/// the exact person this app is for, and that is the same failure in a new
/// place. So the dictionary is used, but not on its own: it says a word is
/// *unfamiliar*, which is cheap, and this signal says a word is *impossible*,
/// which is not.
///
/// Impossibility is judged from the shape of the word, because that is what
/// separates the two cases. `ррверка` opens with a doubled consonant and then a
/// third; `деплой` and `Скаковский` are unusual only to a dictionary. No
/// language written in Latin or Cyrillic script begins a word with a doubled
/// consonant, and no word in any of them is all consonants.
///
/// A word must fail *both* tests to be marked: unknown to the dictionary and
/// impossible in shape. Either alone is a guess; together they are as close to
/// a fact about the characters as this can get, which is what
/// `docs/PHASE_3.md` requires of a signal that carries weight.
struct MalformedWordSignal: RiskSignal {
    let identifier = "malformed"

    private let lexicon: any LexiconChecking

    init(lexicon: any LexiconChecking) {
        self.lexicon = lexicon
    }

    /// Below this a word is too short for either test to mean anything: two
    /// letters cannot hold a consonant run, and dictionaries are erratic on
    /// particles and initials.
    private static let minimumLength = 4

    func spans(in context: RiskContext) -> [RawRiskSpan] {
        guard lexicon.supports(context.language) else { return [] }

        var spans: [RawRiskSpan] = []
        for word in context.words {
            guard word.text.count >= Self.minimumLength else { continue }
            // A number is not a word, and it already has a signal of its own.
            guard !CriticalTokens.containsDigit(word.text) else { continue }
            // An acronym is all consonants by nature. The entity signal owns it.
            guard !Self.isAcronym(word.text) else { continue }
            // The user put this word in their dictionary on purpose. Whatever
            // the system lexicon thinks, it is a word here.
            guard !context.isInGlossary(word.lowercased) else { continue }
            guard Self.hasImpossibleShape(word.text, language: context.language) else { continue }
            guard !lexicon.isKnownWord(word.text, language: context.language) else { continue }
            spans.append(RawRiskSpan(reason: .malformedWord, range: word.range))
        }
        return spans
    }

    static func isAcronym(_ word: String) -> Bool {
        word.count >= 2 && word.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// German compounds pile consonants up at their seams and are correct
    /// doing it: *Angstschweiß* has eight in a row, *Softwareentwicklungs&#8203;prozess*
    /// five. So the consonant-run rule is switched off for German rather than
    /// tuned, exactly as the capitalization heuristic is in `EntityRiskSignal`
    /// and for the same reason — a rule that fires on most of a language is not
    /// a weaker signal, it is a broken one. German keeps the other two rules.
    static func usesConsonantRunRule(_ language: SpeechLanguage) -> Bool {
        language != .german
    }

    /// Whether the word's letters form a sequence no word in the language has.
    ///
    /// Three rules, all about consonants, because a mangled recognition almost
    /// always shows up as consonants that cannot be pronounced together — the
    /// engine emitting a fragment of one word joined to a fragment of another.
    static func hasImpossibleShape(_ word: String, language: SpeechLanguage) -> Bool {
        let letters = word.lowercased().filter { $0.isLetter }
        guard letters.count >= minimumLength else { return false }

        // A doubled consonant at the very start of a word. There is no such
        // word in German, English, Russian, or Ukrainian.
        let characters = Array(letters)
        if characters.count >= 2,
           isConsonant(characters[0]),
           characters[0] == characters[1] {
            return true
        }

        // More than five consonants with no vowel between them. Five is not a
        // round number, it is the longest run the three non-German languages
        // actually produce: Russian "бодрствовать" and English "strengths" both
        // reach it, and a limit of four would have marked them.
        var run = 0
        var sawVowel = false
        for character in characters {
            if isVowel(character) {
                sawVowel = true
                run = 0
                continue
            }
            guard isConsonant(character) else {
                run = 0
                continue
            }
            run += 1
            if run > 5, usesConsonantRunRule(language) { return true }
        }

        // No vowel at all in a word this long is not a word either.
        return !sawVowel
    }

    /// Vowels of the Latin and Cyrillic alphabets used by the four MVP
    /// languages, including the German umlauts and the Ukrainian і/ї/є.
    private static let vowels: Set<Character> = [
        "a", "e", "i", "o", "u", "y", "ä", "ö", "ü",
        "а", "е", "ё", "и", "о", "у", "ы", "э", "ю", "я", "і", "ї", "є",
    ]

    /// Characters that are neither vowels nor consonants for the purpose of a
    /// consonant run: the Cyrillic signs carry no sound of their own and must
    /// not be counted as a consonant piling onto a run.
    private static let neutral: Set<Character> = ["ь", "ъ", "'", "\u{2019}"]

    static func isVowel(_ character: Character) -> Bool { vowels.contains(character) }

    static func isConsonant(_ character: Character) -> Bool {
        character.isLetter && !vowels.contains(character) && !neutral.contains(character)
    }
}
