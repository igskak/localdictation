import XCTest
@testable import Witness

final class BoundedPCMBufferTests: XCTestCase {
    func testAppendWithinCapacityKeepsEverySample() {
        let buffer = BoundedPCMBuffer(capacityFrames: 10)
        let result = buffer.append([0.1, -0.2, 0.3])

        XCTAssertEqual(result, BoundedPCMBuffer.AppendResult(acceptedFrames: 3, droppedFrames: 0))
        XCTAssertEqual(buffer.frameCount, 3)
        XCTAssertEqual(buffer.droppedFrameCount, 0)
        XCTAssertEqual(buffer.makeSamples(), [0.1, -0.2, 0.3])
    }

    func testPeakLevelTracksAbsoluteMaximum() {
        let buffer = BoundedPCMBuffer(capacityFrames: 8)
        buffer.append([0.2, -0.7, 0.5])
        XCTAssertEqual(buffer.peakLevel, 0.7, accuracy: 0.0001)

        buffer.append([0.1])
        XCTAssertEqual(buffer.peakLevel, 0.7, accuracy: 0.0001, "Peak must not decay inside one utterance")
    }

    func testOverflowIsCountedAndBufferStaysBounded() {
        let buffer = BoundedPCMBuffer(capacityFrames: 4)
        buffer.append([1, 2, 3])
        let result = buffer.append([4, 5, 6])

        XCTAssertEqual(result, BoundedPCMBuffer.AppendResult(acceptedFrames: 1, droppedFrames: 2))
        XCTAssertEqual(buffer.frameCount, 4)
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.droppedFrameCount, 2)
        XCTAssertEqual(buffer.makeSamples(), [1, 2, 3, 4])

        let afterFull = buffer.append([7, 8])
        XCTAssertEqual(afterFull, BoundedPCMBuffer.AppendResult(acceptedFrames: 0, droppedFrames: 2))
        XCTAssertEqual(buffer.frameCount, 4)
        XCTAssertEqual(buffer.droppedFrameCount, 4)
    }

    func testEmptyAppendIsANoOp() {
        let buffer = BoundedPCMBuffer(capacityFrames: 4)
        let result = buffer.append([])
        XCTAssertEqual(result, BoundedPCMBuffer.AppendResult(acceptedFrames: 0, droppedFrames: 0))
        XCTAssertEqual(buffer.frameCount, 0)
        XCTAssertEqual(buffer.makeSamples(), [])
    }

    func testResetClearsCountersButKeepsCapacity() {
        let buffer = BoundedPCMBuffer(capacityFrames: 3)
        buffer.append([0.5, 0.5, 0.5, 0.5])
        buffer.reset()

        XCTAssertEqual(buffer.frameCount, 0)
        XCTAssertEqual(buffer.droppedFrameCount, 0)
        XCTAssertEqual(buffer.peakLevel, 0)
        XCTAssertEqual(buffer.capacityFrames, 3)
        XCTAssertEqual(buffer.makeSamples(), [])
    }

    func testSinkProducesUtteranceWithDiagnostics() {
        let configuration = VoiceActivityConfiguration(
            windowDuration: 0.02,
            speechThreshold: 0.05,
            silenceThreshold: 0.01,
            speechActivationWindows: 2,
            trailingSilenceDuration: 0.2,
            maximumUtteranceDuration: 5
        )
        let sink = PCMCaptureSink(
            capacityFrames: 1_600,
            detector: EnergyVoiceActivityDetector(configuration: configuration)
        )

        let loud = [Float](repeating: 0.4, count: 800)
        loud.withUnsafeBufferPointer { sink.ingest($0) }

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.frameCount, 800)
        XCTAssertEqual(snapshot.capacityFrames, 1_600)
        XCTAssertEqual(snapshot.duration, 0.05, accuracy: 0.0001)
        XCTAssertEqual(snapshot.voiceActivity.state, .speaking)

        let utterance = sink.finish(reason: .hotkeyRelease)
        XCTAssertEqual(utterance.frameCount, 800)
        XCTAssertEqual(utterance.sampleRate, AudioTargetFormat.sampleRate)
        XCTAssertEqual(utterance.peakLevel, 0.4, accuracy: 0.0001)
        XCTAssertEqual(utterance.droppedFrameCount, 0)
        XCTAssertTrue(utterance.containsSpeech)
        XCTAssertEqual(utterance.endReason, .hotkeyRelease)
    }

    func testSinkNeverExceedsItsCapacity() {
        let sink = PCMCaptureSink(capacityFrames: 100, detector: EnergyVoiceActivityDetector())
        let chunk = [Float](repeating: 0.01, count: 64)
        for _ in 0..<10 {
            chunk.withUnsafeBufferPointer { sink.ingest($0) }
        }

        let snapshot = sink.snapshot()
        XCTAssertEqual(snapshot.frameCount, 100)
        XCTAssertEqual(snapshot.droppedFrameCount, 640 - 100)
        XCTAssertTrue(snapshot.reachedCapacity)
    }
}
