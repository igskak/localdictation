import XCTest
@testable import Witness

final class MeetingTranscriptAssemblerTests: XCTestCase {
    func testExactTimedOverlapIsSuppressedButRawEvidenceIsRetained() {
        var assembler = MeetingTranscriptAssembler()
        let a = window(.microphone, start: 0, end: 32_000, text: "hello world", words: [("hello", 0..<5, 0, 0.5), ("world", 6..<11, 1, 1.5)])
        let b = window(.microphone, start: 16_000, end: 48_000, text: "world again", words: [("world", 0..<5, 0, 0.5), ("again", 6..<11, 1, 1.5)])
        assembler.append(a)
        assembler.append(b)
        XCTAssertEqual(assembler.rows.map(\.text), ["hello world", "again"])
        XCTAssertEqual(assembler.rows[1].original.text, "world again")
    }

    func testDifferentSourcesAndMixedLanguagesNeverSuppressEachOther() {
        var assembler = MeetingTranscriptAssembler()
        assembler.append(window(.microphone, start: 0, end: 32_000, text: "не 10", words: [("не", 0..<2, 0, 0.4), ("10", 3..<5, 0.5, 1)]))
        assembler.append(window(.system, start: 0, end: 32_000, text: "не 10", words: [("не", 0..<2, 0, 0.4), ("10", 3..<5, 0.5, 1)]))
        assembler.append(window(.system, start: 32_000, end: 48_000, text: "hello", words: [("hello", 0..<5, 0, 0.4)]))
        XCTAssertEqual(assembler.rows.count, 3)
        XCTAssertEqual(Set(assembler.rows.map(\.speaker)), Set(["You", "Others"]))
        XCTAssertEqual(assembler.rows.last?.text, "hello")
    }

    func testUnrepresentedNegationBetweenMatchedTokensIsNeverRemoved() {
        var assembler = MeetingTranscriptAssembler()
        assembler.append(window(.system, start: 0, end: 32_000, text: "do go", words: [("do", 0..<2, 1, 1.2), ("go", 3..<5, 1.3, 1.5)]))
        assembler.append(window(.system, start: 16_000, end: 48_000, text: "do not go", words: [("do", 0..<2, 0, 0.2), ("go", 7..<9, 0.3, 0.5)]))
        XCTAssertEqual(assembler.rows.last?.text, "do not go")
        XCTAssertEqual(assembler.rawWindows.count, 2)
    }

    func testAmbiguousUnownedPrefixIsNeverRemoved() {
        var assembler = MeetingTranscriptAssembler()
        assembler.append(window(.system, start: 0, end: 32_000, text: "world", words: [("world", 0..<5, 1, 1.5)]))
        assembler.append(window(.system, start: 16_000, end: 48_000, text: "not world", words: [("world", 4..<9, 0, 0.5)]))
        XCTAssertEqual(assembler.rows.last?.text, "not world")
    }

    private func window(_ source: MeetingAudioSource, start: Int64, end: Int64, text: String,
                        words: [(String, Range<Int>, Double, Double)]) -> MeetingTranscriptWindow {
        let tokens = words.map { TranscriptToken(text: $0.0, range: $0.1, start: $0.2, end: $0.3, confidence: 0.8) }
        let transcript = Transcript(text: text, tokens: tokens, profile: .english, detectedLanguage: .english,
                                    audioDuration: Double(end-start)/16_000, processingDuration: 0, engineIdentifier: "test")
        return MeetingTranscriptWindow(source: source, startFrame: start, endFrame: end, transcript: transcript)
    }
}
