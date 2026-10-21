import XCTest
@testable import Witness

final class SpeakerDiarizationTests: XCTestCase {
    func testUnavailableServiceKeepsProductionFallbackEmpty() {
        var service = UnavailableSpeakerDiarizationService()
        XCTAssertTrue(service.ingest(chunk(samples: Array(repeating: 0.1, count: 8_000))).isEmpty)
        XCTAssertTrue(service.finish().isEmpty)
    }

    func testExperimentalDiarizerWorksStreamingAndOfflineWithoutPersistingAudio() {
        let first = tone(frequency: 120, count: 12_000)
        let second = tone(frequency: 330, count: 12_000)
        var streaming = ExperimentalLocalSpeakerDiarizer(frameCount: 12_000, newSpeakerDistance: 0.05)
        let firstTurns = streaming.ingest(chunk(samples: first))
        let secondTurns = streaming.ingest(chunk(samples: second, startFrame: 12_000, sequence: 1))
        XCTAssertEqual(firstTurns.map(\.speakerID), ["speaker-1"])
        XCTAssertEqual(secondTurns.map(\.speakerID), ["speaker-2"])
        XCTAssertTrue(streaming.finish().isEmpty)

        var offline = ExperimentalLocalSpeakerDiarizer(frameCount: 12_000, newSpeakerDistance: 0.05)
        let offlineTurns = offline.diarizeOffline(samples: first + second)
        XCTAssertEqual(offlineTurns.map(\.speakerID), ["speaker-1", "speaker-2"])
        XCTAssertTrue(offlineTurns.allSatisfy { (0...1).contains($0.confidence) })
    }

    func testSilenceDoesNotCreateSpeakerHypothesis() {
        var service = ExperimentalLocalSpeakerDiarizer(frameCount: 8_000)
        XCTAssertTrue(service.ingest(chunk(samples: Array(repeating: 0, count: 8_000))).isEmpty)
    }

    func testAlignmentKeepsExplicitSegmentAndWordConfidence() throws {
        let transcript = Transcript.assemble(
            words: [
                .init("hello", start: 0, end: 0.5, confidence: 0.9),
                .init("there", start: 0.5, end: 1, confidence: 0.8)
            ],
            profile: .english,
            audioDuration: 1,
            processingDuration: 0.1,
            engineIdentifier: "test"
        )
        let row = MeetingTranscriptRow(
            source: .system,
            startFrame: 16_000,
            endFrame: 32_000,
            text: transcript.text,
            original: transcript
        )
        let turns = [
            DiarizedSpeakerTurn(speakerID: "speaker-1", startFrame: 16_000, endFrame: 24_000, confidence: 0.8),
            DiarizedSpeakerTurn(speakerID: "speaker-2", startFrame: 24_000, endFrame: 32_000, confidence: 0.9)
        ]
        let alignment = try XCTUnwrap(SpeakerAttributionAligner().align(row: row, turns: turns))
        XCTAssertEqual(alignment.speakerID, "speaker-1") // deterministic tie break
        XCTAssertEqual(alignment.confidence, 0.4, accuracy: 0.0001)
        XCTAssertEqual(alignment.words.map(\.speakerID), ["speaker-1", "speaker-2"])
        XCTAssertEqual(alignment.words.map(\.confidence), [0.8, 0.9])

        let record = MeetingTranscriptRecord(row: row, alignment: alignment)
        XCTAssertEqual(record.originalSpeakerID, "speaker-1")
        XCTAssertEqual(record.speakerAssignmentSource, .diarization)
        XCTAssertEqual(record.wordAttributions.count, 2)
    }

    func testQualityGateRequiresEveryDifficultCorpusCategory() {
        let gate = DiarizationQualityGate(
            minimumRecordingsPerCategory: 2,
            minimumDurationPerCategory: 60,
            maximumSpeakerErrorRate: 0.2
        )
        let passing = DiarizationCorpusCategory.allCases.map {
            DiarizationCorpusMeasurement(category: $0, recordingCount: 2, scoredDuration: 60, speakerErrorDuration: 6)
        }
        XCTAssertTrue(gate.passes(passing))
        XCTAssertFalse(gate.passes(Array(passing.dropLast())))

        var failing = passing
        failing[2] = DiarizationCorpusMeasurement(
            category: .similarVoices,
            recordingCount: 2,
            scoredDuration: 60,
            speakerErrorDuration: 13
        )
        XCTAssertFalse(gate.passes(failing))

        var invalid = passing
        invalid[0] = DiarizationCorpusMeasurement(
            category: .overlaps,
            recordingCount: 2,
            scoredDuration: 60,
            speakerErrorDuration: -1
        )
        XCTAssertFalse(gate.passes(invalid))
    }

    private func chunk(samples: [Float], startFrame: Int64 = 0, sequence: UInt64 = 0) -> MeetingAudioChunk {
        MeetingAudioChunk(
            source: .system,
            sequence: sequence,
            startFrame: startFrame,
            sampleRate: AudioTargetFormat.sampleRate,
            samples: samples,
            isFinal: false
        )
    }

    private func tone(frequency: Double, count: Int) -> [Float] {
        (0..<count).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / AudioTargetFormat.sampleRate) * 0.2)
        }
    }
}
