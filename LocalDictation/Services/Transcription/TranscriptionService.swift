import Foundation

/// What an engine is busy with while it gets ready.
///
/// The phases are not cosmetic. Downloading and loading fail for different
/// reasons and take wildly different times, and "Preparing…" for seven minutes
/// with no phase and no number is indistinguishable from a hang — which is
/// exactly how it read before this existed.
struct ModelPreparation: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// Fetching weights. The only phase with a real percentage, a size and a
        /// time, because it is the only one whose work is counted in bytes.
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
    /// Bytes, a total and a time left. Present exactly while a download is in
    /// flight and its total is known, which is where a bar and an estimate come
    /// from; see `ModelDownloadProgress` for why a fraction over files was not
    /// enough to build either on.
    var download: ModelDownloadProgress?
    /// What an engine reported as a bare fraction, for the engines and the runs
    /// that have nothing better. Reached through `progress`.
    private var reportedProgress: Double?

    /// `0...1` when anything can say how far this has got, which in practice
    /// means downloads.
    var progress: Double? { download?.fraction ?? reportedProgress }

    init(phase: Phase, progress: Double? = nil) {
        self.phase = phase
        reportedProgress = progress
    }

    init(phase: Phase, download: ModelDownloadProgress) {
        self.phase = phase
        self.download = download
    }
}

/// Whether an engine can actually run right now.
///
/// Model availability is explicit state rather than an implicit precondition:
/// a Whisper-class engine needs weights on disk, and the user has to be told
/// when they are missing instead of watching dictation silently do nothing.
enum TranscriptionModelState: Sendable, Equatable {
    /// Not ready and nothing in flight. `needsUserAction` separates "a person
    /// has to do something" — grant access, approve a 1.6 GB download — from
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
                // Three levels of what can honestly be said, in order: bytes and
                // a time, bytes, a bare percentage. The first is what a metered
                // download reports and what the first run now shows.
                if let download = preparation.download {
                    if let time = download.remainingTimeText {
                        L10n.format(
                            "Downloading the speech model… %lld%%. %@ left, %@.",
                            Int64(download.percent),
                            download.remainingSizeText,
                            time
                        )
                    } else {
                        L10n.format(
                            "Downloading the speech model… %lld%%. %@ left.",
                            Int64(download.percent),
                            download.remainingSizeText
                        )
                    }
                } else if let progress = preparation.progress {
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

/// Why getting a model ready did not work, in the three answers that lead to
/// three different things to do about it.
///
/// It is coarse on purpose. The detail belongs in the sentence the user reads
/// and in the log; what a funnel can act on is whether first runs are dying on
/// a connection, on a full disk, or on something nobody has seen yet. The three
/// words are also the entire vocabulary the `model_failed` event may carry, so
/// there is nothing here a filename or a path could be passed into.
enum ModelPreparationFailure: String, Sendable, Equatable {
    /// Anything `URLSession` refuses: offline, a timeout, DNS, a refused host.
    case network
    /// Out of space. The download is 1.6 GB and it is written twice on its way
    /// in, so this is the second-commonest way a first run ends.
    case storage
    case other

    /// Reads the answer out of whatever the engine threw.
    ///
    /// The chain matters more than the top: WhisperKit reports a disk that
    /// filled mid-download as "Model not found. Please check the model or repo
    /// name and try again" and keeps the real `No space left on device`
    /// underneath it, which is the confusion `docs/PHASE_2_BENCHMARK.md`
    /// records somebody losing an afternoon to.
    init(_ error: any Error) {
        for candidate in Self.chain(from: error as NSError) {
            switch (candidate.domain, candidate.code) {
            case (NSURLErrorDomain, _):
                self = .network
                return
            case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                 (NSPOSIXErrorDomain, Int(ENOSPC)):
                self = .storage
                return
            default:
                continue
            }
        }
        self = .other
    }

    /// The error and everything under it, oldest wrapper first. Bounded because
    /// a chain is somebody else's data structure and a cycle in it would hang
    /// a launch.
    private static func chain(from error: NSError, limit: Int = 8) -> [NSError] {
        var found = [error]
        var frontier = [error]
        while !frontier.isEmpty, found.count < limit {
            var next: [NSError] = []
            for error in frontier {
                var underlying = error.underlyingErrors.map { $0 as NSError }
                if underlying.isEmpty, let legacy = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                    underlying = [legacy]
                }
                next.append(contentsOf: underlying)
            }
            found.append(contentsOf: next.prefix(limit - found.count))
            frontier = next
        }
        return found
    }
}

enum TranscriptionError: Error, Sendable, Equatable {
    case modelUnavailable(String)
    /// A load or a download that failed, carrying why in a form something other
    /// than a person can read. `modelUnavailable` stays for the cases that are
    /// a statement about this Mac rather than a failure — no model installed,
    /// recognition not authorized — and reads the same to the user.
    case modelPreparationFailed(ModelPreparationFailure, detail: String)
    case unsupportedProfile(LanguageProfile)
    case emptyAudio
    case cancelled
    case engineFailure(String)

    var message: String {
        switch self {
        case let .modelUnavailable(detail):
            L10n.format("Speech model unavailable: %@", detail)
        case let .modelPreparationFailed(_, detail):
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
