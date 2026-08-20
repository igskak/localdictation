import AppKit
import Foundation

/// `LexiconChecking` backed by the spelling dictionaries macOS already ships.
///
/// No third-party dependency and no bundled word list: the four MVP languages
/// are all in `NSSpellChecker.availableLanguages` on a stock Mac, and shipping
/// a second copy of a dictionary the system already has would be a download the
/// user pays for twice.
///
/// This is the only place in the risk engine that touches AppKit, and it is
/// deliberately behind the protocol so no signal has to. `docs/PHASE_3.md` is
/// explicit that a signal is a pure function of its context; this class is what
/// lets that stay true while still asking the system a question.
///
/// Nothing here is on the main actor. `NSSpellChecker` is not documented as
/// thread-safe, so every call goes through a lock, and answers are cached
/// because dictation repeats words far more often than it introduces them.
final class SystemLexicon: LexiconChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let checker: NSSpellChecker
    private let availableLanguages: Set<String>
    private var cache: [Key: Bool] = [:]

    private struct Key: Hashable {
        let word: String
        let language: SpeechLanguage
    }

    /// Bounded so a long session cannot grow this without limit. A dictated
    /// vocabulary is small; the cap exists for the pathological case, not the
    /// ordinary one.
    private static let cacheLimit = 4_096

    init(checker: NSSpellChecker = .shared) {
        self.checker = checker
        // Read once. The set does not change while the app runs, and reading it
        // per word would put a system call on the hot path of every utterance.
        self.availableLanguages = Set(checker.availableLanguages)
    }

    func supports(_ language: SpeechLanguage) -> Bool {
        // `availableLanguages` reports regional variants too — "en_GB" satisfies
        // a request for English.
        availableLanguages.contains { $0 == language.rawValue || $0.hasPrefix("\(language.rawValue)_") }
    }

    func isKnownWord(_ word: String, language: SpeechLanguage) -> Bool {
        guard supports(language) else { return true }
        let key = Key(word: word.lowercased(), language: language)

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }

        let misspelling = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language.rawValue,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        let known = misspelling.location == NSNotFound
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = known
        return known
    }
}
