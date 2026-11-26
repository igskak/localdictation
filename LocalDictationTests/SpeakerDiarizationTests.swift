import AVFoundation
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

    func testUncoveredWordDoesNotHideTheHandoff() {
        let row = systemRow([
            ("First", 0, 0.4), ("voice", 0.4, 0.8), ("is", 0.8, 1.2), ("done.", 1.2, 1.6),
            ("Between.", 1.7, 1.9),
            ("Second", 2, 2.4), ("voice", 2.4, 2.8), ("answers", 2.8, 3.2), ("now.", 3.2, 3.6)
        ])
        let turns = [
            turn("speaker-1", from: 0, to: 1.6, confidence: 0.9),
            turn("speaker-2", from: 2, to: 3.6, confidence: 0.8)
        ]

        let rows = SpeakerAttributedRowBuilder().rows(from: row, turns: turns)

        XCTAssertEqual(rows.map(\.speakerID), ["speaker-1", "others", "speaker-2"])
        XCTAssertEqual(rows.map(\.speakerAssignmentSource), [.diarization, .sourceFallback, .diarization])
        XCTAssertEqual(rows.map(\.startFrame), [0, 27_200, 32_000])
        XCTAssertEqual(rows.map(\.text).joined(separator: " "), row.text)
        XCTAssertEqual(rows.map { MeetingTranscriptRecord(row: $0).rawText }, rows.map(\.text))
        XCTAssertEqual(rows[2].replacingText("Second voice answers now").rawSlice, rows[2].text)
    }

    func testWeakCoverageNeverBecomesANumberedSpeaker() {
        let row = systemRow([("First", 0, 1), ("voice.", 1, 2)])
        let rows = SpeakerAttributedRowBuilder().rows(from: row, turns: [
            turn("speaker-1", from: 0, to: 0.35, confidence: 0.9),
            turn("speaker-1", from: 1, to: 1.35, confidence: 0.9)
        ])

        XCTAssertEqual(rows.map(\.speakerID), ["others"])
        XCTAssertEqual(rows[0].text, row.text)
        XCTAssertNil(rows[0].speakerConfidence)
    }

    func testCompetingSlotsWithSimilarSupportLeaveSpeakerUnassigned() {
        let row = systemRow([("Who", 0, 0.8), ("spoke?", 0.8, 1.6)])
        let rows = SpeakerAttributedRowBuilder().rows(from: row, turns: [
            turn("speaker-1", from: 0, to: 1.6, confidence: 0.87),
            turn("speaker-2", from: 0, to: 1.6, confidence: 0.81)
        ])

        XCTAssertEqual(rows.map(\.speakerID), ["others"])
        XCTAssertEqual(rows[0].text, row.text)
    }

    func testStrongShortReplyAfterAPauseSurvives() {
        let row = systemRow([
            ("We", 0, 0.4), ("are", 0.4, 0.8), ("all", 0.8, 1.2), ("done.", 1.2, 1.6),
            ("Thanks.", 2.1, 2.5)
        ])
        let rows = SpeakerAttributedRowBuilder().rows(from: row, turns: [
            turn("speaker-1", from: 0, to: 1.6, confidence: 0.9),
            turn("speaker-2", from: 2.1, to: 2.5, confidence: 0.85)
        ])

        XCTAssertEqual(rows.map(\.speakerID), ["speaker-1", "speaker-2"])
        XCTAssertEqual(rows.map(\.text), ["We are all done.", "Thanks."])
    }

    func testStrongShortReplyWithoutAPauseSurvives() {
        let row = systemRow([
            ("Is", 0, 0.4), ("that", 0.4, 0.8), ("all", 0.8, 1.2), ("clear?", 1.2, 1.6),
            ("Thanks.", 1.65, 2.05)
        ])
        let rows = SpeakerAttributedRowBuilder().rows(from: row, turns: [
            turn("speaker-1", from: 0, to: 1.6, confidence: 0.9),
            turn("speaker-2", from: 1.65, to: 2.05, confidence: 0.96)
        ])

        XCTAssertEqual(rows.map(\.speakerID), ["speaker-1", "speaker-2"])
        XCTAssertEqual(rows.map(\.text), ["Is that all clear?", "Thanks."])
    }

    func testLateTurnsReviseAnExistingWindowAndKeepMicrophoneInOrder() {
        let system = systemRow([
            ("First", 0, 0.45), ("person", 0.45, 0.90), ("is", 0.90, 1.35), ("done.", 1.35, 1.8),
            ("Second", 2, 2.45), ("person", 2.45, 2.90), ("can", 2.90, 3.35), ("start.", 3.35, 3.8)
        ])
        let microphone = MeetingTranscriptRow(
            source: .microphone, startFrame: 30_000, endFrame: 31_000,
            text: "You speak", original: system.original
        )
        var timeline = LiveMeetingSpeakerTimeline(cleanup: MeetingTextCleanup())
        timeline.updateTranscript([system])
        timeline.apply(SpeakerTimelineUpdate(turns: [turn("speaker-1", from: 0, to: 1.8, confidence: 0.9)]))
        timeline.updateTranscript([system, microphone])
        timeline.apply(SpeakerTimelineUpdate(turns: [turn("speaker-2", from: 2, to: 3.8, confidence: 0.9)]))

        XCTAssertEqual(timeline.rows.map(\.speakerID), ["speaker-1", "you", "speaker-2"])
        XCTAssertEqual(timeline.rows.filter { $0.source == .system }.map(\.text).joined(separator: " "), system.text)
        timeline.apply(SpeakerTimelineUpdate(turns: [], replacing: 32_000..<60_800))
        XCTAssertEqual(timeline.rows.map(\.speakerID), ["speaker-1", "you", "others"])
    }

    func testSpeakerReviewKeepsTheNumberWhenModelClustersChangeOrder() throws {
        let first = MeetingRecognitionAudio(source: .system, startFrame: 0, samples: Array(repeating: 0, count: 80_000))
        let second = MeetingRecognitionAudio(source: .system, startFrame: 16_000, samples: Array(repeating: 0, count: 112_000))
        var identities = MeetingSpeakerIdentityTracker()
        let original = try XCTUnwrap(identities.update(MeetingSpeakerReview(
            turns: [turn("x", from: 0, to: 2, confidence: 0.9), turn("y", from: 2, to: 5, confidence: 0.9)],
            embeddings: ["x": [1, 0], "y": [0, 1]]
        ), window: first))
        let match = try XCTUnwrap(identities.update(MeetingSpeakerReview(
            turns: [turn("y", from: 1, to: 2, confidence: 0.9), turn("x", from: 2, to: 8, confidence: 0.9)],
            embeddings: ["x": [0, 1], "y": [1, 0]]
        ), window: second))

        XCTAssertNotEqual(original.turns.first?.speakerID, original.turns.last?.speakerID)
        let secondVoice = match.turns.first { $0.endFrame == 128_000 }
        XCTAssertEqual(secondVoice?.speakerID, original.turns.last?.speakerID)
        XCTAssertEqual(match.replacing?.upperBound, 128_000)
    }

    func testReviewBufferLimitsSamplesAndKeepsTheTimelineAcrossShortGaps() throws {
        var buffer = MeetingSpeakerReviewBuffer()
        buffer.append(chunk(samples: Array(repeating: 1, count: 32_000)))
        buffer.append(chunk(samples: Array(repeating: 1, count: 48_000), startFrame: 48_000))
        let tail = try XCTUnwrap(buffer.takeWindow(final: true))
        XCTAssertEqual(tail.samples[32_000], 0)
        XCTAssertEqual(tail.endFrame, 96_000)
        XCTAssertNil(buffer.takeWindow(final: true))

        buffer.append(chunk(samples: Array(repeating: 1, count: 40 * 16_000), startFrame: 96_000))
        let bounded = try XCTUnwrap(buffer.takeWindow())
        XCTAssertEqual(bounded.samples.count, 32 * 16_000)
        XCTAssertEqual(bounded.endFrame, 736_000)
    }

    private func systemRow(_ words: [(String, Double, Double)]) -> MeetingTranscriptRow {
        let duration = words.last?.2 ?? 0
        let transcript = Transcript.assemble(
            words: words.map { .init($0.0, start: $0.1, end: $0.2, confidence: 0.95) },
            profile: .english, audioDuration: duration, processingDuration: 0, engineIdentifier: "test"
        )
        return MeetingTranscriptRow(
            source: .system, startFrame: 0, endFrame: Int64((duration * 16_000).rounded()),
            text: transcript.text, original: transcript
        )
    }

    private func turn(_ speaker: String, from start: Double, to end: Double, confidence: Double) -> DiarizedSpeakerTurn {
        DiarizedSpeakerTurn(
            speakerID: speaker,
            startFrame: Int64((start * 16_000).rounded()),
            endFrame: Int64((end * 16_000).rounded()),
            confidence: confidence
        )
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

extension SpeakerDiarizationTests {
    func testLocalAMIEngineComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["WITNESS_SPEAKER_BENCHMARK_DIR"],
              let nemotronPath = environment["WITNESS_NEMOTRON3_TEST_MODEL_DIR"] else {
            throw XCTSkip("Requires the local public AMI benchmark fixtures")
        }
        let directory = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let file = try AVAudioFile(forReading: directory.appendingPathComponent("EN2002c.wav"))
        let community = BundledCommunitySpeakerReview(directory: directory.appendingPathComponent("community-models"))
        try await community.prepare()
        let nemotron = BundledNemotronSpeakerDiarizer(modelDirectory:
            URL(fileURLWithPath: nemotronPath))
        try await nemotron.prepare()
        var output: [[String: Any]] = []
        for time in [30, 300, 528, 720, 800, 1008, 1104, 1200, 1500, 2200, 2448, 2832] {
            let start = Int64(time * 16_000)
            file.framePosition = start
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48 * 16_000))
            try file.read(into: pcm)
            let values = Array(UnsafeBufferPointer(start: pcm.floatChannelData?[0], count: Int(pcm.frameLength)))
            func serialized(_ turns: [DiarizedSpeakerTurn]) -> [[String: Any]] {
                turns.map { ["speaker": $0.speakerID, "start": $0.startFrame, "end": $0.endFrame, "quality": $0.confidence] }
            }
            var turns: [DiarizedSpeakerTurn] = []
            let timeA = ProcessInfo.processInfo.systemUptime
            for offset in stride(from: 0, to: values.count, by: 16_000) {
                let chunk = MeetingAudioChunk(source: .system, sequence: UInt64(offset / 16_000),
                    startFrame: start + Int64(offset), sampleRate: 16_000,
                    samples: Array(values[offset..<min(offset + 16_000, values.count)]), isFinal: false)
                turns += try await nemotron.ingest(chunk)
            }
            turns += try await nemotron.finish()
            let timeB = ProcessInfo.processInfo.systemUptime
            let review = try await community.review(.init(source: .system, startFrame: start, samples: values))
            let timeC = ProcessInfo.processInfo.systemUptime
            var rollingBuffer = MeetingSpeakerReviewBuffer()
            var identities = MeetingSpeakerIdentityTracker()
            var rolling: [DiarizedSpeakerTurn] = []
            func revise(_ snapshot: MeetingRecognitionAudio) async throws {
                let result = try await community.review(snapshot)
                if let update = identities.update(result, window: snapshot), let replacement = update.replacing {
                    rolling = rolling.flatMap { $0.subtracting(replacement) } + update.turns
                }
            }
            for offset in stride(from: 0, to: values.count, by: 16_000) {
                rollingBuffer.append(.init(source: .system, sequence: UInt64(offset / 16_000),
                    startFrame: start + Int64(offset), sampleRate: 16_000,
                    samples: Array(values[offset..<min(offset + 16_000, values.count)]), isFinal: false))
                if let snapshot = rollingBuffer.takeWindow() { try await revise(snapshot) }
            }
            if let snapshot = rollingBuffer.takeWindow(final: true) { try await revise(snapshot) }
            output.append(["start": start, "end": start + Int64(values.count),
                "stream": serialized(turns), "review": serialized(review.turns), "rolling": serialized(rolling),
                "stream_seconds": timeB - timeA, "review_seconds": timeC - timeB,
                "rolling_seconds": ProcessInfo.processInfo.systemUptime - timeC])
        }
        try JSONSerialization.data(withJSONObject: output).write(to: directory.appendingPathComponent("result.json"))
    }
}
