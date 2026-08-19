import Foundation

/// Combines the signals into positioned, priced spans.
///
/// The engine owns three things the signals deliberately do not: what a reason
/// is worth, where a raw span lands in the cleaned text, and which audio window
/// belongs to it. Signals stay pure functions over text; everything that needs
/// the edit map or the token timings happens once, here.
///
/// `analyze` is a pure function of its arguments. It runs in microseconds on an
/// utterance-sized string, so it stays on the caller's actor rather than paying
/// for a hop — but nothing in it is tied to one.
struct RiskEngine: Sendable {
    let signals: [any RiskSignal]
    let weights: RiskWeights

    init(signals: [any RiskSignal], weights: RiskWeights = .default) {
        self.signals = signals
        self.weights = weights
    }

    /// The six signals of `docs/ARCHITECTURE.md`, in the order the phase spec
    /// builds them: five deterministic rules first, model confidence last.
    static func standard(weights: RiskWeights = .default) -> RiskEngine {
        RiskEngine(
            signals: [
                NumberRiskSignal(),
                EntityRiskSignal(),
                GlossaryRiskSignal(),
                CleanupEditRiskSignal(),
                LanguageSwitchRiskSignal(),
                ConfidenceRiskSignal(threshold: weights.confidenceThreshold),
            ],
            weights: weights
        )
    }

    func analyze(
        cleanup: CleanupResult,
        tokens: [TranscriptToken] = [],
        profile: LanguageProfile,
        glossary: [GlossaryEntry] = []
    ) -> [RiskSpan] {
        let context = RiskContext(
            raw: cleanup.raw,
            tokens: tokens,
            profile: profile,
            language: cleanup.language,
            edits: cleanup.edits,
            glossary: glossary
        )

        let cleanedCharacters = Array(cleanup.cleaned)
        var seen: Set<SpanKey> = []
        var spans: [RiskSpan] = []

        // Collected before any are priced, so a specific reason can suppress a
        // heuristic one covering the same words.
        let raws = Self.suppressingRedundantEntities(signals.flatMap { $0.spans(in: context) })

        for raw in raws {
            let key = SpanKey(range: raw.range, category: raw.reason.category)
            // Two signals agreeing on the same fragment for the same reason
            // is one mark, not two.
            guard seen.insert(key).inserted else { continue }

            let cleanedRange = cleanup.map.cleanedRange(forRaw: raw.range)
            let window = Self.audioWindow(for: raw.range, tokens: tokens)

            spans.append(
                RiskSpan(
                    reason: raw.reason,
                    rawRange: raw.range,
                    cleanedRange: cleanedRange,
                    weight: weights.weight(for: raw.reason, profile: profile),
                    text: Self.slice(cleanedCharacters, cleanedRange),
                    start: window?.start,
                    end: window?.end
                )
            )
        }

        return spans.sorted {
            if $0.cleanedRange.lowerBound != $1.cleanedRange.lowerBound {
                return $0.cleanedRange.lowerBound < $1.cleanedRange.lowerBound
            }
            return $0.weight > $1.weight
        }
    }

    /// Drops a name mark from words another signal already explained.
    ///
    /// The entity rule is a capitalization heuristic, and it is the weakest of
    /// the signals: in English every month and weekday is capitalized, so
    /// "March" arrived marked both as a date and as a person's name. Two labels
    /// on one word is not extra safety — it is the false-warning budget being
    /// spent to say the same thing twice, and `docs/PHASE_3.md` makes that
    /// budget binding.
    ///
    /// Only the heuristic gives way. Two specific signals disagreeing about the
    /// same fragment is real information and is left alone.
    static func suppressingRedundantEntities(_ raws: [RawRiskSpan]) -> [RawRiskSpan] {
        let explained = raws.compactMap { raw -> Range<Int>? in
            if case .namedEntity = raw.reason { return nil }
            return raw.range
        }
        guard !explained.isEmpty else { return raws }

        return raws.filter { raw in
            guard case .namedEntity = raw.reason else { return true }
            return !explained.contains { $0.overlaps(raw.range) }
        }
    }

    private struct SpanKey: Hashable {
        let range: Range<Int>
        let category: String
    }

    private static func slice(_ characters: [Character], _ range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= characters.count, !range.isEmpty else { return "" }
        return String(characters[range])
    }

    /// The audio window of every token the span touches.
    ///
    /// Phase 2 already produces per-token timings against the raw text, so the
    /// replay window falls out of an overlap test rather than needing a second
    /// alignment pass.
    static func audioWindow(
        for range: Range<Int>,
        tokens: [TranscriptToken]
    ) -> (start: TimeInterval, end: TimeInterval)? {
        var start: TimeInterval?
        var end: TimeInterval?

        for token in tokens {
            let overlaps = range.isEmpty
                ? (token.range.contains(range.lowerBound) || token.range.upperBound == range.lowerBound)
                : token.range.overlaps(range)
            guard overlaps else { continue }
            start = min(start ?? token.start, token.start)
            end = max(end ?? token.end, token.end)
        }

        guard let start, let end, end >= start else { return nil }
        return (start, end)
    }
}
