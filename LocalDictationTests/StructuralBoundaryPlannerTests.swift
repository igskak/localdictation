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
        let stage = StructuralBoundaryTransformer().sentences(candidates, in: raw, language: .english)
        let composed = try XCTUnwrap(EditMapComposition.append(stage, to: result))
        XCTAssertEqual(composed.cleaned, "we will leave tomorrow. we return later")
        XCTAssertEqual(composed.raw, raw)
        XCTAssertEqual(composed.edits.map(\.kind), [.inferredPunctuation])
        XCTAssertTrue(planner.sentences(raw: raw, result: result, evidence: evidence, policy: policy,
                                       protected: [.init(range: 14..<22, category: .date, text: "tomorrow")]).isEmpty)
        let deleted = CleanupTransformation.apply([.init(range: 14..<22, text: "", kind: .explicitCorrection)],
                                                  to: raw, language: .english)
        XCTAssertTrue(planner.sentences(raw: raw, result: deleted, evidence: evidence,
                                       policy: policy, protected: []).isEmpty)
    }

    func testParagraphRequiresACompletedSentenceAndIsDisabledInCode() throws {
        let transcript = Transcript.assemble(words: [
            .init("we", start: 0, end: 0.1), .init("finished", start: 0.1, end: 0.2),
            .init("our", start: 0.2, end: 0.3), .init("work", start: 0.3, end: 0.4),
            .init("today.", start: 0.4, end: 0.5), .init("we", start: 3, end: 3.1),
            .init("start", start: 3.1, end: 3.2), .init("again", start: 3.2, end: 3.3),
            .init("tomorrow", start: 3.3, end: 3.4),
        ], profile: .english, audioDuration: 4, processingDuration: 1, engineIdentifier: "fixture")
        let timing = try XCTUnwrap(CleanupTimingEvidence.validated(transcript: transcript))
        let policy = StructuralBoundaryPolicy(sentenceGap: 1, minimumClauseTokens: 3,
                                               allowedClauseEndings: [], paragraphGap: 2)
        let result = CleanupResult.unchanged(transcript.text, language: .english)
        let planner = StructuralBoundaryPlanner()
        let candidates = planner.paragraphs(raw: transcript.text, result: result, evidence: timing,
                                             policy: policy, category: .emailDocument, protected: [])
        XCTAssertEqual(candidates.count, 1)
        let stage = StructuralBoundaryTransformer().paragraphs(candidates, in: transcript.text, language: .english)
        XCTAssertEqual(stage.cleaned, "we finished our work today.\n\nwe start again tomorrow")
        XCTAssertEqual(stage.edits.map(\.kind), [.inferredParagraphBreak])
        XCTAssertTrue(planner.paragraphs(raw: transcript.text, result: result, evidence: timing,
                                          policy: policy, category: .codeTerminal, protected: []).isEmpty)
    }

    func testProductionPoliciesRemainDisabledUntilMeasured() {
        for language in [SpeechLanguage.german, .english, .russian, .ukrainian] {
#if WITNESS_PHASE_9_1_PREVIEW
            XCTAssertNotNil(StructuralBoundaryPolicy.measuredPolicy(for: language))
#else
            XCTAssertNil(StructuralBoundaryPolicy.measuredPolicy(for: language))
#endif
        }
    }
}
