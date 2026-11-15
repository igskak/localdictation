import XCTest
@testable import Witness

/// The structure pass may only touch punctuation and line breaks, and only
/// where the words or the melody give it a reason.
final class StructurePassTests: XCTestCase {
    // MARK: - Pitch

    private func tone(_ segments: [(seconds: Double, from: Double, to: Double)], sampleRate: Double = 16_000) -> [Float] {
        var samples: [Float] = []
        var phase = 0.0
        for segment in segments {
            let count = Int(segment.seconds * sampleRate)
            for index in 0..<count {
                let frequency = segment.from + (segment.to - segment.from) * Double(index) / Double(count)
                phase += 2 * .pi * frequency / sampleRate
                // Three harmonics, so the tracker sees something voice-like.
                samples.append(Float(0.3 * sin(phase) + 0.15 * sin(2 * phase) + 0.08 * sin(3 * phase)))
            }
        }
        return samples
    }

    func testASteadyToneIsTrackedAtItsPitch() throws {
        let evidence = try XCTUnwrap(PitchTracker.evidence(samples: tone([(1.0, 200, 200)]), sampleRate: 16_000))
        let median = try XCTUnwrap(evidence.medianF0)
        XCTAssertEqual(median, 200, accuracy: 4)
    }

    func testSilenceHasNoPitch() {
        let evidence = PitchTracker.evidence(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        XCTAssertNil(evidence?.medianF0)
    }

    func testARisingEndingRisesAndAFallingOneDoesNot() throws {
        let rising = try XCTUnwrap(PitchTracker.evidence(
            samples: tone([(1.5, 150, 150), (0.6, 150, 260)]), sampleRate: 16_000
        )?.ending(at: 2.1))
        let falling = try XCTUnwrap(PitchTracker.evidence(
            samples: tone([(1.5, 150, 150), (0.6, 150, 105)]), sampleRate: 16_000
        )?.ending(at: 2.1))

        XCTAssertGreaterThan(rising.rise, 5)
        XCTAssertGreaterThan(rising.peakPosition, 0.6)
        XCTAssertLessThan(falling.rise, 1)
        XCTAssertLessThan(falling.tail, -3)
        XCTAssertTrue(QuestionProsodyPolicy.calibrated.isQuestionLike(rising))
        XCTAssertFalse(QuestionProsodyPolicy.calibrated.isQuestionLike(falling))
    }

    // MARK: - Lexical cues

    private func cue(_ text: String, _ language: SpeechLanguage) -> QuestionCue {
        let words = WordScanner.words(in: text).map(\.lowercased)
        return QuestionCues.cue(words: words, hasComma: text.contains(","), language: language)
    }

    func testQuestionWordsAndParticlesAreCues() {
        XCTAssertEqual(cue("Когда ты будешь дома", .russian), .interrogative)
        XCTAssertEqual(cue("Де лежать документи", .ukrainian), .interrogative)
        XCTAssertEqual(cue("Чи ти вдома", .ukrainian), .particle)
        XCTAssertEqual(cue("Придёшь ли ты завтра", .russian), .particle)
        XCTAssertEqual(cue("Разве это нормально", .russian), .particle)
    }

    func testClausesAndIndirectQuestionsAreNotCues() {
        XCTAssertEqual(cue("Когда закончишь, напиши", .russian), .none)
        XCTAssertEqual(cue("Как только он придёт", .russian), .none)
        XCTAssertEqual(cue("Он спросил, сможем ли мы приехать раньше", .russian), .none)
        XCTAssertEqual(cue("Він запитав, чи зможемо ми приїхати раніше", .ukrainian), .none)
        XCTAssertEqual(cue("Скажи мне, где ты оставил ключи", .russian), .none)
        XCTAssertEqual(cue("Ты придёшь завтра", .russian), .none, "only the melody can say")
    }

    // MARK: - Question repair

    private func clean(
        _ raw: String,
        _ language: SpeechLanguage,
        prosody: ProsodyEvidence? = nil,
        secondsPerWord: TimeInterval = 0.4
    ) -> CleanupResult {
        let transcript = Transcript.fixture(text: raw, profile: LanguageProfile(language), secondsPerWord: secondsPerWord)
        return AdaptiveCleanupService().clean(
            raw,
            language: language,
            options: CleanupOptions(
                level: .clean,
                timing: CleanupTimingEvidence.validated(transcript: transcript),
                prosody: prosody
            )
        )
    }

    func testAQuestionWordSentenceGetsItsQuestionMark() {
        let result = clean("когда ты будешь дома.", .russian)
        XCTAssertEqual(result.cleaned, "Когда ты будешь дома?")
        XCTAssertTrue(result.edits.contains { $0.kind == .inferredPunctuation })
    }

    func testAClauseKeepsItsPeriod() {
        XCTAssertEqual(clean("Когда закончишь, напиши.", .russian).cleaned, "Когда закончишь, напиши.")
    }

    func testGermanAndEnglishAreLeftToTheRecognizer() {
        XCTAssertEqual(clean("Wann bist du zu Hause.", .german).cleaned, "Wann bist du zu Hause.")
    }

    /// Four words at 0.4 s each end at 1.6 s; the pitch track below rises over
    /// the last 0.6 s of that.
    private func prosody(endingFrom start: Float, to end: Float) -> ProsodyEvidence {
        let frames = Int(1.7 / ProsodyEvidence.hop)
        let rampStart = Int(1.0 / ProsodyEvidence.hop)
        return ProsodyEvidence(f0: (0..<frames).map { frame in
            guard frame >= rampStart else { return start }
            let progress = Float(frame - rampStart) / Float(frames - rampStart)
            return start + (end - start) * progress
        })
    }

    func testARisingMelodyMakesAPlainSentenceAQuestion() {
        let result = clean("Ты придёшь завтра вечером.", .russian, prosody: prosody(endingFrom: 150, to: 260))
        XCTAssertEqual(result.cleaned, "Ты придёшь завтра вечером?")
    }

    func testAFallingMelodyLeavesAStatement() {
        let result = clean("Ты придёшь завтра вечером.", .russian, prosody: prosody(endingFrom: 150, to: 105))
        XCTAssertEqual(result.cleaned, "Ты придёшь завтра вечером.")
    }

    func testWithoutMelodyAPlainSentenceStays() {
        XCTAssertEqual(clean("Ты придёшь завтра вечером.", .russian).cleaned, "Ты придёшь завтра вечером.")
    }

    func testAnOpenEndCanBecomeAQuestionInsteadOfAPeriod() {
        let result = clean("ты придёшь завтра вечером", .russian, prosody: prosody(endingFrom: 150, to: 260))
        XCTAssertEqual(result.cleaned, "Ты придёшь завтра вечером?")
    }

    func testConservativeNeverRepairs() {
        let result = AdaptiveCleanupService().clean(
            "когда ты будешь дома.",
            language: .russian,
            options: CleanupOptions(level: .conservative)
        )
        XCTAssertEqual(result.cleaned, "Когда ты будешь дома.")
    }

    // MARK: - Paragraphs

    func testALongPauseAfterAFinishedSentenceStartsAParagraph() {
        let raw = "Сегодня был тяжёлый день, мы всё успели. Завтра начнём с тестов и созвонимся с поставщиком."
        let words = WordScanner.words(in: raw)
        // 0.3 s per word, and a 1.5 s pause after "успели."
        var time: TimeInterval = 0
        let tokens = words.map { word -> TranscriptToken in
            defer { time += word.text == "успели" ? 1.8 : 0.3 }
            return TranscriptToken(text: word.text, range: word.range, start: time, end: time + 0.3, confidence: 0.9)
        }
        let timing = CleanupTimingEvidence.validated(Self.timings(raw: raw, tokens: tokens), raw: raw)
        let result = AdaptiveCleanupService().clean(
            raw,
            language: .russian,
            options: CleanupOptions(level: .clean, timing: timing)
        )
        XCTAssertTrue(result.cleaned.contains("успели.\n\nЗавтра"), result.cleaned)
        XCTAssertTrue(result.edits.contains { $0.kind == .inferredParagraphBreak })
    }

    func testAShortPauseDoesNotStartAParagraph() {
        let result = clean("Сегодня был тяжёлый день, мы всё успели. Завтра начнём с тестов и созвонимся.", .russian)
        XCTAssertFalse(result.cleaned.contains("\n"))
    }

    /// Timings whose ranges cover the token text with its punctuation, the
    /// way Whisper's words carry theirs.
    private static func timings(raw: String, tokens: [TranscriptToken]) -> [CleanupTokenTiming] {
        let characters = Array(raw)
        return tokens.map { token in
            var end = token.range.upperBound
            while end < characters.count, !characters[end].isWhitespace { end += 1 }
            return CleanupTokenTiming(rawRange: token.range.lowerBound..<end, start: token.start, end: token.end, confidence: 0.9)
        }
    }
}
