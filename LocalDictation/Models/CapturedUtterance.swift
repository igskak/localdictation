import Foundation

/// Why an utterance stopped. Phase 1 uses push-to-talk release as the primary
/// boundary; the detector only reports silence, it does not end the utterance.
enum UtteranceEndReason: String, Sendable, Equatable {
    case hotkeyRelease
    case maximumDuration
    case interrupted
}

/// One completed in-memory utterance.
///
/// Audio never leaves memory in Phase 1: there is no persistence, and the debug
/// export is a separate, explicitly user-initiated action.
struct CapturedUtterance: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
    let peakLevel: Float
    let droppedFrameCount: Int
    let voiceActivity: VoiceActivityObservation
    let endReason: UtteranceEndReason
    /// How many times capture moved to another input segment while this was
    /// being said. Non-zero means the route changed and the sentence survived
    /// it; the user was told nothing, so the diagnostics are where it shows.
    var rebindCount: Int = 0

    var frameCount: Int { samples.count }
    var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    var containsSpeech: Bool { voiceActivity.speechStart != nil }
}

/// Content-free levels computed once a recording has left the real-time path.
///
/// Peak alone cannot distinguish one click from a sentence. RMS makes an empty
/// recognition diagnosable without retaining or logging any audio samples.
struct AudioSignalMetrics: Sendable, Equatable {
    let rmsLevel: Float
    let peakLevel: Float

    static func measure(_ samples: [Float]) -> AudioSignalMetrics {
        guard !samples.isEmpty else { return AudioSignalMetrics(rmsLevel: 0, peakLevel: 0) }

        var squaredSum: Double = 0
        var peak: Float = 0
        var finiteSampleCount = 0
        for sample in samples where sample.isFinite {
            squaredSum += Double(sample) * Double(sample)
            peak = max(peak, abs(sample))
            finiteSampleCount += 1
        }
        guard finiteSampleCount > 0 else { return AudioSignalMetrics(rmsLevel: 0, peakLevel: 0) }
        return AudioSignalMetrics(
            rmsLevel: Float((squaredSum / Double(finiteSampleCount)).squareRoot()),
            peakLevel: peak
        )
    }
}

/// Non-content summary of the last utterance, safe to show in the UI and to log.
struct UtteranceSummary: Sendable, Equatable {
    let duration: TimeInterval
    let frameCount: Int
    let sampleRate: Double
    let peakLevel: Float
    let rmsLevel: Float
    let droppedFrameCount: Int
    let speechStart: TimeInterval?
    let trailingSilence: TimeInterval
    let endReason: UtteranceEndReason
    let rebindCount: Int
    /// Whether this Mac heard speech at all, which is a different question
    /// from whether the engine recognized any. The live detector runs at the
    /// level the samples arrived at, so a recording from a raw microphone
    /// array is answered on a normalized copy instead — see
    /// `NormalizedVoiceActivity`.
    let heardSpeech: Bool

    /// `heardSpeech` defaults to the live detector's own answer. The dictation
    /// path passes the normalized one.
    init(_ utterance: CapturedUtterance, heardSpeech: Bool? = nil) {
        let signal = AudioSignalMetrics.measure(utterance.samples)
        duration = utterance.duration
        frameCount = utterance.frameCount
        sampleRate = utterance.sampleRate
        peakLevel = utterance.peakLevel
        rmsLevel = signal.rmsLevel
        droppedFrameCount = utterance.droppedFrameCount
        speechStart = utterance.voiceActivity.speechStart
        trailingSilence = utterance.voiceActivity.trailingSilence
        endReason = utterance.endReason
        rebindCount = utterance.rebindCount
        self.heardSpeech = heardSpeech ?? (utterance.voiceActivity.speechStart != nil)
    }
}
