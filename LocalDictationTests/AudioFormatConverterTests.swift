import AVFoundation
import XCTest
@testable import LocalDictation

final class AudioFormatConverterTests: XCTestCase {
    private func makeFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
        )
    }

    private func makeBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        sample: (_ channel: Int, _ frame: Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frameCount) {
                channels[channel][frame] = sample(channel, frame)
            }
        }
        return buffer
    }

    func testOutputFormatIsMonoFloat32At16kHz() throws {
        let converter = try AudioFormatConverter(inputFormat: try makeFormat(sampleRate: 48_000, channels: 2))

        XCTAssertEqual(converter.outputFormat.sampleRate, 16_000)
        XCTAssertEqual(converter.outputFormat.channelCount, 1)
        XCTAssertEqual(converter.outputFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(converter.outputFormat.isInterleaved)
    }

    func testDownsamplingProducesExpectedFrameCount() throws {
        let inputFormat = try makeFormat(sampleRate: 48_000, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: inputFormat)

        // 10 buffers of 4800 frames = 1 second of 48 kHz audio.
        var totalOutputFrames = 0
        for index in 0..<10 {
            let buffer = try makeBuffer(format: inputFormat, frameCount: 4_800) { _, frame in
                sin(2 * .pi * 220 * Float(index * 4_800 + frame) / 48_000) * 0.5
            }
            totalOutputFrames += try converter.convertToArray(buffer).count
        }
        totalOutputFrames += try converter.drainToArray().count

        // One second of input must yield one second at 16 kHz once the resampler
        // latency has been drained.
        XCTAssertEqual(Double(totalOutputFrames), 16_000, accuracy: 64)
    }

    func testStereoInputIsDownmixedToMono() throws {
        let inputFormat = try makeFormat(sampleRate: 44_100, channels: 2)
        let converter = try AudioFormatConverter(inputFormat: inputFormat)

        var output: [Float] = []
        for _ in 0..<5 {
            let buffer = try makeBuffer(format: inputFormat, frameCount: 4_410) { _, _ in 0.5 }
            output.append(contentsOf: try converter.convertToArray(buffer))
        }
        output.append(contentsOf: try converter.drainToArray())

        XCTAssertFalse(output.isEmpty)
        XCTAssertEqual(Double(output.count), 8_000, accuracy: 64)
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
        let maximum = output.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximum, 0.75, "Downmix must not amplify beyond the source level")
        XCTAssertGreaterThan(maximum, 0.3, "Downmixed signal must retain the source amplitude")
    }

    func testDrainRecoversTheTailOfAnUtterance() throws {
        let inputFormat = try makeFormat(sampleRate: 48_000, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: inputFormat)
        let buffer = try makeBuffer(format: inputFormat, frameCount: 4_800) { _, _ in 0.5 }

        let converted = try converter.convertToArray(buffer).count
        let drained = try converter.drainToArray().count

        XCTAssertGreaterThan(drained, 0, "The resampler holds back latency that must be flushed")
        XCTAssertEqual(Double(converted + drained), 1_600, accuracy: 64)
        XCTAssertEqual(try converter.drainToArray().count, 0, "A second drain has nothing left to flush")
    }

    func testEmptyInputProducesNoFrames() throws {
        let inputFormat = try makeFormat(sampleRate: 48_000, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: inputFormat)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 512))
        buffer.frameLength = 0

        XCTAssertEqual(try converter.convertToArray(buffer).count, 0)
    }

    func testAlreadyNormalizedInputPassesThrough() throws {
        let inputFormat = try makeFormat(sampleRate: 16_000, channels: 1)
        let converter = try AudioFormatConverter(inputFormat: inputFormat)
        let buffer = try makeBuffer(format: inputFormat, frameCount: 1_600) { _, frame in
            Float(frame % 2 == 0 ? 0.25 : -0.25)
        }

        let output = try converter.convertToArray(buffer)
        XCTAssertEqual(output.count, 1_600)
        XCTAssertEqual(output.first ?? 0, 0.25, accuracy: 0.0001)
    }

    func testTargetFormatConstantsMatchThePipelineContract() {
        XCTAssertEqual(AudioTargetFormat.sampleRate, 16_000)
        XCTAssertEqual(AudioTargetFormat.channelCount, 1)
        XCTAssertEqual(AudioCaptureConfiguration.default.bufferCapacityFrames, 120 * 16_000)
    }
}
