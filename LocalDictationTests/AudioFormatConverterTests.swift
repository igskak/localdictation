import AVFoundation
import XCTest
@testable import Witness

final class AudioFormatConverterTests: XCTestCase {
    private func makeFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
        )
    }

    /// A device with more than two channels reports a discrete layout, which
    /// `AVAudioFormat(commonFormat:channels:)` cannot express at all. This builds
    /// the same description the HAL hands us for a raw microphone array.
    private func makeDiscreteFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let layout = try XCTUnwrap(
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        )
        return try XCTUnwrap(AVAudioFormat(streamDescription: &description, channelLayout: layout))
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

    /// A microphone reports 3 raw channels while another app runs voice processing.
    /// `AVAudioConverter.downmix` produced exact zeros for such a discrete layout,
    /// so a dictation during a call recorded silence. Channel 0 must survive.
    func testThreeChannelInputKeepsChannelZero() throws {
        try assertChannelZeroSurvives(channelCount: 3)
    }

    /// Seven channels is what the built-in microphone reports under our own
    /// voice processing, and the same discrete-layout path applies.
    func testSevenChannelInputKeepsChannelZero() throws {
        try assertChannelZeroSurvives(channelCount: 7)
    }

    private func assertChannelZeroSurvives(channelCount: AVAudioChannelCount) throws {
        let multiFormat = try makeDiscreteFormat(sampleRate: 48_000, channels: channelCount)
        let monoFormat = try makeFormat(sampleRate: 48_000, channels: 1)
        let tone: (Int) -> Float = { frame in sin(2 * .pi * 440 * Float(frame) / 48_000) * 0.5 }

        let multi = try AudioFormatConverter(inputFormat: multiFormat)
        let mono = try AudioFormatConverter(inputFormat: monoFormat)

        var fromMulti: [Float] = []
        var fromMono: [Float] = []
        for index in 0..<5 {
            let offset = index * 4_800
            // Channel 0 carries the voice; the raw array channels carry something else.
            let multiBuffer = try makeBuffer(format: multiFormat, frameCount: 4_800) { channel, frame in
                channel == 0 ? tone(offset + frame) : -0.25
            }
            let monoBuffer = try makeBuffer(format: monoFormat, frameCount: 4_800) { _, frame in
                tone(offset + frame)
            }
            fromMulti.append(contentsOf: try multi.convertToArray(multiBuffer))
            fromMono.append(contentsOf: try mono.convertToArray(monoBuffer))
        }
        fromMulti.append(contentsOf: try multi.drainToArray())
        fromMono.append(contentsOf: try mono.drainToArray())

        let peak = fromMulti.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.3, "\(channelCount)-channel input must not convert to silence")
        XCTAssertEqual(fromMulti.count, fromMono.count)
        for (index, sample) in fromMulti.enumerated() {
            XCTAssertEqual(sample, fromMono[index], accuracy: 0.02, "Frame \(index) must match the mono conversion of channel 0")
        }
    }

    /// Documents the channel-0 choice: a signal that never reaches channel 0 is
    /// not mixed in, so a raw array channel cannot leak into the result.
    func testMultiChannelInputIgnoresChannelsOtherThanZero() throws {
        let inputFormat = try makeDiscreteFormat(sampleRate: 48_000, channels: 3)
        let converter = try AudioFormatConverter(inputFormat: inputFormat)

        var output: [Float] = []
        for _ in 0..<5 {
            let buffer = try makeBuffer(format: inputFormat, frameCount: 4_800) { channel, _ in
                channel == 0 ? 0 : 0.8
            }
            output.append(contentsOf: try converter.convertToArray(buffer))
        }
        output.append(contentsOf: try converter.drainToArray())

        let peak = output.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(peak, 0.01, "Only channel 0 is captured")
    }

    func testTargetFormatConstantsMatchThePipelineContract() {
        XCTAssertEqual(AudioTargetFormat.sampleRate, 16_000)
        XCTAssertEqual(AudioTargetFormat.channelCount, 1)
        XCTAssertEqual(AudioCaptureConfiguration.default.bufferCapacityFrames, 300 * 16_000)
    }
}
