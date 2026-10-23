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

/// One source's 16 kHz timeline, kept the way a recorder writes a track: a
/// chunk starts where the previous one ended, and host time only corrects
/// that position. The device clock and the host clock drift apart by tens of
/// milliseconds over half an hour, and a process tap stops delivering while
/// its app is silent, so a disagreement is never an error:
///
/// - within `driftToleranceFrames` the sample count wins;
/// - a late chunk is preceded by silence up to `paddingLimitFrames`, so a
///   clock correction does not split a sentence into two windows;
/// - a longer hole starts the chunk at its host-time position, and the window
///   builder closes the window there instead of inventing silence;
/// - a chunk that claims audio already handed out loses that overlap, which
///   resynchronises a device clock that runs fast;
/// - a jump back of more than `clockResetFrames` means the device restarted
///   its clock: the audio is kept and the timeline continues.
///
/// On 23.10 a meeting ended after 29 minutes because one backward correction
/// was treated as missing audio.
struct MeetingTimeline: Sendable, Equatable {
    enum Correction: Sendable, Equatable {
        case none
        case padded(frames: Int)
        case trimmed(frames: Int)
        case gap(frames: Int64)
        case clockReset(frames: Int64)
    }

    struct Placement: Sendable, Equatable {
        let startFrame: Int64
        let paddingFrames: Int
        let trimmedFrames: Int
        let correction: Correction
    }

    static let driftToleranceFrames: Int64 = 320
    static let paddingLimitFrames: Int64 = 4_000
    static let clockResetFrames: Int64 = 32_000

    private(set) var nextFrame: Int64?
    private var hostOffset: Int64 = 0

    /// The next chunk starts at its host-time position, as after a pause.
    mutating func reanchor() {
        nextFrame = nil
    }

    mutating func place(hostFrame rawHostFrame: Int64, frameCount: Int) -> Placement {
        let hostFrame = rawHostFrame + hostOffset
        let placement: Placement
        if let next = nextFrame {
            let drift = hostFrame - next
            if abs(drift) <= Self.driftToleranceFrames {
                placement = Placement(startFrame: next, paddingFrames: 0, trimmedFrames: 0, correction: .none)
            } else if drift > Self.paddingLimitFrames {
                placement = Placement(startFrame: hostFrame, paddingFrames: 0, trimmedFrames: 0,
                                      correction: .gap(frames: drift))
            } else if drift > 0 {
                placement = Placement(startFrame: next, paddingFrames: Int(drift), trimmedFrames: 0,
                                      correction: .padded(frames: Int(drift)))
            } else if -drift > Self.clockResetFrames {
                hostOffset += -drift
                placement = Placement(startFrame: next, paddingFrames: 0, trimmedFrames: 0,
                                      correction: .clockReset(frames: -drift))
            } else {
                let trimmed = min(Int(-drift), frameCount)
                placement = Placement(startFrame: next, paddingFrames: 0, trimmedFrames: trimmed,
                                      correction: .trimmed(frames: trimmed))
            }
        } else {
            placement = Placement(startFrame: hostFrame, paddingFrames: 0, trimmedFrames: 0, correction: .none)
        }
        nextFrame = placement.startFrame + Int64(placement.paddingFrames + frameCount - placement.trimmedFrames)
        return placement
    }
}

/// Consumed off the IO thread. Host time is shared with the microphone source;
/// conversion and allocation never occur in the Core Audio callback.
final class SystemAudioChunkProcessor {
    private let buffer: MeetingAudioBuffer
    private let source: MeetingAudioSource
    private let originHostTime: UInt64
    private let converter: AudioFormatConverter
    private var timeline = MeetingTimeline()
    private var nextSequence: UInt64 = 0
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

    /// Returns the next placed chunk, or nil once the queue is empty. A chunk
    /// whose audio was already handed out entirely is skipped, not returned.
    func take() throws -> MeetingAudioChunk? {
        while !finished, let chunk = buffer.take() {
            guard chunk.sampleRate == converter.inputFormat.sampleRate,
                  let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(max(chunk.samples.count, 1))),
                  let channel = input.floatChannelData?[0] else { throw SystemAudioCaptureError.unsupportedFormat }
            input.frameLength = AVAudioFrameCount(chunk.samples.count)
            chunk.samples.withUnsafeBufferPointer { values in
                if let source = values.baseAddress { channel.update(from: source, count: values.count) }
            }
            let frames = try converter.convert(input)
            nextSequence = chunk.sequence + 1
            let placement = timeline.place(
                hostFrame: Self.frame(hostTime: chunk.hostTime, originHostTime: originHostTime),
                frameCount: frames.count
            )
            report(placement.correction)
            var samples = [Float](repeating: 0, count: placement.paddingFrames)
            samples.append(contentsOf: frames.dropFirst(placement.trimmedFrames))
            guard !samples.isEmpty else { continue }
            return MeetingAudioChunk(source: source, sequence: chunk.sequence, startFrame: placement.startFrame,
                                     sampleRate: converter.outputFormat.sampleRate, samples: samples, isFinal: false)
        }
        return nil
    }

    /// Pause is an intentional hole, not lost audio. The first resumed chunk
    /// keeps its host-time position while sequence checking stays intact.
    func prepareForResume() {
        timeline.reanchor()
    }

    /// Call after the device is stopped and every queued buffer has been read.
    func finish() throws -> MeetingAudioChunk {
        guard !finished, buffer.snapshot().queuedChunks == 0 else { throw SystemAudioCaptureError.invalidState }
        finished = true
        let tail = try converter.drain()
        return MeetingAudioChunk(source: source, sequence: nextSequence, startFrame: timeline.nextFrame ?? 0,
                                 sampleRate: converter.outputFormat.sampleRate, samples: Array(tail), isFinal: true)
    }

    /// Gaps are routine for a sparse process tap, so only corrections that
    /// change audio are worth a line in the log.
    private func report(_ correction: MeetingTimeline.Correction) {
        let milliseconds = { (frames: Int64) in frames * 1_000 / Int64(AudioTargetFormat.sampleRate) }
        switch correction {
        case .none:
            break
        case let .gap(frames):
            Log.audio.debug("Meeting \(self.source.rawValue, privacy: .public) timeline gap: \(milliseconds(frames), privacy: .public) ms")
        case let .padded(frames):
            Log.audio.info("Meeting \(self.source.rawValue, privacy: .public) timeline padded \(milliseconds(Int64(frames)), privacy: .public) ms of silence")
        case let .trimmed(frames):
            Log.audio.info("Meeting \(self.source.rawValue, privacy: .public) timeline trimmed \(milliseconds(Int64(frames)), privacy: .public) ms of overlap")
        case let .clockReset(frames):
            Log.audio.notice("Meeting \(self.source.rawValue, privacy: .public) device clock jumped back \(milliseconds(frames), privacy: .public) ms; audio kept")
        }
    }

    private static func frame(hostTime: UInt64, originHostTime: UInt64) -> Int64 {
        let hostNanos = AudioConvertHostTimeToNanos(hostTime)
        let originNanos = AudioConvertHostTimeToNanos(originHostTime)
        let seconds = hostNanos >= originNanos ? Double(hostNanos - originNanos) / 1e9 : -Double(originNanos - hostNanos) / 1e9
        return Int64((seconds * AudioTargetFormat.sampleRate).rounded())
    }
}
