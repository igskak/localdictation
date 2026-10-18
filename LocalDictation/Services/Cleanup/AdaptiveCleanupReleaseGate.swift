import Foundation

struct AdaptiveCleanupLanguageMetrics: Sendable, Equatable {
    let language: SpeechLanguage
    let protectedValuePreservation: Double
    let negationPreservation: Double
    let criticalSemanticPreservation: Double
    let wordRemovalPrecision: Double
    let spokenCommandPrecision: Double
    let typedValueCorrectness: Double
}

struct AdaptiveCleanupReleaseEvidence: Sendable, Equatable {
    let languages: [AdaptiveCleanupLanguageMetrics]
    let contextJoinCorrectness: Double
    let cleanPreference: Double
    let p95OverheadMilliseconds: Double
    let contextFallbackMilliseconds: Double
    let realSpeechCorpusCompleted: Bool
    let manualCompatibilityCompleted: Bool
    let repeatedDictationSoakCompleted: Bool
}

enum AdaptiveCleanupReleaseGate {
    static func passes(_ evidence: AdaptiveCleanupReleaseEvidence) -> Bool {
        let reports = Dictionary(evidence.languages.map { ($0.language, $0) }, uniquingKeysWith: { first, _ in first })
        guard Set(reports.keys) == Set(SpeechLanguage.verified),
              reports.count == evidence.languages.count,
              evidence.realSpeechCorpusCompleted,
              evidence.manualCompatibilityCompleted,
              evidence.repeatedDictationSoakCompleted,
              evidence.contextJoinCorrectness >= 0.995,
              evidence.cleanPreference >= 0.70,
              evidence.p95OverheadMilliseconds <= 75,
              evidence.contextFallbackMilliseconds <= 150
        else { return false }

        return reports.values.allSatisfy {
            $0.protectedValuePreservation == 1
                && $0.negationPreservation == 1
                && $0.criticalSemanticPreservation == 1
                && $0.wordRemovalPrecision >= 0.995
                && $0.spokenCommandPrecision >= 0.995
                && $0.typedValueCorrectness == 1
        }
    }

    /// No measurement evidence is embedded in a shipping build. A future
    /// release may pass its signed-off report here only after every gate above
    /// has been recorded. Missing evidence is deliberately Conservative.
    static func defaultLevel(for evidence: AdaptiveCleanupReleaseEvidence?) -> CleanupLevel {
        evidence.map(passes) == true ? .clean : .conservative
    }
}

