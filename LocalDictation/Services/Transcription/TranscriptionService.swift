import Foundation

/// What an engine is busy with while it gets ready.
///
/// The phases are not cosmetic. Downloading and loading fail for different
/// reasons and take wildly different times, and "Preparing…" for seven minutes
/// with no phase and no number is indistinguishable from a hang — which is
/// exactly how it read before this existed.
struct ModelPreparation: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// Fetching weights. The only phase with a real percentage.
        case downloading
        /// Reading weights already on disk. Seconds, once the system has
        /// compiled this model before.
        case loading
        /// Loading has run long enough that this can only be the one-time
        /// Core ML compilation of the model for this Mac and this OS build.
        /// Core ML reports no progress for it, so the honest thing to show is
        /// what is happening and that it does not repeat.
        case compilingForThisSystem
    }

    var phase: Phase
    /// `0...1` when the engine reports it, which in practice means downloads.
    var progress: Double?

    init(phase: Phase, progress: Double? = nil) {
        self.phase = phase
        self.progress = progress
    }
}

/// Whether an engine can actually run right now.
///
/// Model availability is explicit state rather than an implicit precondition:
/// a Whisper-class engine needs weights on disk, and the user has to be told
/// when they are missing instead of watching dictation silently do nothing.
enum TranscriptionModelState: Sendable, Equatable {
    /// Not ready and nothing in flight. `needsUserAction` separates "a person
    /// has to do something" — grant access, approve a 600 MB download — from
    /// "the weights are on disk and only need loading", which reaches no
    /// network and the app may therefore start on its own.
    case unavailable(String, needsUserAction: Bool)
    case preparing(ModelPreparation)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    /// True when getting ready needs nothing from the user and nothing from
    /// the network, so the app may do it unprompted at launch.
    var canPrepareUnattended: Bool {
        if case let .unavailable(_, needsUserAction) = self { return !needsUserAction }
        return false
    }

    var label: String {
        switch self {
        case let .unavailable(detail, _): detail
        case let .preparing(preparation):
            switch preparation.phase {
            case .downloading:
                if let progress = preparation.progress {
                    "Downloading the speech model… \(Int((progress * 100).rounded()))%"
                } else {
                    "Downloading the speech model…"
                }
            case .loading:
                "Loading the speech model…"
            case .compilingForThisSystem:
                "Preparing the speech model for this Mac. The first time on a new macOS version takes several minutes; after that it is seconds."
            }
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
