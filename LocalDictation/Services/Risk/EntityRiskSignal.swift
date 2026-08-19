import Foundation

/// Names, per language.
///
/// The obvious heuristic — a capitalized word in the middle of a sentence — is
/// valid in English, Russian, and Ukrainian, and **meaningless in German**,
/// where every noun is capitalized. Running it there would mark most of the
/// sentence and teach the user that the marks mean nothing.
///
/// So German gets a different, much narrower rule set: a name announced by a
/// title, and acronyms. Broad German name detection needs a tagged model, which
/// is a Phase 3 non-goal — the glossary is what covers the names a particular
/// user actually cares about, and it works in every language.
struct EntityRiskSignal: RiskSignal {
    let identifier = "entities"

    /// Words that announce a person's name in the following word.
    static let titleMarkers: [SpeechLanguage: Set<String>] = [
        .german: ["herr", "frau", "dr", "prof", "familie"],
        .english: ["mr", "mrs", "ms", "miss", "dr", "prof", "professor"],
        .russian: ["господин", "госпожа", "г-н", "г-жа", "доктор", "профессор"],
        .ukrainian: ["пан", "пані", "добродій", "доктор", "професор"],
    ]

    /// Capitalization says nothing about nouns in German, so the mid-sentence
    /// heuristic is switched off there rather than tuned.
    static func usesCapitalizationHeuristic(_ language: SpeechLanguage) -> Bool {
        language != .german
    }

    func spans(in context: RiskContext) -> [RawRiskSpan] {
        let markers = Self.titleMarkers[context.language] ?? []
        let usesCapitalization = Self.usesCapitalizationHeuristic(context.language)
        var spans: [RawRiskSpan] = []
        var previousWasMarker = false

        for word in context.words {
            defer { previousWasMarker = markers.contains(word.lowercased) }

            // A number is already marked by its own signal, and marking it
            // twice would say the same thing in two places.
            guard !CriticalTokens.containsDigit(word.text) else { continue }
            guard let first = word.text.first else { continue }

            if previousWasMarker, first.isUppercase {
                spans.append(RawRiskSpan(reason: .namedEntity, range: word.range))
                continue
            }

            // Acronyms are names in every one of the four languages, German
            // included, and are cheap to misrecognize.
            if word.text.count >= 2, word.text.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                spans.append(RawRiskSpan(reason: .namedEntity, range: word.range))
                continue
            }

            if usesCapitalization, !word.isSentenceInitial, first.isUppercase {
                // English "I" is capitalized everywhere and is not a name.
                if context.language == .english, word.lowercased == "i" { continue }
                spans.append(RawRiskSpan(reason: .namedEntity, range: word.range))
            }
        }

        return spans
    }
}
