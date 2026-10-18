import XCTest
@testable import Witness

final class LongFormTranscriberTests: XCTestCase {
    func testWindowBoundariesOverlapAndFinalTail() throws {
        var builder = MeetingWindowBuilder(source: .microphone, windowFrames: 6, overlapFrames: 2)
        XCTAssertEqual(try builder.append(chunk(start: 0, values: [0, 1, 2])).count, 0)
        let first = try builder.append(chunk(start: 3, values: [3, 4, 5]))
        XCTAssertEqual(first.first?.samples, [0, 1, 2, 3, 4, 5])
        let second = try builder.append(chunk(start: 6, values: [6, 7, 8, 9]))
        XCTAssertEqual(second.first?.samples, [4, 5, 6, 7, 8, 9])
        XCTAssertNil(builder.finish())
    }

    func testAudioGapIsReportedBeforeAnyDataIsAccepted() throws {
        var builder = MeetingWindowBuilder(source: .microphone, windowFrames: 10, overlapFrames: 2)
        _ = try builder.append(chunk(start: 0, values: [1, 2]))
        XCTAssertThrowsError(try builder.append(chunk(start: 9, values: [3]))) {
            XCTAssertEqual($0 as? LongFormTranscriptionError, .missingAudio)
        }
        XCTAssertEqual(builder.finish()?.samples, [1, 2])
    }

    func testBoundedQueueAndFairSourceOrder() async throws {
        let engine = FakeTranscriptionService()
        engine.setResult(Transcript(text: "hello", tokens: [], profile: .english, detectedLanguage: .english,
                                    audioDuration: 1, processingDuration: 0, engineIdentifier: "fake"))
        let service = LongFormTranscriber(engine: engine, profile: .english, capacity: 3)
        try await service.enqueue(MeetingRecognitionAudio(source: .microphone, startFrame: 0, samples: [1]))
        try await service.enqueue(MeetingRecognitionAudio(source: .microphone, startFrame: 10, samples: [2]))
        try await service.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 1, samples: [3]))
        do {
            try await service.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 2, samples: [4]))
            XCTFail("full queue must reject input")
        } catch { XCTAssertEqual(error as? LongFormTranscriptionError, .backlogFull) }
        let first = try await service.drainOne()
        let second = try await service.drainOne()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        let rows = await service.assembler.rows
        XCTAssertEqual(rows.map(\.source), [.microphone, .system])
        let remaining = await service.queuedCount()
        XCTAssertEqual(remaining, 1)
    }

    func testModelFailureKeepsWindowAvailableForRecovery() async throws {
        let engine = FakeTranscriptionService()
        engine.setModelState(.unavailable("test", needsUserAction: true))
        let service = LongFormTranscriber(engine: engine, profile: .english)
        try await service.enqueue(MeetingRecognitionAudio(source: .system, startFrame: 0, samples: [1]))
        do { _ = try await service.drainOne(); XCTFail("must refuse an unready model") }
        catch { XCTAssertEqual(error as? LongFormTranscriptionError, .modelNotReady) }
        let remaining = await service.queuedCount()
        XCTAssertEqual(remaining, 1)
    }

    private func chunk(start: Int64, values: [Float]) -> MeetingAudioChunk {
        MeetingAudioChunk(source: .microphone, sequence: 0, startFrame: start, sampleRate: 16_000, samples: values, isFinal: false)
    }
}
