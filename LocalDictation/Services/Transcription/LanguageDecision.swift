import Foundation

/// Which of the user's languages an utterance is decoded as.
///
/// The engine ranks every language it knows on every utterance. This is the
/// rule that turns that ranking into one answer inside the set the user chose,
/// and it is deliberately a pure function of a probability table so it can be
/// tested without a model, a microphone, or a second of audio.
///
/// Restricting the ranking to the selected languages is what stops drift *out*
/// of the set — a Ukrainian sentence coming back as Polish, which is the miss
/// `LanguageClampTests` was written for. It does nothing about confusion
/// *inside* the set, which is the failure a Russian-and-Ukrainian user actually
/// meets: two words carry barely a second of evidence, and between two closely
/// related languages the ranking is a coin toss. The margin and the previous
/// utterance exist for exactly that case.
struct LanguageDecision: Sendable, Equatable {
    /// Why this language, in the words the log uses.
    enum Reason: String, Sendable, Equatable {
        /// One language is selected, so nothing was detected at all.
        case onlyLanguage
        /// The leader is ahead of the runner-up by at least the margin.
        case confident
        /// Ambiguous, and the previous utterance's language is one of the two
        /// leaders: a person mid-paragraph is still in the same language.
        case continuedFromPrevious
        /// Ambiguous, and the preferred language is one of the two leaders.
        case fellBackToPreferred
        /// Ambiguous, and neither the previous nor the preferred language is in
        /// contention. The leader wins for want of anything better.
        case leadWithoutMargin
        /// No selected language appears in the distribution at all.
        case noEvidence
    }

    let language: SpeechLanguage
    let reason: Reason

    /// How far ahead of the runner-up the leader has to be to settle it alone.
    ///
    /// A starting value, not a measured one: `docs/PHASE_7.md` says so, and
    /// `docs/PHASE_2_BENCHMARK.md`'s harness is what will move it. Too low and
    /// the previous utterance never gets a say; too high and a clear sentence
    /// is overruled by what came before it.
    static let defaultMargin: Float = 0.2

    /// How long the previous utterance's language stays worth knowing.
    ///
    /// Long enough to cover a pause for thought in the middle of a paragraph,
    /// short enough that yesterday's language has no opinion about today's.
    static let recencyWindow: TimeInterval = 120

    static func choose(
        profile: LanguageProfile,
        probabilities: [String: Float],
        previous: SpeechLanguage? = nil,
        margin: Float = defaultMargin
    ) -> LanguageDecision {
        guard profile.isMixed else {
            return LanguageDecision(language: profile.primary, reason: .onlyLanguage)
        }

        let ranked = rank(profile: profile, probabilities: probabilities)
        guard let leader = ranked.first else {
            // Nothing the user selected was ranked. Producing a transcript in a
            // language they chose beats failing the recording they just made.
            return LanguageDecision(language: profile.primary, reason: .noEvidence)
        }
        guard let runnerUp = ranked.dropFirst().first else {
            return LanguageDecision(language: leader.language, reason: .confident)
        }
        guard leader.probability - runnerUp.probability < margin else {
            return LanguageDecision(language: leader.language, reason: .confident)
        }

        // Ambiguous. A confident distribution is never overruled by what came
        // before it, which is why this is reached only here: switching language
        // mid-session costs one clear sentence, never a setting.
        let contenders = [leader.language, runnerUp.language]
        if let previous, contenders.contains(previous) {
            return LanguageDecision(language: previous, reason: .continuedFromPrevious)
        }
        if contenders.contains(profile.primary) {
            return LanguageDecision(language: profile.primary, reason: .fellBackToPreferred)
        }
        return LanguageDecision(language: leader.language, reason: .leadWithoutMargin)
    }

    /// The selected languages the engine ranked, most likely first.
    ///
    /// Ties keep the profile's own order, so two languages the engine cannot
    /// separate at all are separated by the user's preference rather than by
    /// whichever came out of a dictionary first.
    static func rank(
        profile: LanguageProfile,
        probabilities: [String: Float]
    ) -> [(language: SpeechLanguage, probability: Float)] {
        var ranked: [(position: Int, language: SpeechLanguage, probability: Float)] = []
        for (position, language) in profile.languages.enumerated() {
            guard let probability = probabilities[language.rawValue] else { continue }
            ranked.append((position: position, language: language, probability: probability))
        }
        ranked.sort { left, right in
            left.probability == right.probability
                ? left.position < right.position
                : left.probability > right.probability
        }
        return ranked.map { (language: $0.language, probability: $0.probability) }
    }
}
