import Foundation

/// One utterance's samples, held only for as long as a review needs them.
///
/// A named type rather than a loose `[Float]` so "the app is still holding the
/// recording" is a visible fact in the coordinator and in its tests, instead of
/// an array that quietly outlives the interaction.
struct RetainedAudio: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double

    var frameCount: Int { samples.count }
    var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    func slice(from start: TimeInterval, to end: TimeInterval) -> [Float] {
        guard sampleRate > 0, end > start else { return [] }
        let lower = min(max(Int(start * sampleRate), 0), samples.count)
        let upper = min(max(Int(end * sampleRate), lower), samples.count)
        return Array(samples[lower..<upper])
    }
}

enum AudioPlaybackError: Error, Equatable {
    case emptyFragment
    case engineFailure(String)

    var message: String {
        switch self {
        case .emptyFragment: "That fragment has no audio to play"
        case let .engineFailure(detail): "Playback failed: \(detail)"
        }
    }
}

/// Plays a fragment of the retained utterance.
///
/// Main-actor bound because playback is started and stopped by the review strip
/// and nothing else; there is no real-time constraint here, unlike capture.
@MainActor
protocol AudioFragmentPlayer: AnyObject {
    var isPlaying: Bool { get }
    /// Plays `samples` directly from memory. Implementations must not write the
    /// fragment to disk or hand it to any service outside the process.
    func play(samples: [Float], sampleRate: Double) throws
    func stop()
}
