import AVFoundation
import CoreAudio
import Foundation

enum MeetingAudioSource: String, Sendable, Hashable, Codable { case microphone, system }

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
    private let source: MeetingAudioSource
    private let originHostTime: UInt64
    private let converter: AudioFormatConverter
    private var nextFrame: Int64 = 0
    private var nextSequence: UInt64 = 0
    private var previousSequence: UInt64?
    private var expectedInputEndNanos: UInt64?
    private var nextChunkStartsAtHostTime = false
    private var finished = false

    init(buffer: MeetingAudioBuffer, inputSampleRate: Double, originHostTime: UInt64, source: MeetingAudioSource = .system) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false) else {
            throw SystemAudioCaptureError.unsupportedFormat
        }
        self.buffer = buffer
        self.source = source
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
        let hostNanos = AudioConvertHostTimeToNanos(chunk.hostTime)
        if let previousSequence, chunk.sequence != previousSequence + 1 {
            // The bounded capture queue reports the loss separately. Keep the
            // session alive, preserve the gap on the host-time timeline, and
            // let the UI/metrics mark the note partial instead of discarding
            // everything captured after one delayed callback.
            guard chunk.sequence > previousSequence else { throw SystemAudioCaptureError.discontinuity }
            nextChunkStartsAtHostTime = true
        }
        if let expected = expectedInputEndNanos {
            let delta = hostNanos >= expected ? hostNanos - expected : expected - hostNanos
            let tolerance = UInt64((2e9 / chunk.sampleRate).rounded(.up))
            if delta > tolerance {
                // A process tap may stop delivering callbacks while an app is
                // silent. The callback sequence remains continuous, so this is
                // a real timeline gap rather than dropped audio. Re-anchor the
                // next system chunk instead of terminating the whole meeting.
                // Sequence continuity proves the callback itself was not
                // dropped. Both a sparse process tap and a temporarily delayed
                // microphone callback can therefore continue at host time.
                nextChunkStartsAtHostTime = true
            }
        }
        let start = previousSequence == nil || nextChunkStartsAtHostTime
            ? Self.frame(hostTime: chunk.hostTime, originHostTime: originHostTime)
            : nextFrame
        nextChunkStartsAtHostTime = false
        let frames = try converter.convert(input)
        nextFrame = start + Int64(frames.count)
        nextSequence = chunk.sequence + 1
        previousSequence = chunk.sequence
        expectedInputEndNanos = hostNanos + UInt64((Double(chunk.samples.count) / chunk.sampleRate * 1e9).rounded())
        return MeetingAudioChunk(source: source, sequence: chunk.sequence, startFrame: start,
                                 sampleRate: converter.outputFormat.sampleRate, samples: Array(frames), isFinal: false)
    }

    /// Pause is an intentional hole, not lost audio. The first resumed chunk
    /// keeps its host-time position while sequence checking stays intact.
    func prepareForResume() {
        expectedInputEndNanos = nil
        nextChunkStartsAtHostTime = true
    }

    /// Call after the device is stopped and every queued buffer has been read.
    func finish() throws -> MeetingAudioChunk {
        guard !finished, buffer.snapshot().queuedChunks == 0 else { throw SystemAudioCaptureError.invalidState }
        finished = true
        let tail = try converter.drain()
        return MeetingAudioChunk(source: source, sequence: nextSequence, startFrame: nextFrame,
                                 sampleRate: converter.outputFormat.sampleRate, samples: Array(tail), isFinal: true)
    }

    private static func frame(hostTime: UInt64, originHostTime: UInt64) -> Int64 {
        let hostNanos = AudioConvertHostTimeToNanos(hostTime)
        let originNanos = AudioConvertHostTimeToNanos(originHostTime)
        let seconds = hostNanos >= originNanos ? Double(hostNanos - originNanos) / 1e9 : -Double(originNanos - hostNanos) / 1e9
        return Int64((seconds * AudioTargetFormat.sampleRate).rounded())
    }
}
