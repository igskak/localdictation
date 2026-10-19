import XCTest
@testable import Witness

final class CleanupTimingEvidenceTests: XCTestCase {
    private func token(_ range: Range<Int>, _ start: Double, _ end: Double) -> CleanupTokenTiming {
        CleanupTokenTiming(rawRange: range, start: start, end: end, confidence: nil)
    }

    func testValidAndOverlappingTimeRangesAreAccepted() {
        let tokens = [token(0..<3, 0, 0.5), token(4..<7, 0.4, 0.8)]
        XCTAssertEqual(CleanupTimingEvidence.validated(tokens, raw: "one two")?.tokens, tokens)
    }

    func testMalformedEvidenceIsRejectedAsAWhole() {
        let first = token(0..<3, 0, 1)
        for second in [token(4..<7, .nan, 2), token(4..<7, 1, .infinity), token(4..<7, -1, 2),
                       token(4..<7, 2, 1), token(4..<7, 0.5, 0.8), token(7..<9, 1, 2),
                       token(2..<4, 1, 2), token(4..<4, 1, 2)] {
            XCTAssertNil(CleanupTimingEvidence.validated([first, second], raw: "one two"))
        }
        XCTAssertNil(CleanupTimingEvidence.validated([], raw: "one two"))
    }

    func testTranscriptAnchorsMustMatchTheRawTextIncludingGraphemes() {
        let raw = "ä 🌍"
        let valid = TranscriptToken(text: "ä", range: 0..<1, start: 0, end: 0.5, confidence: 0.9)
        let invalid = TranscriptToken(text: "x", range: 2..<3, start: 1, end: 2, confidence: nil)
        let transcript = Transcript(text: raw, tokens: [valid, invalid], profile: .english,
                                    detectedLanguage: .english, audioDuration: 2,
                                    processingDuration: 1, engineIdentifier: "fixture")
        XCTAssertNil(CleanupTimingEvidence.validated(transcript: transcript))
        let matching = TranscriptToken(text: "🌍", range: 2..<3, start: 1, end: 2, confidence: nil)
        let good = Transcript(text: raw, tokens: [valid, matching], profile: .english,
                              detectedLanguage: .english, audioDuration: 2,
                              processingDuration: 1, engineIdentifier: "fixture")
        XCTAssertNotNil(CleanupTimingEvidence.validated(transcript: good))
    }

    func testSegmentBoundaryAndIdenticalPositiveDurationAreRequiredForDuplicateRemoval() throws {
        let raw = "go go now"
        let pipeline = ConservativePipeline()
        let unknownBoundary = try XCTUnwrap(CleanupTimingEvidence.validated(
            [token(0..<2, 0, 0.5), token(3..<5, 0, 0.5), token(6..<9, 0.6, 1)], raw: raw))
        let unproven = pipeline.clean(raw, language: .english, options: CleanupOptions(timing: unknownBoundary))
        XCTAssertFalse(unproven.edits.contains { $0.kind == .boundaryDuplicateRemoval })
        var boundaryToken = token(3..<5, 0, 0.5)
        boundaryToken.segmentBoundaryBefore = true
        let overlap = try XCTUnwrap(CleanupTimingEvidence.validated(
            [token(0..<2, 0, 0.5), boundaryToken, token(6..<9, 0.6, 1)], raw: raw))
        let options = CleanupOptions(timing: overlap)
        let result = pipeline.clean(raw, language: .english, options: options)
        XCTAssertEqual(result.cleaned, "Go now.")
        XCTAssertEqual(result.raw, raw)
        XCTAssertTrue(result.edits.contains { $0.kind == .boundaryDuplicateRemoval })
        let clean = AdaptiveCleanupService().clean(raw, language: .english,
                                                   options: CleanupOptions(level: .clean, timing: overlap))
        XCTAssertTrue(clean.edits.contains { $0.kind == .boundaryDuplicateRemoval })
        XCTAssertEqual(clean.raw, raw)
        let adjacent = try XCTUnwrap(CleanupTimingEvidence.validated(
            [token(0..<2, 0, 0.5), token(2..<4, 0, 0.5)], raw: "gogo"))
        let subwords = pipeline.clean("gogo", language: .english, options: CleanupOptions(timing: adjacent))
        XCTAssertFalse(subwords.edits.contains { $0.kind == .boundaryDuplicateRemoval })
        for evidence in [
            [token(0..<2, 0, 0.5), token(3..<5, 0.4, 0.9), token(6..<9, 1, 2)],
            [token(0..<2, 0, 0), token(3..<5, 0, 0), token(6..<9, 1, 2)],
        ] {
            let valid = try XCTUnwrap(CleanupTimingEvidence.validated(evidence, raw: raw))
            let unchanged = pipeline.clean(raw, language: .english, options: CleanupOptions(timing: valid))
            XCTAssertFalse(unchanged.edits.contains { $0.kind == .boundaryDuplicateRemoval })
        }
    }

    func testTimingDoesNotChangeCurrentTextOnlyCleanup() throws {
        let raw = "one two"
        let timing = try XCTUnwrap(CleanupTimingEvidence.validated([token(0..<3, 0, 0.5), token(4..<7, 2, 3)], raw: raw))
        let service = AdaptiveCleanupService()
        for level in [CleanupLevel.verbatim, .conservative, .clean] {
            let without = service.clean(raw, language: .english, options: CleanupOptions(level: level))
            let with = service.clean(raw, language: .english, options: CleanupOptions(level: level, timing: timing))
            XCTAssertEqual(with, without)
        }
    }
}
