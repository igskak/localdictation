import XCTest
@testable import Witness

final class AdaptiveCleanupReleaseGateTests: XCTestCase {
    func testEveryRecordedGateMustPassBeforeCleanCanBeTheDefault() {
        XCTAssertTrue(AdaptiveCleanupReleaseGate.passes(passingEvidence()))
        XCTAssertEqual(AdaptiveCleanupReleaseGate.defaultLevel(for: passingEvidence()), .clean)
    }

    func testMissingEvidenceKeepsConservativeAsTheDefault() {
        XCTAssertEqual(AdaptiveCleanupReleaseGate.defaultLevel(for: nil), .conservative)
        XCTAssertEqual(Preferences.default.cleanupLevel, .conservative)
    }

    func testOneMissingLanguageFailsTheGate() {
        var evidence = passingEvidence()
        evidence = AdaptiveCleanupReleaseEvidence(
            languages: Array(evidence.languages.dropLast()),
            contextJoinCorrectness: evidence.contextJoinCorrectness,
            cleanPreference: evidence.cleanPreference,
            p95OverheadMilliseconds: evidence.p95OverheadMilliseconds,
            contextFallbackMilliseconds: evidence.contextFallbackMilliseconds,
            realSpeechCorpusCompleted: true,
            manualCompatibilityCompleted: true,
            repeatedDictationSoakCompleted: true
        )
        XCTAssertFalse(AdaptiveCleanupReleaseGate.passes(evidence))
    }

    func testAThresholdMissFailsTheWholeGate() {
        let baseline = passingEvidence()
        let evidence = AdaptiveCleanupReleaseEvidence(
            languages: baseline.languages,
            contextJoinCorrectness: 0.994,
            cleanPreference: baseline.cleanPreference,
            p95OverheadMilliseconds: baseline.p95OverheadMilliseconds,
            contextFallbackMilliseconds: baseline.contextFallbackMilliseconds,
            realSpeechCorpusCompleted: true,
            manualCompatibilityCompleted: true,
            repeatedDictationSoakCompleted: true
        )
        XCTAssertFalse(AdaptiveCleanupReleaseGate.passes(evidence))
    }

    private func passingEvidence() -> AdaptiveCleanupReleaseEvidence {
        AdaptiveCleanupReleaseEvidence(
            languages: SpeechLanguage.verified.map {
                AdaptiveCleanupLanguageMetrics(
                    language: $0,
                    protectedValuePreservation: 1,
                    negationPreservation: 1,
                    criticalSemanticPreservation: 1,
                    wordRemovalPrecision: 0.995,
                    spokenCommandPrecision: 0.995,
                    typedValueCorrectness: 1
                )
            },
            contextJoinCorrectness: 0.995,
            cleanPreference: 0.70,
            p95OverheadMilliseconds: 75,
            contextFallbackMilliseconds: 150,
            realSpeechCorpusCompleted: true,
            manualCompatibilityCompleted: true,
            repeatedDictationSoakCompleted: true
        )
    }
}

