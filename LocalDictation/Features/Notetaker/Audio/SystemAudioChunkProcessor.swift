import AVFoundation
import CoreAudio
import Foundation

enum MeetingAudioSource: Sendable, Equatable { case microphone, system }

struct MeetingAudioChunk: Sendable {
    let source: MeetingAudioSource
    let sequence: UInt64
    let startFrame: Int64
    let sampleRate: Double
    let samples: [Float]
    let isFinal: Bool
}

/// Consumed off the IO thread. Host time is shared with the microphone source;
/// conversion and allocation never occur in the Core Audio callback.
final class SystemAudioChunkProcessor {
    private let buffer: MeetingAudioBuffer
    private let originHostTime: UInt64
    private let converter: AudioFormatConverter
    private var nextFrame: Int64 = 0
    private var nextSequence: UInt64 = 0
    private var finished = false

    init(buffer: MeetingAudioBuffer, inputSampleRate: Double, originHostTime: UInt64) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false) else {
            throw SystemAudioCaptureError.unsupportedFormat
        }
        self.buffer = buffer
        self.originHostTime = originHostTime
        self.converter = try AudioFormatConverter(inputFormat: format)
    }

    func take() throws -> MeetingAudioChunk? {
        guard !finished, let chunk = buffer.take() else { return nil }
        guard chunk.sampleRate == converter.inputFormat.sampleRate,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(max(chunk.samples.count, 1))),
              let channel = input.floatChannelData?[0] else { throw SystemAudioCaptureError.unsupportedFormat }
        input.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { values in
            if let source = values.baseAddress { channel.update(from: source, count: values.count) }
        }
        let frames = try converter.convert(input)
        let start = Self.frame(hostTime: chunk.hostTime, originHostTime: originHostTime)
        nextFrame = start + Int64(frames.count)
        nextSequence = chunk.sequence + 1
        return MeetingAudioChunk(source: .system, sequence: chunk.sequence, startFrame: start,
                                 sampleRate: converter.outputFormat.sampleRate, samples: Array(frames), isFinal: false)
    }

    /// Call after the device is stopped and every queued buffer has been read.
    func finish() throws -> MeetingAudioChunk {
        guard !finished, buffer.snapshot().queuedChunks == 0 else { throw SystemAudioCaptureError.invalidState }
        finished = true
        let tail = try converter.drain()
        return MeetingAudioChunk(source: .system, sequence: nextSequence, startFrame: nextFrame,
                                 sampleRate: converter.outputFormat.sampleRate, samples: Array(tail), isFinal: true)
    }

    private static func frame(hostTime: UInt64, originHostTime: UInt64) -> Int64 {
        let hostNanos = AudioConvertHostTimeToNanos(hostTime)
        let originNanos = AudioConvertHostTimeToNanos(originHostTime)
        let seconds = hostNanos >= originNanos ? Double(hostNanos - originNanos) / 1e9 : -Double(originNanos - hostNanos) / 1e9
        return Int64((seconds * AudioTargetFormat.sampleRate).rounded())
    }
}
