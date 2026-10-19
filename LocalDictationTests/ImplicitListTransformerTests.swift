import XCTest
@testable import Witness

final class ImplicitListTransformerTests: XCTestCase {
    func testOnlyMeasuredPausesAndSequentialMarkersBoundAList() throws {
        let transcript = Transcript.assemble(words: [
            .init("shopping", start: 0, end: 0.2), .init("first", start: 1.5, end: 1.6),
            .init("apples", start: 1.6, end: 1.8), .init("second", start: 1.8, end: 1.9),
            .init("pears", start: 1.9, end: 2.1), .init("afterward", start: 4, end: 4.1),
            .init("lunch", start: 4.1, end: 4.2),
        ], profile: .english, audioDuration: 5, processingDuration: 1, engineIdentifier: "fixture")
        let timing = try XCTUnwrap(CleanupTimingEvidence.validated(transcript: transcript))
        let source = CleanupResult.unchanged(transcript.text, language: .english)
        let policy = ImplicitListPolicy(introductionWords: ["shopping"], pauseBeforeFirst: 1, pauseAfterList: 1)
        let transformer = ImplicitListTransformer()
        let stage = transformer.transform(raw: transcript.text, result: source, evidence: timing,
                                          language: .english, policy: policy, protected: [])
        XCTAssertEqual(stage.cleaned, "shopping\n1. apples\n2. pears\n\nafterward lunch")
        XCTAssertEqual(stage.edits.map(\.kind), [.listFormatting, .listFormatting, .inferredParagraphBreak])
        let blocked = transformer.transform(raw: transcript.text, result: source, evidence: timing,
                                            language: .english, policy: policy,
                                            protected: [.init(range: timing.tokens[1].rawRange, category: .glossary, text: "first")])
        XCTAssertEqual(blocked.cleaned, transcript.text)
        for language in [SpeechLanguage.english, .german, .russian, .ukrainian] {
            XCTAssertNil(ImplicitListPolicy.measuredPolicy(for: language))
        }
    }
}
