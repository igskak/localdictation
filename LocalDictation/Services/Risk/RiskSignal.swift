import Foundation

/// Everything a signal is allowed to look at.
///
/// Assembled once and handed to every signal, so a signal cannot reach for the
/// audio, the engine, or anything else that would make it untestable without a
/// model. All of Phase 3's deterministic signals are pure functions of this.
struct RiskContext: Sendable {
    /// The raw transcript, verbatim. Signals work here and the engine maps
    /// their results forward, because the raw text is what the audio timings
    /// belong to.
    let raw: String
    let words: [TextWord]
    /// Empty when there is no engine behind the text — the measurement harness
    /// runs the signals over reference sentences to count false warnings.
    let tokens: [TranscriptToken]
    let profile: LanguageProfile
    let language: SpeechLanguage
    let edits: [TextEdit]
    let glossary: [GlossaryEntry]

    init(
        raw: String,
        tokens: [TranscriptToken] = [],
        profile: LanguageProfile,
        language: SpeechLanguage? = nil,
        edits: [TextEdit] = [],
        glossary: [GlossaryEntry] = []
    ) {
        self.raw = raw
        self.words = WordScanner.words(in: raw)
        self.tokens = tokens
        self.profile = profile
        self.language = language ?? profile.primary
        self.edits = edits
        self.glossary = glossary
    }

    /// Whether the user put this exact word in their dictionary.
    ///
    /// A term someone typed into Settings on purpose is a word, whatever a
    /// spelling dictionary or a capitalization heuristic thinks of it. This is
    /// what makes the dictionary work as a way to *silence* marks and not only
    /// as a way to earn them: adding "Флок" stops it being reported as a risky
    /// name every time it is said correctly.
    func isInGlossary(_ lowercasedWord: String) -> Bool {
        glossary.contains { entry in
            profile.contains(entry.language) && entry.term.lowercased() == lowercasedWord
        }
    }
}

/// A marked fragment before the engine has priced it or mapped it forward.
struct RawRiskSpan: Sendable, Equatable {
    let reason: RiskReason
    /// `Character` offsets into `RiskContext.raw`.
    let range: Range<Int>
}

/// One independently testable source of risk.
///
/// Each signal answers exactly one question and knows nothing about the review
/// decision. Weighting and the decision live in `RiskEngine` and
/// `ReviewCoordinator`, so a signal can be added, measured, and weighted to
/// zero without touching the policy.
protocol RiskSignal: Sendable {
    var identifier: String { get }
    func spans(in context: RiskContext) -> [RawRiskSpan]
}
