import Foundation

/// Bridges the real-time audio callback and the main actor.
///
/// The audio thread calls `ingest`, which does a bounded copy plus fixed-cost
/// arithmetic under an unfair lock. The main actor calls `snapshot` at UI cadence
/// and `finish` once per utterance. Nothing here allocates, logs, or touches disk
/// while recording.
final class PCMCaptureSink: @unchecked Sendable {
    private let lock = UnfairLock()
    private let buffer: BoundedPCMBuffer
    private let sampleRate: Double
    private var detector: any VoiceActivityDetector

    init(capacityFrames: Int, sampleRate: Double = AudioTargetFormat.sampleRate, detector: any VoiceActivityDetector) {
        buffer = BoundedPCMBuffer(capacityFrames: capacityFrames)
        self.sampleRate = sampleRate
        self.detector = detector
    }

    var capacityFrames: Int { buffer.capacityFrames }

    /// Called from the real-time audio thread.
    func ingest(_ frames: UnsafeBufferPointer<Float>) {
        lock.withLock {
            buffer.append(frames)
            detector.ingest(frames)
        }
    }

    func snapshot() -> CaptureSnapshot {
        lock.withLock {
            CaptureSnapshot(
                frameCount: buffer.frameCount,
                capacityFrames: buffer.capacityFrames,
                peakLevel: buffer.peakLevel,
                droppedFrameCount: buffer.droppedFrameCount,
                voiceActivity: detector.observation,
                sampleRate: sampleRate
            )
        }
    }

    /// Copies the utterance out of the ring of preallocated storage.
    func finish(reason: UtteranceEndReason) -> CapturedUtterance {
        lock.withLock {
            CapturedUtterance(
                samples: buffer.makeSamples(),
                sampleRate: sampleRate,
                peakLevel: buffer.peakLevel,
                droppedFrameCount: buffer.droppedFrameCount,
                voiceActivity: detector.observation,
                endReason: reason
            )
        }
    }

    func reset() {
        lock.withLock {
            buffer.reset()
            detector.reset()
        }
    }
}
