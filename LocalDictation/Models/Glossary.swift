import Foundation

/// One term the user wants the app to watch for.
struct GlossaryEntry: Sendable, Equatable, Codable, Identifiable {
    static let maximumTermLength = 120

    let id: UUID
    var term: String
    /// Optional phrase Whisper tends to produce instead of `term`.
    var replacement: String?
    /// Terms are scoped by language, per `docs/PRODUCT_SCOPE.md`: a German
    /// customer name is not a Russian one, and a dictionary that ignored the
    /// distinction would fire in the wrong profile.
    var language: SpeechLanguage

    init(id: UUID = UUID(), term: String, replacement: String? = nil, language: SpeechLanguage) {
        self.id = id
        self.term = term
        self.replacement = replacement
        self.language = language
    }

    var normalizedTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedReplacement: String? {
        guard let value = replacement?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    var isValid: Bool {
        !normalizedTerm.isEmpty
            && normalizedTerm.count <= Self.maximumTermLength
            && (normalizedReplacement?.count ?? 0) <= Self.maximumTermLength
    }
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
    mutating func add(_ term: String, replacement: String? = nil, language: SpeechLanguage) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTrigger = trigger.flatMap { $0.isEmpty ? nil : $0 }
        guard !trimmed.isEmpty,
              trimmed.count <= GlossaryEntry.maximumTermLength,
              (normalizedTrigger?.count ?? 0) <= GlossaryEntry.maximumTermLength
        else { return false }
        let exists = entries.contains {
            guard $0.language == language else { return false }
            if let normalizedTrigger {
                return $0.normalizedReplacement?.localizedCaseInsensitiveCompare(normalizedTrigger) == .orderedSame
            }
            return $0.normalizedReplacement == nil
                && $0.normalizedTerm.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !exists else { return false }
        entries.append(GlossaryEntry(term: trimmed, replacement: normalizedTrigger, language: language))
        return true
    }

    @discardableResult
    mutating func remove(id: UUID) -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == id }
        return entries.count != before
    }
}
