import Foundation

/// Why a fragment is worth checking.
///
/// The reason travels with the span all the way into the review strip. A mark
/// the user cannot explain is a mark they learn to ignore, and `docs/PHASE_3.md`
/// treats that as the failure mode that matters most.
enum RiskReason: Sendable, Equatable {
    case number
    case currency
    case date
    case namedEntity
    /// The text nearly matches a term in the user's dictionary.
    case glossaryNearMiss(term: String)
    /// A word whose letters form a sequence no MVP language produces, and which
    /// the system dictionary does not know either. See `MalformedWordSignal`.
    case malformedWord
    case cleanupEdit(TextEdit.Kind)
    /// A word carrying evidence of a language the profile does not name.
    case languageSwitch(SpeechLanguage)
    case lowConfidence(Double)

    var label: String {
        switch self {
        case .number: "Number"
        case .currency: "Amount"
        case .date: "Date"
        case .namedEntity: "Name"
        case let .glossaryNearMiss(term): "Close to “\(term)”"
        case .malformedWord: "Not a word"
        case let .cleanupEdit(kind): kind.label
        case let .languageSwitch(language): "\(language.displayName) word"
        case .lowConfidence: "Uncertain"
        }
    }

    /// Stable grouping key for measurement, so false-warning density can be
    /// reported per signal instead of as one number nobody can act on.
    var category: String {
        switch self {
        case .number: "number"
        case .currency: "currency"
        case .date: "date"
        case .namedEntity: "entity"
        case .glossaryNearMiss: "glossary"
        case .malformedWord: "malformed"
        case let .cleanupEdit(kind): "cleanup.\(kind.rawValue)"
        case .languageSwitch: "language"
        case .lowConfidence: "confidence"
        }
    }
}

/// One fragment marked by the risk engine, positioned in both texts.
///
/// Both ranges are kept because they answer different questions: the raw range
/// is where the audio is, and the cleaned range is where the user is looking.
struct RiskSpan: Sendable, Equatable {
    let reason: RiskReason
    /// `Character` offsets into the raw transcript.
    let rawRange: Range<Int>
    /// `Character` offsets into the cleaned text.
    let cleanedRange: Range<Int>
    let weight: Double
    /// The fragment as the user sees it. Empty for an edit that only removed
    /// text, which has a position in the cleaned text but no extent.
    let text: String
    /// Utterance-relative audio window, from the Phase 2 token timings.
    let start: TimeInterval?
    let end: TimeInterval?

    /// Whether the span can be replayed. A cleanup edit over text the engine
    /// never emitted has no timing, and offering a dead play button would be
    /// worse than offering none.
    var isPlayable: Bool { start != nil && end != nil }

    var hasExtentInCleanedText: Bool { !cleanedRange.isEmpty }
}

/// How much each signal counts toward the review decision.
///
/// Weights are a tuned parameter, not a structural assumption. `docs/PHASE_3.md`
/// requires the deterministic signals to carry the promise and model confidence
/// to arrive last, behind a weight that starts at zero — so it does.
struct RiskWeights: Sendable, Equatable {
    var number: Double = 0.8
    var currency: Double = 0.8
    var date: Double = 0.8
    var namedEntity: Double = 0.6
    var glossaryNearMiss: Double = 0.9

    /// The heaviest deterministic signal in the engine, and the only new one in
    /// Phase 5. A word that is both impossible in shape and unknown to the
    /// system dictionary is not a judgement call — `ррверка` is not a word in
    /// any language, and the user has no way to notice it except by rereading
    /// text they just dictated. Priced above the attention threshold on its own,
    /// which nothing else except a dictionary near-miss is.
    var malformedWord: Double = 0.85

    /// Cleanup edits are weighted by what they actually did. Every utterance
    /// gets a closing period and a capital letter, so charging those the same
    /// as a deleted word would put every single utterance into review and burn
    /// the false-warning budget on punctuation.
    var cleanupFillerRemoval: Double = 0.6
    var cleanupPunctuation: Double = 0.05
    var cleanupCapitalization: Double = 0.05
    var cleanupSpacing: Double = 0.0

    /// A word from outside the profile is a strong signal; the second language
    /// of a mixed profile is the profile working as intended.
    var languageOutsideProfile: Double = 0.7
    var languageSecondaryOfProfile: Double = 0.3

    /// Zero by decision, not by omission. Phase 2 measured weak separation
    /// between the confidence of correct and incorrect tokens, and *negative*
    /// separation on Russian. The signal is wired up and measured; it starts
    /// contributing when a measurement on real speech says it should.
    var modelConfidence: Double = 0
    var confidenceThreshold: Double = 0.5

    static let `default` = RiskWeights()

    func weight(for reason: RiskReason, profile: LanguageProfile) -> Double {
        switch reason {
        case .number: number
        case .currency: currency
        case .date: date
        case .namedEntity: namedEntity
        case .glossaryNearMiss: glossaryNearMiss
        case .malformedWord: malformedWord
        case let .cleanupEdit(kind):
            switch kind {
            case .fillerRemoval: cleanupFillerRemoval
            case .punctuation: cleanupPunctuation
            case .capitalization: cleanupCapitalization
            case .spacing: cleanupSpacing
            }
        case let .languageSwitch(language):
            profile.contains(language) ? languageSecondaryOfProfile : languageOutsideProfile
        case let .lowConfidence(value):
            modelConfidence * severity(ofConfidence: value)
        }
    }

    /// How far below the threshold a confidence sits, in `0...1`.
    func severity(ofConfidence value: Double) -> Double {
        guard confidenceThreshold > 0 else { return 0 }
        let shortfall = (confidenceThreshold - value) / confidenceThreshold
        return min(max(shortfall, 0), 1)
    }
}
