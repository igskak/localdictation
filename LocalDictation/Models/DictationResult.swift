import Foundation

/// Everything Phase 3 knows about one utterance.
///
/// Assembled once, when the transcript arrives, and then read. Keeping the raw
/// transcript, the cleaned text, every edit, every span, and the decision in a
/// single value is what makes raw-transcript recovery free: the raw text is not
/// reconstructed later, it was never thrown away.
struct DictationResult: Sendable, Equatable {
    let transcript: Transcript
    let cleanup: CleanupResult
    /// Every span the engine produced, including the ones below the flag
    /// threshold. Those are informational: they explain a review that happened
    /// for another reason, and never cause one.
    let spans: [RiskSpan]
    let decision: ReviewDecision

    var rawText: String { cleanup.raw }
    var cleanedText: String { cleanup.cleaned }
    var profile: LanguageProfile { transcript.profile }
    var requiresReview: Bool { decision.requiresReview }
    var flaggedSpans: [RiskSpan] { decision.flaggedSpans }

    var isEmpty: Bool { cleanup.cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The text the user takes away, given whether they asked for the raw
    /// transcript back.
    func text(preferringRaw preferRaw: Bool) -> String {
        preferRaw ? rawText : cleanedText
    }
}

/// Non-content summary of the Phase 3 stages, for developer diagnostics.
///
/// Counts, weights, and kinds only. As with `TranscriptDiagnostics`, no
/// recognized text is copied in here, so nothing in this struct can reach a
/// log line.
struct RiskDiagnostics: Sendable, Equatable {
    let editCount: Int
    let editKinds: [String]
    let spanCount: Int
    let flaggedSpanCount: Int
    let spanCategories: [String]
    let maximumWeight: Double
    let requiresReview: Bool

    init(_ result: DictationResult) {
        editCount = result.cleanup.edits.count
        editKinds = result.cleanup.edits.map { $0.kind.rawValue }.sorted()
        spanCount = result.spans.count
        flaggedSpanCount = result.flaggedSpans.count
        spanCategories = result.spans.map { $0.reason.category }.sorted()
        maximumWeight = result.spans.map(\.weight).max() ?? 0
        requiresReview = result.requiresReview
    }
}
