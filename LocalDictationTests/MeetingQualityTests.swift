import XCTest
@testable import Witness

/// The five repairs made after the 28.10 Ukrainian call: speaker runs, quiet
/// microphone windows, cleanup, short windows and the meeting's language.
final class MeetingQualityTests: XCTestCase {
    // MARK: Speaker runs

    func testOneVoiceTheDiarizerFlipsWordByWordStaysOneSpeaker() {
        let words = attributions(["speaker-1", "speaker-2", "speaker-1", "speaker-2", "speaker-1"], secondsEach: 0.3)

        XCTAssertEqual(Set(SpeakerAttributedRowBuilder.smoothedSpeakers(words)).count, 1)
    }

    func testAShortRunBetweenTwoRunsOfOneSpeakerJoinsThem() {
        let speakers = Array(repeating: "speaker-1", count: 5) + ["speaker-2"] + Array(repeating: "speaker-1", count: 5)

        XCTAssertEqual(SpeakerAttributedRowBuilder.smoothedSpeakers(attributions(speakers, secondsEach: 0.3)),
                       Array(repeating: "speaker-1", count: 11))
    }

    func testARealTurnOfFourWordsSurvives() {
        let speakers = Array(repeating: "speaker-1", count: 6) + Array(repeating: "speaker-2", count: 4)

        XCTAssertEqual(SpeakerAttributedRowBuilder.smoothedSpeakers(attributions(speakers, secondsEach: 0.2)), speakers)
    }

    func testALongShortReplySurvivesOnItsDuration() {
        let speakers = Array(repeating: "speaker-1", count: 6) + ["speaker-2", "speaker-2"]

        XCTAssertEqual(SpeakerAttributedRowBuilder.smoothedSpeakers(attributions(speakers, secondsEach: 0.8)), speakers)
    }

    func testNoWordsMeansNoSpeakers() {
        XCTAssertEqual(SpeakerAttributedRowBuilder.smoothedSpeakers([]), [])
    }

    // MARK: Quiet microphone

    func testNearSilentMicrophoneWindowIsNotDecoded() {
        // Above the meeting gate, below the dictation threshold throughout:
        // what produced "Продолжение следует..." on 28.10.
        let quiet = MeetingRecognitionAudio(source: .microphone, startFrame: 0, samples: noise(level: 0.003, frames: 400))

        XCTAssertFalse(MeetingSpeechDetector().containsSpeech(in: quiet))
    }

    func testSpokenMicrophoneWindowIsDecoded() {
        let spoken = MeetingRecognitionAudio(source: .microphone, startFrame: 0,
                                             samples: noise(level: 0.003, frames: 300) + noise(level: 0.2, frames: 100))

        XCTAssertTrue(MeetingSpeechDetector().containsSpeech(in: spoken))
    }

    func testQuietSystemAudioKeepsTheConservativeGate() {
        let quiet = MeetingRecognitionAudio(source: .system, startFrame: 0, samples: noise(level: 0.003, frames: 400))

        XCTAssertTrue(MeetingSpeechDetector().containsSpeech(in: quiet))
    }

    // MARK: Echo

    func testQuietOwnVoiceWhileTheCallIsSilentIsDecoded() {
        // 03.11 12:24: the call quiet, Igor's reply at -52 dBFS on a microphone
        // that voice processing did not reach.
        let reply = MeetingRecognitionAudio(source: .microphone, startFrame: 0,
                                            samples: noise(level: 0.00003, frames: 300) + noise(level: 0.0025, frames: 100))
        var echo = MeetingEchoReference()
        echo.record(chunk(level: 0, frames: 400))

        XCTAssertTrue(MeetingSpeechDetector().containsSpeech(in: reply, echo: echo))
    }

    func testTheCallHeardThroughTheSpeakersIsNotDecoded() {
        // The same -52 dBFS, but 36 dB under the call at the same moment.
        let echoed = MeetingRecognitionAudio(source: .microphone, startFrame: 0,
                                             samples: noise(level: 0.00003, frames: 300) + noise(level: 0.0025, frames: 100))
        var echo = MeetingEchoReference()
        echo.record(chunk(level: 0, frames: 300))
        echo.record(chunk(level: 0.16, frames: 100, startingAt: 300))

        XCTAssertEqual(echo.framesAboveEcho(in: echoed), 0)
        XCTAssertFalse(MeetingSpeechDetector().containsSpeech(in: echoed, echo: echo))
    }

    func testSteadyRoomNoiseIsNotDecoded() {
        // After the 03.11 call: minutes of flat -50 dBFS with the call silent.
        let hum = MeetingRecognitionAudio(source: .microphone, startFrame: 0, samples: noise(level: 0.003, frames: 400))

        XCTAssertFalse(MeetingSpeechDetector().containsSpeech(in: hum, echo: MeetingEchoReference()))
    }

    func testEchoLevelsAreReadAcrossChunkBoundaries() {
        var echo = MeetingEchoReference()
        echo.record(MeetingAudioChunk(source: .system, sequence: 0, startFrame: 0, sampleRate: 16_000,
                                      samples: [Float](repeating: 0.1, count: 500), isFinal: false))
        echo.record(MeetingAudioChunk(source: .system, sequence: 1, startFrame: 500, sampleRate: 16_000,
                                      samples: [Float](repeating: 0.1, count: 140), isFinal: false))

        XCTAssertEqual(echo.systemDecibels(at: 1), -20, accuracy: 0.01)
        XCTAssertEqual(echo.systemDecibels(at: 2), -120, accuracy: 0.01, "A frame the call never sent is silence")
    }

    // MARK: Words past the window

    func testWordsTimedAfterTheWindowEndAreDropped() {
        let transcript = timed([("Чтобы", 0.2, 0.6), ("туннели", 0.6, 1.2), ("Спасибо!", 29.0, 29.6)])

        let kept = transcript.droppingWords(startingAfter: 8)

        XCTAssertEqual(kept.text, "Чтобы туннели")
        XCTAssertEqual(kept.tokens.map(\.text), ["Чтобы", "туннели"])
    }

    func testAWindowWrittenEntirelyIntoThePaddingBecomesEmpty() {
        let transcript = timed([("Продолжение", 18.3, 19.7), ("следует...", 19.7, 21.1)])

        XCTAssertTrue(transcript.droppingWords(startingAfter: 8.2).isEmpty)
    }

    func testWordsInsideTheWindowAreKept() {
        let transcript = timed([("Ну", 0.1, 0.3), ("да.", 7.6, 8.4)])

        XCTAssertEqual(transcript.droppingWords(startingAfter: 8), transcript)
    }

    // MARK: Detached pieces

    func testDetachedHyphenAndApostropheJoinTheirWord() {
        let pairs = [
            ("И, по -моему, почти", "И, по-моему, почти"),
            ("из -за этого", "из-за этого"),
            ("пишем pull -request", "пишем pull-request"),
            ("до 27 -го года, 16 -24 недели", "до 27-го года, 16-24 недели"),
            ("бла -бла -бла", "бла-бла-бла"),
            ("с CloudFar 'ю и Opus 'а", "с CloudFar'ю и Opus'а"),
        ]
        for (raw, expected) in pairs {
            XCTAssertEqual(MeetingTextCleanup.joiningDetachedPieces(raw), expected, raw)
        }
    }

    func testDashesFlagsAndQuotesKeepTheirSpace() {
        for text in ["это - всё", "запусти ls -la там", "он сказал 'привет' всем", "минус -", "- начало"] {
            XCTAssertEqual(MeetingTextCleanup.joiningDetachedPieces(text), text)
        }
    }

    func testATurnNeverStartsOnASuffix() {
        XCTAssertTrue(SpeakerAttributedRowBuilder.continuesPreviousWord(" -то?"))
        XCTAssertTrue(SpeakerAttributedRowBuilder.continuesPreviousWord("'а"))
        XCTAssertFalse(SpeakerAttributedRowBuilder.continuesPreviousWord(" Ну"))
    }

    // MARK: Cleanup

    func testMeetingRowsGetDictationsSurfaceRepairsWithoutSentenceRules() {
        let row = meetingRow("тоді будь -яким способом", language: .ukrainian)

        let cleaned = MeetingTextCleanup().clean(row)

        XCTAssertEqual(cleaned.text, "тоді будь-яким способом", "No capital and no full stop on a fragment")
        XCTAssertEqual(cleaned.original.text, "тоді будь -яким способом", "The recognizer's words stay as evidence")
        XCTAssertEqual(cleaned.speakerID, row.speakerID)
    }

    func testVocabularyReplacesWordsOnlyAtTheCleanLevelAsInDictation() {
        let glossary = Glossary(entries: [GlossaryEntry(term: "Confluence", replacement: "конфліенції", language: .ukrainian)])
        let row = meetingRow("актуальними в конфліенції", language: .ukrainian)

        XCTAssertEqual(MeetingTextCleanup(glossary: glossary, level: .clean).clean(row).text, "актуальними в Confluence")
        XCTAssertEqual(MeetingTextCleanup(glossary: glossary, level: .conservative).clean(row).text,
                       "актуальними в конфліенції", "Conservative never changes a word")
    }

    // MARK: Meeting language

    func testPrevailingLanguageIsTheConfidentMajority() {
        let history: [SpeechLanguage] = [.ukrainian, .russian, .ukrainian, .ukrainian, .russian]

        XCTAssertEqual(LanguageDecision.prevailing(in: history, profile: .russianUkrainian), .ukrainian)
    }

    func testPrevailingTieGoesToTheNewest() {
        XCTAssertEqual(LanguageDecision.prevailing(in: [.ukrainian, .russian], profile: .russianUkrainian), .russian)
    }

    func testPrevailingIgnoresLanguagesOutsideTheProfile() {
        XCTAssertNil(LanguageDecision.prevailing(in: [.german, .german], profile: .russianUkrainian))
        XCTAssertNil(LanguageDecision.prevailing(in: [], profile: .russianUkrainian))
    }

    func testAnAmbiguousWindowStaysInTheMeetingsLanguageUnderTheWiderMargin() {
        // Ahead by 0.3: confident for a dictation, not enough to leave a meeting.
        let probabilities: [String: Float] = ["ru": 0.6, "uk": 0.3]

        XCTAssertEqual(LanguageDecision.choose(profile: .russianUkrainian, probabilities: probabilities,
                                               previous: .ukrainian).language, .russian)
        XCTAssertEqual(LanguageDecision.choose(profile: .russianUkrainian, probabilities: probabilities,
                                               previous: .ukrainian, margin: LanguageDecision.meetingMargin).language,
                       .ukrainian)
    }

    // MARK: Language distribution

    func testLanguageLogitsBecomeProbabilitiesOverEveryLanguage() {
        let distribution = LanguageDecision.distribution(fromLogits: [
            "uk": 2.0, "en": 1.0, "ru": 0.0, "pl": -Float.infinity,
        ])

        XCTAssertEqual(distribution.values.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertNil(distribution["pl"], "A token the filter suppressed gets no share")
        XCTAssertEqual(distribution["uk"] ?? 0, 0.665, accuracy: 0.001)
        XCTAssertEqual(distribution["en"] ?? 0, 0.245, accuracy: 0.001)
        XCTAssertEqual(distribution["ru"] ?? 0, 0.090, accuracy: 0.001)
    }

    func testNoUsableLogitsGiveNoDistribution() {
        XCTAssertTrue(LanguageDecision.distribution(fromLogits: [:]).isEmpty)
        XCTAssertTrue(LanguageDecision.distribution(fromLogits: ["uk": -Float.infinity, "ru": .nan]).isEmpty)
    }

    /// 05.11, a Ukrainian standup: WhisperKit's own detector reported only its
    /// pick, "en" at log-probability -1.3, and with one entry the window was
    /// confident English and came out translated. With the whole
    /// distribution the same pick is barely ahead of Ukrainian, and the
    /// meeting keeps its language.
    func testAWeakEnglishPickNoLongerTakesAUkrainianMeeting() {
        let profile = LanguageProfile(.russian, .german, .english, .ukrainian)
        let distribution = LanguageDecision.distribution(fromLogits: [
            "en": 1.0, "uk": 0.8, "ru": 0.1, "de": -1.0, "pl": -0.5,
        ])

        let decision = LanguageDecision.choose(profile: profile, probabilities: distribution,
                                               previous: .ukrainian, margin: LanguageDecision.meetingMargin)

        XCTAssertEqual(decision.language, .ukrainian)
        XCTAssertEqual(decision.reason, .continuedFromPrevious)
    }

    func testAClearPickStillLeavesTheMeetingsLanguage() {
        let profile = LanguageProfile(.russian, .german, .english, .ukrainian)
        let distribution = LanguageDecision.distribution(fromLogits: ["en": 4.0, "uk": 1.0, "ru": 0.5])

        let decision = LanguageDecision.choose(profile: profile, probabilities: distribution,
                                               previous: .ukrainian, margin: LanguageDecision.meetingMargin)

        XCTAssertEqual(decision.language, .english)
        XCTAssertEqual(decision.reason, .confident)
    }

    // MARK: Helpers

    private func attributions(_ speakers: [String], secondsEach: Double) -> [SpeakerWordAttribution] {
        let frames = Int64(secondsEach * 16_000)
        return speakers.enumerated().map { index, speaker in
            SpeakerWordAttribution(text: "w\(index)", startFrame: Int64(index) * frames,
                                   endFrame: Int64(index + 1) * frames, speakerID: speaker, confidence: 0.8)
        }
    }

    private func chunk(level: Float, frames: Int, startingAt frame: Int = 0) -> MeetingAudioChunk {
        MeetingAudioChunk(source: .system, sequence: UInt64(frame), startFrame: Int64(frame * 320), sampleRate: 16_000,
                          samples: noise(level: level, frames: frames), isFinal: false)
    }

    private func timed(_ words: [(String, Double, Double)]) -> Transcript {
        Transcript.assemble(words: words.map { Transcript.Word($0.0, start: $0.1, end: $0.2, confidence: 0.9) },
                            profile: .russianUkrainian, audioDuration: 30, processingDuration: 0, engineIdentifier: "test")
    }

    private func noise(level: Float, frames: Int) -> [Float] {
        (0..<(frames * 320)).map { $0.isMultiple(of: 2) ? level : -level }
    }

    private func meetingRow(_ text: String, language: SpeechLanguage) -> MeetingTranscriptRow {
        let transcript = Transcript(text: text, tokens: [], profile: .russianUkrainian, detectedLanguage: language,
                                    audioDuration: 2, processingDuration: 0, engineIdentifier: "test")
        return MeetingTranscriptRow(source: .system, startFrame: 0, endFrame: 32_000, text: text, original: transcript,
                                    speakerID: "speaker-1", speakerAssignmentSource: .diarization)
    }
}
