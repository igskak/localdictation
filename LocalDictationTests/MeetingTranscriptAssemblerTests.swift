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

    func testPunctuationOnlyBoundaryDifferenceDoesNotRepeatAWord() {
        var assembler = MeetingTranscriptAssembler()
        assembler.append(window(.system, start: 0, end: 32_000, text: "hello world!",
                                words: [("hello", 0..<5, 0, 0.5), ("world", 6..<11, 1, 1.5)]))
        assembler.append(window(.system, start: 16_000, end: 48_000, text: "world, again",
                                words: [("world", 0..<5, 0, 0.5), ("again", 7..<12, 1, 1.5)]))
        XCTAssertEqual(assembler.rows.map(\.text), ["hello world!", "again"])
    }

    func testRepeatedPhraseUsesTimingToRemoveOnlyTheActualOverlap() {
        var assembler = MeetingTranscriptAssembler()
        assembler.append(window(.system, start: 0, end: 24_000, text: "go go",
                                words: [("go", 0..<2, 0, 0.2), ("go", 3..<5, 0.5, 0.7)]))
        assembler.append(window(.system, start: 8_000, end: 32_000, text: "go now",
                                words: [("go", 0..<2, 0, 0.2), ("now", 3..<6, 0.5, 0.7)]))
        XCTAssertEqual(assembler.rows.map(\.text), ["go go", "now"])
    }

    func testLateWindowRebuildsTimelineWithoutChangingRawArrivalOrder() {
        var assembler = MeetingTranscriptAssembler()
        let later = window(.system, start: 16_000, end: 48_000, text: "world again",
                           words: [("world", 0..<5, 0, 0.5), ("again", 6..<11, 1, 1.5)])
        let earlier = window(.system, start: 0, end: 32_000, text: "hello world",
                             words: [("hello", 0..<5, 0, 0.5), ("world", 6..<11, 1, 1.5)])
        assembler.append(later)
        assembler.append(earlier)
        XCTAssertEqual(assembler.rawWindows.map(\.startFrame), [16_000, 0])
        XCTAssertEqual(assembler.rows.map(\.text), ["hello world", "again"])
    }

    func testSameTimestampPreservesArrivalOrderAcrossSimultaneousSources() {
        var assembler = MeetingTranscriptAssembler()
        assembler.append(window(.system, start: 0, end: 16_000, text: "remote",
                                words: [("remote", 0..<6, 0, 0.5)]))
        assembler.append(window(.microphone, start: 0, end: 16_000, text: "local",
                                words: [("local", 0..<5, 0, 0.5)]))
        XCTAssertEqual(assembler.rows.map(\.source), [.system, .microphone])
    }

    func testFourVerifiedLanguagesRemainVerbatimAcrossTurns() {
        var assembler = MeetingTranscriptAssembler()
        let fixtures: [(String, LanguageProfile, SpeechLanguage)] = [
            ("Guten Tag", .german, .german),
            ("hello", .english, .english),
            ("привет", .russian, .russian),
            ("привіт", .ukrainian, .ukrainian)
        ]
        for (index, fixture) in fixtures.enumerated() {
            let start = Int64(index * 16_000)
            assembler.append(window(.system, start: start, end: start + 8_000, text: fixture.0,
                                    words: [(fixture.0, 0..<fixture.0.count, 0, 0.5)],
                                    profile: fixture.1, language: fixture.2))
        }
        XCTAssertEqual(assembler.rows.map(\.text), fixtures.map { $0.0 })
        XCTAssertEqual(assembler.rows.map { $0.original.detectedLanguage }, fixtures.map { $0.2 })
    }

    private func window(_ source: MeetingAudioSource, start: Int64, end: Int64, text: String,
                        words: [(String, Range<Int>, Double, Double)],
                        profile: LanguageProfile = .english,
                        language: SpeechLanguage = .english) -> MeetingTranscriptWindow {
        let tokens = words.map { TranscriptToken(text: $0.0, range: $0.1, start: $0.2, end: $0.3, confidence: 0.8) }
        let transcript = Transcript(text: text, tokens: tokens, profile: profile, detectedLanguage: language,
                                    audioDuration: Double(end-start)/16_000, processingDuration: 0, engineIdentifier: "test")
        return MeetingTranscriptWindow(source: source, startFrame: start, endFrame: end, transcript: transcript)
    }
}
