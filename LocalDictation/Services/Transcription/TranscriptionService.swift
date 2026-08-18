import Foundation

/// Whether an engine can actually run right now.
///
/// Model availability is explicit state rather than an implicit precondition:
/// a Whisper-class engine needs weights on disk, and the user has to be told
/// when they are missing instead of watching dictation silently do nothing.
enum TranscriptionModelState: Sendable, Equatable {
    /// Nothing is installed and no work is in flight.
    case unavailable(String)
    /// Loading or downloading. `progress` is `0...1` when the engine reports it.
    case preparing(progress: Double?)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var label: String {
        switch self {
        case let .unavailable(detail): detail
        case let .preparing(progress):
            if let progress { "Preparing… \(Int((progress * 100).rounded()))%" } else { "Preparing…" }
        case .ready: "Ready"
        case let .failed(detail): detail
        }
    }
}

enum TranscriptionError: Error, Sendable, Equatable {
    case modelUnavailable(String)
    case unsupportedProfile(LanguageProfile)
    case emptyAudio
    case cancelled
    case engineFailure(String)

    var message: String {
        switch self {
        case let .modelUnavailable(detail):
            "Speech model unavailable: \(detail)"
        case let .unsupportedProfile(profile):
            "\(profile.displayName) is not supported by the current speech engine"
        case .emptyAudio:
            "Nothing was recorded"
        case .cancelled:
            "Transcription was cancelled"
        case let .engineFailure(detail):
            "Transcription failed: \(detail)"
        }
    }
}

/// Local transcription boundary.
///
/// Implementations must run inference off the main actor, must honor task
/// cancellation, and must never send audio or text off the machine. Returning
/// token-level timing and confidence is part of the contract, not an optional
/// extra: Phase 3's risk engine is built on it.
protocol TranscriptionService: AnyObject, Sendable {
    /// Stable identifier recorded in transcripts and benchmark results.
    var identifier: String { get }
    var displayName: String { get }

    /// Whether this engine can serve the profile at all.
    func supports(_ profile: LanguageProfile) -> Bool

    /// Non-blocking read of the current model state.
    func modelState(for profile: LanguageProfile) async -> TranscriptionModelState

    /// Loads or downloads whatever the engine needs for the profile.
    /// Callers must only invoke this from an explicit user action.
    func prepare(for profile: LanguageProfile) async throws

    /// Transcribes one completed utterance.
    ///
    /// Must throw `TranscriptionError.cancelled` — or let `CancellationError`
    /// propagate — when the surrounding task is cancelled, so a superseded
    /// request can never deliver a stale transcript.
    func transcribe(_ utterance: CapturedUtterance, profile: LanguageProfile) async throws -> Transcript
}

extension TranscriptionService {
    /// Convenience for engines that support every profile they are asked about.
    func supportsAllProfiles() -> Bool {
        LanguageProfile.all.allSatisfy(supports)
    }
}
