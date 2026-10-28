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

    // MARK: Helpers

    private func attributions(_ speakers: [String], secondsEach: Double) -> [SpeakerWordAttribution] {
        let frames = Int64(secondsEach * 16_000)
        return speakers.enumerated().map { index, speaker in
            SpeakerWordAttribution(text: "w\(index)", startFrame: Int64(index) * frames,
                                   endFrame: Int64(index + 1) * frames, speakerID: speaker, confidence: 0.8)
        }
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
