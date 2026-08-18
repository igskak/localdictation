import Foundation

/// Tunable boundary-detection thresholds. Values are deliberately plain numbers
/// so the pure logic stays unit-testable.
struct VoiceActivityConfiguration: Sendable, Equatable {
    /// Length of one RMS analysis window.
    var windowDuration: TimeInterval
    /// RMS level at or above which a window counts as speech.
    var speechThreshold: Float
    /// RMS level below which a window counts as silence. Kept lower than
    /// `speechThreshold` to provide hysteresis around the boundary.
    var silenceThreshold: Float
    /// Consecutive speech windows required before speech start is declared.
    var speechActivationWindows: Int
    /// Trailing silence after speech that marks the end of an utterance.
    var trailingSilenceDuration: TimeInterval
    /// Hard cap on one utterance. Reaching it ends the capture.
    var maximumUtteranceDuration: TimeInterval

    static let `default` = VoiceActivityConfiguration(
        windowDuration: 0.02,
        speechThreshold: 0.02,
        silenceThreshold: 0.012,
        speechActivationWindows: 3,
        trailingSilenceDuration: 1.0,
        maximumUtteranceDuration: 120
    )

    /// Clamps user-supplied values into a range the detector can honor.
    func validated() -> VoiceActivityConfiguration {
        var copy = self
        copy.windowDuration = min(max(windowDuration, 0.005), 0.1)
        copy.speechThreshold = min(max(speechThreshold, 0.0005), 0.5)
        copy.silenceThreshold = min(max(silenceThreshold, 0.0001), copy.speechThreshold)
        copy.speechActivationWindows = max(speechActivationWindows, 1)
        copy.trailingSilenceDuration = min(max(trailingSilenceDuration, 0.1), 10)
        copy.maximumUtteranceDuration = min(max(maximumUtteranceDuration, 1), 600)
        return copy
    }
}

/// Boundary state. `endedBySilence` and `endedByMaximumDuration` are terminal
/// observations, not instructions to discard audio: Phase 1 never trims frames.
enum VoiceActivityState: String, Sendable, Equatable {
    case idle
    case speaking
    case trailingSilence
    case endedBySilence
    case endedByMaximumDuration

    var isTerminal: Bool { self == .endedBySilence || self == .endedByMaximumDuration }

    var label: String {
        switch self {
        case .idle: "Waiting for speech"
        case .speaking: "Speech"
        case .trailingSilence: "Trailing silence"
        case .endedBySilence: "Ended (silence)"
        case .endedByMaximumDuration: "Ended (maximum duration)"
        }
    }
}

struct VoiceActivityObservation: Sendable, Equatable {
    var state: VoiceActivityState
    /// Offset of detected speech start inside the utterance, if any.
    var speechStart: TimeInterval?
    /// Current uninterrupted trailing silence after speech.
    var trailingSilence: TimeInterval
    /// Audio analyzed so far.
    var elapsed: TimeInterval
    /// RMS of the most recently completed analysis window.
    var lastWindowRMS: Float

    static let initial = VoiceActivityObservation(
        state: .idle,
        speechStart: nil,
        trailingSilence: 0,
        elapsed: 0,
        lastWindowRMS: 0
    )
}

/// Replaceable boundary detector. The energy baseline below is intentionally
/// simple; a production VAD can be substituted without touching capture code.
protocol VoiceActivityDetector: Sendable {
    var configuration: VoiceActivityConfiguration { get }
    var observation: VoiceActivityObservation { get }
    mutating func reset()
    @discardableResult
    mutating func ingest(_ frames: UnsafeBufferPointer<Float>) -> VoiceActivityObservation
}

extension VoiceActivityDetector {
    @discardableResult
    mutating func ingest(_ frames: [Float]) -> VoiceActivityObservation {
        frames.withUnsafeBufferPointer { ingest($0) }
    }
}
