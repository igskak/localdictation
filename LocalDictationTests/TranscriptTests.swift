import XCTest
@testable import Witness

final class TranscriptTests: XCTestCase {
    func testAssembleComputesCharacterRangesForLatinText() {
        let transcript = Transcript.fixture(words: [("Hello", 0.9), ("world", 0.8)])

        XCTAssertEqual(transcript.text, "Hello world")
        XCTAssertEqual(transcript.tokens.map(\.range), [0..<5, 6..<11])
    }

    /// German umlauts and ß are multi-byte in UTF-8. Counting bytes instead of
    /// characters here would misplace every span Phase 3 needs to highlight.
    func testAssembleCountsCharactersNotBytesForGerman() {
        let transcript = Transcript.fixture(
            words: [("Größe", 0.9), ("überprüfen", 0.7)],
            profile: .german
        )

        XCTAssertEqual(transcript.text, "Größe überprüfen")
        XCTAssertEqual(transcript.tokens[0].range, 0..<5)
        XCTAssertEqual(transcript.tokens[1].range, 6..<16)

        for token in transcript.tokens {
            let range = try? XCTUnwrap(transcript.resolvedRange(for: token))
            XCTAssertEqual(range.map { String(transcript.text[$0]) }, token.text)
        }
    }

    func testAssembleCountsCharactersNotBytesForCyrillic() {
        let transcript = Transcript.fixture(
            words: [("Привіт", 0.9), ("світе", 0.6)],
            profile: .ukrainian
        )

        XCTAssertEqual(transcript.text, "Привіт світе")
        XCTAssertEqual(transcript.tokens[0].range, 0..<6)
        XCTAssertEqual(transcript.tokens[1].range, 7..<12)

        let second = transcript.tokens[1]
        let resolved = transcript.resolvedRange(for: second)
        XCTAssertEqual(resolved.map { String(transcript.text[$0]) }, "світе")
    }

    func testAssembleSkipsEmptyWordsWithoutLeavingGaps() {
        let transcript = Transcript.fixture(words: [("one", 0.9), ("", 0.5), ("two", 0.8)])

        XCTAssertEqual(transcript.text, "one two")
        XCTAssertEqual(transcript.tokens.count, 2)
        XCTAssertEqual(transcript.tokens.map(\.text), ["one", "two"])
    }

    func testResolvedRangeReturnsNilForAnOutOfBoundsToken() {
        let transcript = Transcript(
            text: "short",
            tokens: [TranscriptToken(text: "short", range: 0..<99, start: 0, end: 1, confidence: nil)],
            profile: .english,
            detectedLanguage: nil,
            audioDuration: 1,
            processingDuration: 0.1,
            engineIdentifier: "test"
        )

        XCTAssertNil(transcript.resolvedRange(for: transcript.tokens[0]))
    }

    func testConfidenceAggregatesIgnoreMissingValues() {
        let transcript = Transcript.fixture(words: [("a", 0.9), ("b", nil), ("c", 0.5)])

        XCTAssertTrue(transcript.hasConfidenceSignal)
        XCTAssertEqual(try XCTUnwrap(transcript.meanConfidence), 0.7, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(transcript.minimumConfidence), 0.5, accuracy: 0.0001)
    }

    /// An engine that reports no confidence at all cannot support Phase 3, so
    /// the absence has to be detectable rather than read as "all certain".
    func testEngineWithoutConfidenceIsDetectable() {
        let transcript = Transcript.fixture(words: [("a", nil), ("b", nil)])

        XCTAssertFalse(transcript.hasConfidenceSignal)
        XCTAssertNil(transcript.meanConfidence)
    }

    func testRealTimeFactorIsNilWithoutAudio() {
        let empty = Transcript.empty(profile: .default, engineIdentifier: "test")
        XCTAssertNil(empty.realTimeFactor)
        XCTAssertTrue(empty.isEmpty)
    }

    func testRealTimeFactorComparesInferenceToAudioLength() {
        let transcript = Transcript.fixture(
            words: [("a", 0.9)],
            audioDuration: 4,
            processingDuration: 1
        )
        XCTAssertEqual(try XCTUnwrap(transcript.realTimeFactor), 0.25, accuracy: 0.0001)
    }

    func testTokensAtOrBelowThresholdTreatMissingConfidenceAsCertain() {
        let transcript = Transcript.fixture(words: [("a", 0.2), ("b", nil), ("c", 0.9)])
        XCTAssertEqual(transcript.tokens(atOrBelow: 0.5).map(\.text), ["a"])
    }
}
