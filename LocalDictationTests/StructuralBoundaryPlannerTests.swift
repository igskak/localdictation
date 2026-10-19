import XCTest
@testable import Witness

final class StructuralBoundaryPlannerTests: XCTestCase {
    func testFixtureThresholdFindsOnlyEvidencedGap() throws {
        let raw = "we will leave tomorrow we return later"
        let words = Transcript.assemble(words: [
            .init("we", start: 0, end: 0.1), .init("will", start: 0.1, end: 0.2),
            .init("leave", start: 0.2, end: 0.4), .init("tomorrow", start: 0.4, end: 0.6),
            .init("we", start: 2.0, end: 2.1), .init("return", start: 2.1, end: 2.3),
            .init("later", start: 2.3, end: 2.5),
        ], profile: .english, audioDuration: 3, processingDuration: 1, engineIdentifier: "fixture")
        XCTAssertEqual(words.text, raw)
        let evidence = try XCTUnwrap(CleanupTimingEvidence.validated(transcript: words))
        let policy = StructuralBoundaryPolicy(sentenceGap: 1, minimumClauseTokens: 4, allowedClauseEndings: ["tomorrow"])
        let planner = StructuralBoundaryPlanner()
        let result = CleanupResult.unchanged(raw, language: .english)
        let candidates = planner.sentences(raw: raw, result: result, evidence: evidence, policy: policy, protected: [])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].rawAnchor, "we will leave tomorrow".count)
        XCTAssertTrue(planner.sentences(raw: raw, result: result, evidence: evidence, policy: policy,
                                       protected: [.init(range: 14..<22, category: .date, text: "tomorrow")]).isEmpty)
        let deleted = CleanupTransformation.apply([.init(range: 14..<22, text: "", kind: .explicitCorrection)],
                                                  to: raw, language: .english)
        XCTAssertTrue(planner.sentences(raw: raw, result: deleted, evidence: evidence,
                                       policy: policy, protected: []).isEmpty)
    }

    func testProductionPoliciesRemainDisabledUntilMeasured() {
        for language in [SpeechLanguage.german, .english, .russian, .ukrainian] {
            XCTAssertNil(StructuralBoundaryPolicy.measuredPolicy(for: language))
        }
    }
}
