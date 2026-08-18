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

    init(_ utterance: CapturedUtterance) {
        duration = utterance.duration
        frameCount = utterance.frameCount
        sampleRate = utterance.sampleRate
        peakLevel = utterance.peakLevel
        droppedFrameCount = utterance.droppedFrameCount
        speechStart = utterance.voiceActivity.speechStart
        trailingSilence = utterance.voiceActivity.trailingSilence
        endReason = utterance.endReason
    }
}
