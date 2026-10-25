import XCTest
@testable import Witness

final class SpeakerLabelPolicyTests: XCTestCase {
    private func turn(_ speaker: String, _ start: Double, _ end: Double, _ confidence: Double = 0.7) -> DiarizedSpeakerTurn {
        DiarizedSpeakerTurn(speakerID: speaker, startFrame: Int64(start * 16_000), endFrame: Int64(end * 16_000), confidence: confidence)
    }

    private let policy = SpeakerLabelPolicy.standard

    func testOneWordFlickersInsideALongTurnDisappear() {
        // The shape of the first real file: a long run with single words handed to another speaker.
        let raw = [turn("speaker-1", 0, 10), turn("speaker-2", 10, 10.4), turn("speaker-1", 10.4, 20),
                   turn("speaker-3", 20, 20.2), turn("speaker-1", 20.2, 30), turn("speaker-2", 30, 60), turn("speaker-1", 60, 70)]

        let refined = policy.refine(raw, finished: false)

        XCTAssertEqual(refined.turns.map(\.speakerID), ["speaker-1", "speaker-2", "speaker-1"])
        XCTAssertEqual(refined.turns.first?.startFrame, 0)
        XCTAssertEqual(refined.turns.last?.endFrame, 70 * 16_000)
        XCTAssertTrue(refined.isReliable)
    }

    func testTurnsOfOneSpeakerAreJoinedAcrossAShortGapButNotALongOne() {
        let near = policy.refine([turn("a", 0, 10), turn("a", 10.5, 20), turn("b", 20, 40)], finished: false)
        XCTAssertEqual(near.turns.count, 2)
        let far = policy.refine([turn("a", 0, 10), turn("b", 10, 30), turn("a", 30, 40)], finished: false)
        XCTAssertEqual(far.turns.map(\.speakerID), ["a", "b", "a"], "a real change of speaker is kept")
    }

    func testASpeakerWhoBarelySpeaksIsNotAParticipant() {
        let raw = [turn("a", 0, 100), turn("b", 100, 190), turn("c", 190, 196), turn("a", 196, 290), turn("b", 290, 380)]
        let refined = policy.refine(raw, finished: false)
        XCTAssertFalse(refined.turns.contains { $0.speakerID == "c" })
    }

    func testAFinishedRecordingDominatedByOneVoiceGetsNoLabels() {
        // 94% on one speaker, as in the first real file.
        let raw = [turn("speaker-1", 0, 940, 0.5), turn("speaker-2", 940, 1000, 0.5)]
        let refined = policy.refine(raw, finished: true)
        XCTAssertEqual(refined.doubt, .oneVoiceDominates)
        XCTAssertTrue(refined.turns.isEmpty)
        XCTAssertTrue(policy.refine(raw, finished: false).isReliable, "a live call only smooths: its first minutes prove nothing")
    }

    func testAFinishedRecordingWhoseModelIsUnsureGetsNoLabels() {
        let raw = [turn("a", 0, 100, 0.2), turn("b", 100, 200, 0.25), turn("a", 200, 300, 0.2)]
        XCTAssertEqual(policy.refine(raw, finished: true).doubt, .lowConfidence)
    }

    func testAPlausibleConversationKeepsItsLabels() {
        let raw = [turn("a", 0, 60, 0.7), turn("b", 60, 120, 0.65), turn("a", 120, 200, 0.7), turn("b", 200, 260, 0.6)]
        let refined = policy.refine(raw, finished: true)
        XCTAssertTrue(refined.isReliable)
        XCTAssertEqual(refined.turns.map(\.speakerID), ["a", "b", "a", "b"])
    }

    func testTheRefinedTurnsTileWithoutOverlapAndTerminateOnNoise() {
        // 400 random alternations: must finish, stay ordered and non-overlapping.
        var generator = SystemRandomNumberGenerator()
        var raw: [DiarizedSpeakerTurn] = []
        var cursor = 0.0
        for _ in 0..<400 {
            let length = Double.random(in: 0.2...4, using: &generator)
            raw.append(turn(["a", "b", "c", "d"].randomElement(using: &generator)!, cursor, cursor + length, Double.random(in: 0.1...0.9, using: &generator)))
            cursor += length
        }
        let refined = policy.refine(raw, finished: false)
        XCTAssertFalse(refined.turns.isEmpty)
        for (previous, next) in zip(refined.turns, refined.turns.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.endFrame, next.startFrame)
            XCTAssertNotEqual(previous.speakerID, next.speakerID)
        }
        XCTAssertLessThan(refined.turns.count, raw.count / 2)
        XCTAssertTrue(refined.turns.allSatisfy { $0.endFrame - $0.startFrame >= 3 * 16_000 }, "no turn shorter than the minimum survives")
    }

    func testNothingInNothingOut() {
        XCTAssertTrue(policy.refine([], finished: false).turns.isEmpty)
        XCTAssertEqual(policy.refine([], finished: true).doubt, .oneVoiceDominates)
    }
}

final class SentenceRowSplitterTests: XCTestCase {
    /// "Eins zwei. Drei vier fuenf. Sechs sieben. Acht neun." as word tokens, one per second.
    private func row(_ text: String, seconds: Double, modified: Bool = false) -> MeetingTranscriptRow {
        var tokens: [TranscriptToken] = []
        var offset = 0
        for (index, word) in text.split(separator: " ").enumerated() {
            tokens.append(TranscriptToken(text: String(word), range: offset..<(offset + word.count),
                                          start: Double(index), end: Double(index) + 0.9, confidence: 0.9))
            offset += word.count + 1
        }
        let transcript = Transcript(text: text, tokens: tokens, profile: .english, detectedLanguage: .english,
                                    audioDuration: seconds, processingDuration: 0, engineIdentifier: "fake")
        return MeetingTranscriptRow(source: .system, startFrame: 160_000, endFrame: 160_000 + Int64(seconds * 16_000),
                                    text: modified ? text + " extra" : text, original: transcript)
    }

    func testALongWindowIsCutAtSentenceEndsWithTheWordsOwnTimes() {
        let text = "Eins zwei drei vier. Fuenf sechs sieben acht. Neun zehn elf zwölf."
        let parts = SentenceRowSplitter().split(row(text, seconds: 12))

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.map(\.text).joined(separator: " "), text)
        XCTAssertEqual(parts.first?.startFrame, 160_000)
        XCTAssertEqual(parts.last?.endFrame, 160_000 + 12 * 16_000)
        for (previous, next) in zip(parts, parts.dropFirst()) { XCTAssertLessThanOrEqual(previous.endFrame, next.startFrame) }
        XCTAssertTrue(parts.allSatisfy { $0.rawSlice == $0.text }, "a part must not claim the whole window as its recognized text")
    }

    func testShortRowsAndRowsWhoseTextWasEditedAreLeftAlone() {
        let splitter = SentenceRowSplitter()
        XCTAssertEqual(splitter.split(row("Eins zwei drei.", seconds: 3)).count, 1)
        XCTAssertEqual(splitter.split(row("Eins zwei. Drei vier. Fuenf sechs. Sieben acht. Neun zehn.", seconds: 12, modified: true)).count, 1)
    }

    func testASplitRowStoresItsOwnRecognizedSliceInTheRecord() {
        let parts = SentenceRowSplitter().split(row("Eins zwei drei vier. Fuenf sechs sieben acht. Neun zehn elf zwölf.", seconds: 12))
        let record = MeetingTranscriptRecord(row: parts[1])
        XCTAssertEqual(record.rawText, parts[1].text)
        XCTAssertNotEqual(record.rawText, parts[1].original.text)
    }
}

final class ActiveSpeakerSignalTests: XCTestCase {
    func testLabelsThatNameASpeakerAreParsedAndOthersAreNot() {
        XCTAssertEqual(ActiveSpeakerNameParser.name(in: "Talking: Anna Becker,"), "Anna Becker")
        XCTAssertEqual(ActiveSpeakerNameParser.name(in: "Active speaker: Sasha"), "Sasha")
        XCTAssertEqual(ActiveSpeakerNameParser.name(in: "Herr Krüger spricht"), "Herr Krüger")
        XCTAssertEqual(ActiveSpeakerNameParser.name(in: "Говорит: Женя"), "Женя")
        XCTAssertEqual(ActiveSpeakerNameParser.name(in: "Maria is speaking"), "Maria")
        XCTAssertNil(ActiveSpeakerNameParser.name(in: "Mute"))
        XCTAssertNil(ActiveSpeakerNameParser.name(in: "Talking: "))
        XCTAssertNil(ActiveSpeakerNameParser.name(in: "Talking: 12345"))
        XCTAssertNil(ActiveSpeakerNameParser.name(in: String(repeating: "x", count: 200)))
    }

    func testARowTakesTheNameShownForMostOfItAndSilenceVotesForNobody() {
        var timeline = ActiveSpeakerTimeline()
        for second in 0..<20 {
            let name: String? = second < 12 ? "Anna" : (second < 14 ? nil : "Boris")
            timeline.record(ActiveSpeakerSample(frame: Int64(second) * 16_000, name: name))
        }
        XCTAssertEqual(timeline.name(from: 0, to: 12 * 16_000), "Anna")
        XCTAssertEqual(timeline.name(from: 14 * 16_000, to: 19 * 16_000), "Boris")
        XCTAssertNil(timeline.name(from: 12 * 16_000, to: 14 * 16_000), "nobody highlighted")
        XCTAssertNil(timeline.name(from: 8 * 16_000, to: 17 * 16_000), "two names in one row are not resolved by a guess")
        XCTAssertFalse(timeline.isEmpty)
        XCTAssertTrue(ActiveSpeakerTimeline().isEmpty)
    }

    func testTheRosterKeepsOneIDPerPersonAndEightAtMost() {
        var roster = ActiveSpeakerRoster()
        XCTAssertEqual(roster.speakerID(for: "Anna"), "speaker-1")
        XCTAssertEqual(roster.speakerID(for: "Boris"), "speaker-2")
        XCTAssertEqual(roster.speakerID(for: "anna"), "speaker-1")
        for index in 3...8 { _ = roster.speakerID(for: "P\(index)") }
        XCTAssertNil(roster.speakerID(for: "Ninth"))
        XCTAssertEqual(roster.displayNames["speaker-1"], "Anna")
        XCTAssertEqual(roster.displayNames.count, 8)
    }

    func testAgreementIsOneWhenEachAcousticSpeakerIsOnePersonAndLowerWhenSplit() {
        func row(_ speaker: String, _ start: Int, _ end: Int) -> MeetingTranscriptRow {
            let transcript = Transcript(text: "x", tokens: [], profile: .english, detectedLanguage: .english,
                                        audioDuration: 1, processingDuration: 0, engineIdentifier: "fake")
            return MeetingTranscriptRow(source: .system, startFrame: Int64(start) * 16_000, endFrame: Int64(end) * 16_000,
                                        text: "x", original: transcript, speakerID: speaker)
        }
        let named = [row("speaker-1", 0, 60), row("speaker-2", 60, 120)]
        XCTAssertEqual(SpeakerAgreement.purity(acoustic: [row("speaker-1", 0, 60), row("speaker-2", 60, 120)], named: named) ?? 0, 1, accuracy: 0.001)
        // One acoustic voice covering both people: half of its time is wrong.
        XCTAssertEqual(SpeakerAgreement.purity(acoustic: [row("speaker-1", 0, 120)], named: named) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(SpeakerAgreement.purity(acoustic: [row("speaker-1", 0, 10)], named: []))
    }
}
