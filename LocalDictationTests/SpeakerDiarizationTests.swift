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

    func testNemotronProbabilitySegmenterPreservesOverlappingSpeakersAndConfidence() {
        let speakerCount = 2
        let frameCount = 10
        var probabilities = [Float](repeating: 0.05, count: frameCount * speakerCount)
        for frame in 0..<6 { probabilities[frame * speakerCount] = 0.8 }
        for frame in 3..<10 { probabilities[frame * speakerCount + 1] = 0.7 }

        let turns = NemotronProbabilitySegmenter(minimumFrames: 2).turns(
            probabilities: probabilities,
            frameCount: frameCount,
            speakerCount: speakerCount,
            startFrame: 16_000
        )

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speakerID, "speaker-1")
        XCTAssertEqual(turns[0].startFrame, 16_000)
        XCTAssertEqual(turns[0].endFrame, 16_960)
        XCTAssertEqual(turns[0].confidence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(turns[1].speakerID, "speaker-2")
        XCTAssertEqual(turns[1].startFrame, 16_480)
        XCTAssertEqual(turns[1].endFrame, 17_600)
        XCTAssertEqual(turns[1].confidence, 0.7, accuracy: 0.0001)
    }

    func testAttributedRowBuilderSplitsSpeakerRunsWithoutRewritingWords() {
        let transcript = Transcript.assemble(
            words: [
                // Each run lasts at least `minimumTurnFrames`, so both are turns.
                .init("hello", start: 0, end: 1.6, confidence: 0.9),
                .init("there", start: 1.6, end: 2.0, confidence: 0.9),
                .init("friend", start: 2.0, end: 3.6, confidence: 0.9)
            ],
            profile: .english,
            audioDuration: 3.6,
            processingDuration: 0.1,
            engineIdentifier: "test"
        )
        let row = MeetingTranscriptRow(
            source: .system,
            startFrame: 0,
            endFrame: 57_600,
            text: transcript.text,
            original: transcript
        )
        let turns = [
            DiarizedSpeakerTurn(speakerID: "speaker-1", startFrame: 0, endFrame: 25_600, confidence: 0.9),
            DiarizedSpeakerTurn(speakerID: "speaker-2", startFrame: 25_600, endFrame: 57_600, confidence: 0.8)
        ]

        let rows = SpeakerAttributedRowBuilder().rows(from: row, turns: turns)

        XCTAssertEqual(rows.map(\.speakerID), ["speaker-1", "speaker-2"])
        XCTAssertEqual(rows.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(rows.map(\.text).joined(separator: " "), transcript.text)
        XCTAssertEqual(rows.flatMap(\.wordAttributions).map(\.text), ["hello", "there", "friend"])
        XCTAssertTrue(rows.allSatisfy { $0.speakerAssignmentSource == .diarization })
    }

    #if NOTETAKER_DIARIZATION
    func testPinnedNemotronModelLoadsAndRunsFromAnExplicitLocalDirectory() async throws {
        guard let path = ProcessInfo.processInfo.environment["WITNESS_NEMOTRON3_TEST_MODEL_DIR"] else {
            throw XCTSkip("Set WITNESS_NEMOTRON3_TEST_MODEL_DIR for the local model smoke test")
        }
        let service = BundledNemotronSpeakerDiarizer(
            modelDirectory: URL(fileURLWithPath: path, isDirectory: true)
        )
        try await service.prepare()
        let sampleCount = Int(AudioTargetFormat.sampleRate * 12)
        _ = try await service.ingest(chunk(samples: Array(repeating: 0, count: sampleCount)))
        _ = try await service.finish()

        let metrics = await service.metricsSnapshot()
        XCTAssertGreaterThan(metrics.modelLoadSeconds, 0)
        XCTAssertGreaterThan(metrics.inferenceSeconds, 0)
        XCTAssertEqual(metrics.processedAudioSeconds, 12, accuracy: 0.001)
    }
    #endif

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

final class SpeakerSlotProbabilityDigestTests: XCTestCase {
    func testCountsFramesAtEachLevelAndWhichSlotLeads() {
        var digest = SpeakerSlotProbabilityDigest()
        // Row-major: frame * speakerCount + speaker.
        digest.add(
            probabilities: [0.9, 0.1, 0.6, 0.35, 0.1, 0.45, 0.05, 0.1],
            frameCount: 4, speakerCount: 2, startFrame: 32_000, samplesPerProbabilityFrame: 160
        )

        XCTAssertEqual(digest.frames, 4)
        XCTAssertEqual(digest.slots[0].peak, 0.9, accuracy: 0.0001)
        XCTAssertEqual(digest.slots[0].framesAtOrAbove50, 2)
        XCTAssertEqual(digest.slots[0].framesLeading, 2)
        XCTAssertEqual(digest.slots[1].peak, 0.45, accuracy: 0.0001)
        XCTAssertEqual(digest.slots[1].framesAtOrAbove50, 0)
        XCTAssertEqual(digest.slots[1].framesAtOrAbove30, 2)
        XCTAssertEqual(digest.slots[1].framesAtOrAbove20, 2)
        // The last frame peaks at 0.1, below the 0.2 floor, so nobody leads it.
        XCTAssertEqual(digest.slots[1].framesLeading, 1)
    }

    func testSecondVoiceUnderTheTurnThresholdIsVisibleInTheSummary() {
        var digest = SpeakerSlotProbabilityDigest()
        digest.add(
            probabilities: [0.9, 0.1, 0.6, 0.35, 0.1, 0.45, 0.05, 0.1],
            frameCount: 4, speakerCount: 2, startFrame: 32_000, samplesPerProbabilityFrame: 160
        )

        let summary = digest.summary()
        XCTAssertTrue(summary.hasPrefix("2.0-2.0 s, 4 frames"), summary)
        XCTAssertTrue(summary.contains("slot 2 peak 0.45"), summary)
        XCTAssertTrue(summary.contains(">=0.5:0 >=0.3:2"), summary)
    }

    func testAccumulatesAcrossChunksAndResets() {
        var digest = SpeakerSlotProbabilityDigest()
        digest.add(probabilities: [0.2, 0.8], frameCount: 1, speakerCount: 2, startFrame: 0, samplesPerProbabilityFrame: 160)
        digest.add(probabilities: [0.7, 0.3], frameCount: 1, speakerCount: 2, startFrame: 160, samplesPerProbabilityFrame: 160)

        XCTAssertEqual(digest.frames, 2)
        XCTAssertEqual(digest.slots[0].framesAtOrAbove50, 1)
        XCTAssertEqual(digest.slots[1].framesAtOrAbove50, 1)
        XCTAssertEqual(digest.endFrame, 320)

        digest.reset()
        XCTAssertTrue(digest.isEmpty)
        XCTAssertEqual(digest.summary(), "no frames")
    }

    func testShortProbabilityBufferIsIgnoredRatherThanTrapping() {
        var digest = SpeakerSlotProbabilityDigest()
        digest.add(probabilities: [0.9], frameCount: 4, speakerCount: 2, startFrame: 0, samplesPerProbabilityFrame: 160)

        XCTAssertTrue(digest.isEmpty)
    }
}
