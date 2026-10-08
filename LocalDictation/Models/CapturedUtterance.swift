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

/// Non-content summary of the last utterance, safe to show in the UI and to log.
struct UtteranceSummary: Sendable, Equatable {
    let duration: TimeInterval
    let frameCount: Int
    let sampleRate: Double
    let peakLevel: Float
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
        duration = utterance.duration
        frameCount = utterance.frameCount
        sampleRate = utterance.sampleRate
        peakLevel = utterance.peakLevel
        droppedFrameCount = utterance.droppedFrameCount
        speechStart = utterance.voiceActivity.speechStart
        trailingSilence = utterance.voiceActivity.trailingSilence
        endReason = utterance.endReason
        rebindCount = utterance.rebindCount
        self.heardSpeech = heardSpeech ?? (utterance.voiceActivity.speechStart != nil)
    }
}
