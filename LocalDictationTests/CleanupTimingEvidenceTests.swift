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
