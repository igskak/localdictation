import Foundation

/// Whether a word is one the system has heard of, per language.
///
/// A protocol rather than a direct `NSSpellChecker` call for the reason every
/// other OS integration in this app is one: the risk signals are pure functions
/// of a `RiskContext` and are tested as such, and a signal that reaches into
/// AppKit is a signal that can only be measured on a Mac with the right
/// dictionaries installed. The benchmark corpus has to produce the same numbers
/// everywhere or the numbers are not a regression guard.
///
/// `supports` is a real question and not a formality. macOS ships spelling for
/// German, English, Russian, and Ukrainian, but a dictionary can be absent, and
/// a signal whose evidence is missing must produce nothing rather than guess.
protocol LexiconChecking: Sendable {
    func supports(_ language: SpeechLanguage) -> Bool
    func isKnownWord(_ word: String, language: SpeechLanguage) -> Bool
}

/// A lexicon with no dictionaries at all, which switches the signals that need
/// one off entirely. The default, so that an engine built without a lexicon
/// behaves exactly as it did before one existed.
struct EmptyLexicon: LexiconChecking {
    func supports(_ language: SpeechLanguage) -> Bool { false }
    func isKnownWord(_ word: String, language: SpeechLanguage) -> Bool { false }
}

/// A lexicon that has every language and knows no word in any of them.
///
/// This is what the measurement harness runs on, and the choice is deliberate.
/// `MalformedWordSignal` marks a word only when it fails two independent tests,
/// and one of them — the dictionary — depends on which spelling files happen to
/// be installed on the Mac running the benchmark. A number that moves with the
/// machine is not a regression guard.
///
/// Answering "no" to every word removes that gate, so the benchmark measures
/// the shape rule alone. Because the dictionary can only ever *remove* marks,
/// what comes out is a strict upper bound: whatever false-warning density this
/// reports, the shipping app's is at most that.
struct ShapeOnlyLexicon: LexiconChecking {
    func supports(_ language: SpeechLanguage) -> Bool { true }
    func isKnownWord(_ word: String, language: SpeechLanguage) -> Bool { false }
}
