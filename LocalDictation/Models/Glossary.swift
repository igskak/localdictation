import Foundation

/// One term the user wants the app to watch for.
struct GlossaryEntry: Sendable, Equatable, Codable, Identifiable {
    let id: UUID
    var term: String
    /// Terms are scoped by language, per `docs/PRODUCT_SCOPE.md`: a German
    /// customer name is not a Russian one, and a dictionary that ignored the
    /// distinction would fire in the wrong profile.
    var language: SpeechLanguage

    init(id: UUID = UUID(), term: String, language: SpeechLanguage) {
        self.id = id
        self.term = term
        self.language = language
    }

    var normalizedTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool { !normalizedTerm.isEmpty }
}

/// The user's vocabulary.
///
/// This is the first thing in the app that survives a launch, and it is the
/// only thing that may: `docs/PHASE_3.md` keeps transcripts and audio
/// memory-only. Nothing derived from an utterance is ever written here.
struct Glossary: Sendable, Equatable, Codable {
    var entries: [GlossaryEntry]

    init(entries: [GlossaryEntry] = []) {
        self.entries = entries
    }

    static let empty = Glossary()

    func entries(for profile: LanguageProfile) -> [GlossaryEntry] {
        entries.filter { profile.contains($0.language) }
    }

    func entries(for language: SpeechLanguage) -> [GlossaryEntry] {
        entries.filter { $0.language == language }
    }

    /// Adds a term, ignoring blanks and case-insensitive duplicates within the
    /// same language. Returns whether anything changed.
    @discardableResult
    mutating func add(_ term: String, language: SpeechLanguage) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let exists = entries.contains {
            $0.language == language && $0.normalizedTerm.lowercased() == trimmed.lowercased()
        }
        guard !exists else { return false }
        entries.append(GlossaryEntry(term: trimmed, language: language))
        return true
    }

    @discardableResult
    mutating func remove(id: UUID) -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == id }
        return entries.count != before
    }
}
