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

    /// Whether getting ready is a wait measured in minutes rather than seconds,
    /// and therefore one a press has to be answered about rather than held
    /// through.
    ///
    /// A warm load — reading installed weights — is about nine seconds, and a
    /// recording made during one is kept and transcribed the moment it ends.
    /// A download and a first-ever Core ML compilation are minutes, and text
    /// arriving minutes late lands in whatever application the user has moved
    /// on to. The two need different answers, so the difference is named here
    /// rather than re-derived at each of the places that acts on it.
    var isLongWait: Bool {
        switch self {
        case .ready: false
        case let .preparing(preparation): preparation.phase != .loading
        case .unavailable, .failed: true
        }
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
                    L10n.format("Downloading the speech model… %lld%%", Int64((progress * 100).rounded()))
                } else {
                    L10n.string("Downloading the speech model…")
                }
            case .loading:
                L10n.string("Loading the speech model…")
            case .compilingForThisSystem:
                L10n.string("Preparing the speech model for this Mac. The first time on a new macOS version takes several minutes; after that it is seconds.")
            }
        case .ready: L10n.string("Ready")
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
            L10n.format("Speech model unavailable: %@", detail)
        case let .unsupportedProfile(profile):
            L10n.format("%@ is not supported by the current speech engine", profile.displayName)
        case .emptyAudio:
            L10n.string("Nothing was recorded")
        case .cancelled:
            L10n.string("Transcription was cancelled")
        case let .engineFailure(detail):
            L10n.format("Transcription failed: %@", detail)
        }
    }
}

/// How much of a recording an engine is given to decide its language before the
/// user has finished speaking.
///
/// Whisper cannot decode until it knows the language, and finding out costs a
/// full encoder pass over a fixed thirty-second window however short the
/// utterance is — the same pass the decode then runs again. Handed the opening
/// of the recording, the engine can pay that while the user is still talking,
/// which takes it off the wait that starts when they stop.
///
/// The duration is a compromise between the two things it trades: the head
/// start needs enough speech for Whisper's language head to mean anything, and
/// it has to begin early enough to finish before an ordinary sentence does.
/// Utterances shorter than this never get one, and are decided by
/// `LanguageDecision` from what came before them instead.
enum LanguageHeadStart {
    static let duration: TimeInterval = 1.5

    static var frames: Int { Int((duration * AudioTargetFormat.sampleRate).rounded()) }
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

    /// Offers the opening of an utterance that is still being spoken, so an
    /// engine that must decide a language before it can decode may do that work
    /// now rather than after the user stops.
    ///
    /// Advisory in both directions: the caller may never call it, and the
    /// engine may ignore it. Nothing `transcribe` returns may depend on whether
    /// this was called, and an engine must never start a model load from here —
    /// a recording is not a place to wait for weights.
    ///
    /// Deliberately has no default implementation, even though most engines
    /// want an empty one. A default here is a trap: an actor satisfying it with
    /// a synchronous method declares a *different* overload, the empty default
    /// wins both the witness and the call, and the whole optimization does
    /// nothing while every test still passes. That is exactly what happened.
    /// Required, it is a compile error instead.
    func beginLanguageDetection(prefix: [Float], profile: LanguageProfile) async
}

extension TranscriptionService {

    /// Convenience for engines that support every profile they are asked about.
    func supportsAllProfiles() -> Bool {
        LanguageProfile.all.allSatisfy(supports)
    }
}
