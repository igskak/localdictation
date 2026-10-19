import XCTest
@testable import Witness

final class AdaptiveCleanupFoundationTests: XCTestCase {
    private let service = AdaptiveCleanupService()

    func testVerbatimIsAnIdentity() {
        let raw = "  uh hello comma  "
        let result = service.clean(raw, language: .english, options: CleanupOptions(level: .verbatim))
        XCTAssertEqual(result.cleaned, raw)
        XCTAssertFalse(result.map.hasEdits)
        XCTAssertTrue(result.edits.isEmpty)
    }

    func testConservativeHasExactParityWithTheExistingService() {
        let legacy = ConservativeCleanupService()
        for language in SpeechLanguage.verified {
            let raw = "  uh ähм ээ ее hello 1450 euro  "
            XCTAssertEqual(
                service.clean(raw, language: language, options: CleanupOptions(level: .conservative)),
                legacy.clean(raw, language: language)
            )
        }
    }

    func testCleanRetainsConservativeBehaviorWithoutAnAdaptiveTrigger() {
        let raw = "hello world"
        XCTAssertEqual(
            service.clean(raw, language: .english, options: CleanupOptions(level: .clean)).cleaned,
            service.clean(raw, language: .english, options: CleanupOptions(level: .conservative)).cleaned
        )
    }

#if WITNESS_PHASE_9_1_PREVIEW
    func testPreviewKeepsThreeDistinctCleanupLevels() throws {
        let transcript = Transcript.assemble(words: [
            .init("Во", start: 0, end: 0.1), .init("-первых", start: 0.1, end: 0.2),
            .init("это", start: 0.2, end: 0.3), .init("первый", start: 0.3, end: 0.45),
            .init("длинный", start: 0.45, end: 0.6), .init("фрагмент", start: 0.6, end: 0.8),
            .init("теперь", start: 1.8, end: 1.95), .init("начинается", start: 1.95, end: 2.1),
            .init("второй", start: 2.1, end: 2.25), .init("длинный", start: 2.25, end: 2.4),
            .init("фрагмент", start: 2.4, end: 2.6),
        ], profile: .russian, audioDuration: 3, processingDuration: 1, engineIdentifier: "fixture")
        let timing = try XCTUnwrap(CleanupTimingEvidence.validated(transcript: transcript))
        let raw = transcript.text
        XCTAssertEqual(service.clean(raw, language: .russian,
                                     options: CleanupOptions(level: .verbatim, timing: timing)).cleaned,
                       "Во -первых это первый длинный фрагмент теперь начинается второй длинный фрагмент")
        XCTAssertEqual(service.clean(raw, language: .russian,
                                     options: CleanupOptions(level: .conservative, timing: timing)).cleaned,
                       "Во-первых это первый длинный фрагмент теперь начинается второй длинный фрагмент.")
        XCTAssertEqual(service.clean(raw, language: .russian,
                                     options: CleanupOptions(level: .clean, timing: timing)).cleaned,
                       "Во-первых это первый длинный фрагмент. Теперь начинается второй длинный фрагмент.")
    }

    func testPreviewReservesLongPausesForParagraphs() throws {
        let transcript = Transcript.assemble(words: [
            .init("это", start: 0, end: 0.1), .init("первый", start: 0.1, end: 0.2),
            .init("достаточно", start: 0.2, end: 0.35), .init("длинный", start: 0.35, end: 0.5),
            .init("фрагмент", start: 0.5, end: 0.7), .init("теперь", start: 2.8, end: 2.9),
            .init("идёт", start: 2.9, end: 3.0), .init("второй", start: 3.0, end: 3.1),
            .init("достаточно", start: 3.1, end: 3.25), .init("длинный", start: 3.25, end: 3.4),
            .init("фрагмент", start: 3.4, end: 3.6),
        ], profile: .russian, audioDuration: 4, processingDuration: 1, engineIdentifier: "fixture")
        let timing = try XCTUnwrap(CleanupTimingEvidence.validated(transcript: transcript))
        let result = service.clean(transcript.text, language: .russian,
                                   options: CleanupOptions(level: .clean, timing: timing))
        XCTAssertEqual(result.cleaned,
                       "Это первый достаточно длинный фрагмент.\n\nТеперь идёт второй достаточно длинный фрагмент.")
        XCTAssertEqual(result.edits.filter { $0.kind == .inferredParagraphBreak }.count, 1)
        XCTAssertFalse(result.edits.contains { $0.kind == .inferredPunctuation })
    }
#endif

    func testProtectedDetectorFindsFactsNegationGlossaryAndEntities() {
        let glossary = [GlossaryEntry(term: "Acme Cloud", language: .english)]
        let spans = ProtectedSpanDetector().detect(
            in: "Send not 20 euro to Acme Cloud on Friday",
            language: .english,
            glossary: glossary
        )
        XCTAssertTrue(spans.contains { $0.category == .negation && $0.text == "not" })
        XCTAssertTrue(spans.contains { $0.category == .number && $0.text == "20" })
        XCTAssertTrue(spans.contains { $0.category == .currency && $0.text == "euro" })
        XCTAssertTrue(spans.contains { $0.category == .glossary && $0.text == "Acme Cloud" })
        XCTAssertTrue(spans.contains { $0.category == .date && $0.text == "Friday" })
    }

    func testProtectedConflictAllowsOnlyAnOwningWholeSpanEdit() throws {
        let span = try XCTUnwrap(ProtectedSpanDetector().detect(in: "not", language: .english).first)
        XCTAssertFalse(ProtectedSpanDetector.allows(proposed: 0..<3, protected: [span]))
        XCTAssertFalse(ProtectedSpanDetector.allows(proposed: 0..<2, protected: [span], owningWholeSpan: .negation))
        XCTAssertTrue(ProtectedSpanDetector.allows(proposed: 0..<3, protected: [span], owningWholeSpan: .negation))
    }
}
