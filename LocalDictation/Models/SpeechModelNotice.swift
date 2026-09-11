import Foundation

/// What a press is told while the speech model is still on its way.
///
/// The first launch has a hole in it that no amount of menu bar copy closed: a
/// person installs a dictation app and presses the key, because pressing the
/// key is the entire product. Before this existed the press either recorded
/// into a five-minute wait — the recording joined the load and the text arrived
/// long after the user had moved on — or it failed with a sentence about a
/// button they had never seen. Both read as an app that does not work.
///
/// So the press is answered instead of served. Nothing is recorded, and the
/// user is told the one thing they need: this happens once, roughly how long it
/// takes, and that the app will say when it is over. `SilentResult` is the same
/// idea for the opposite case, and this deliberately shares its shape — a title,
/// one sentence for the user, and a non-content label for the log.
///
/// Every field is non-content: a phase, a percentage, and the name of a
/// keyboard shortcut. Nothing derived from anything the user said can reach it.
enum SpeechModelNotice: Sendable, Equatable {
    /// A load or a download is already running. The commonest case by far: the
    /// app starts the download itself at launch, so a press within the first
    /// few minutes of a first run lands here.
    case preparing(ModelPreparation, hotkey: String)
    /// The weights are missing and nothing was fetching them — a launch that
    /// had no network, or a download that was never resumed. The press starts
    /// it rather than sending the user to a button.
    case starting(hotkey: String)
    /// Preparation failed. The press retries it.
    case failed(String)
    /// The wait is over, said to the person who pressed during it.
    case ready(hotkey: String)

    var title: String {
        switch self {
        case .preparing, .starting: L10n.string("The speech model is still arriving")
        case .failed: L10n.string("The speech model is not ready")
        case .ready: L10n.string("Ready to dictate")
        }
    }

    /// The sentence the user reads, in the panel that appears where they are
    /// already looking rather than in a menu they have no reason to open.
    var message: String {
        switch self {
        case let .preparing(preparation, hotkey):
            switch preparation.phase {
            case .downloading:
                return L10n.format(
                    "Nothing was recorded yet — Witness is downloading the speech model%@. It happens once, usually within five minutes, and afterwards recognition runs entirely on this Mac. Hold %@ again when it is here; Witness will say so.",
                    Self.percentage(preparation.progress),
                    hotkey
                )
            case .loading:
                return L10n.format(
                    "Nothing was recorded yet — the speech model is loading. That takes seconds. Hold %@ again in a moment.",
                    hotkey
                )
            case .compilingForThisSystem:
                return L10n.format(
                    "Nothing was recorded yet — macOS is preparing the speech model for this Mac. It happens once per macOS version and takes a few minutes. Hold %@ again when it is here; Witness will say so.",
                    hotkey
                )
            }
        case let .starting(hotkey):
            return L10n.format(
                "Nothing was recorded yet — the speech model is not on this Mac. The download has just started: about 600 MB, once, usually within five minutes. Hold %@ again when it is here; Witness will say so.",
                hotkey
            )
        case let .failed(detail):
            return L10n.format(
                "Nothing was recorded — the speech model is not ready. %@ Witness is trying again; the menu bar icon shows how it is going.",
                detail
            )
        case let .ready(hotkey):
            return L10n.format("The speech model is ready. Hold %@ and speak — the text lands where your cursor is.", hotkey)
        }
    }

    var systemImage: String {
        switch self {
        case .preparing, .starting: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        case .ready: "checkmark.circle"
        }
    }

    /// Non-content label for the unified log, in the same shape as
    /// `SilentResult.logLabel`.
    var logLabel: String {
        switch self {
        case let .preparing(preparation, _):
            "model:\(preparation.phase)\(Self.percentage(preparation.progress))"
        case .starting: "model:startingDownload"
        case .failed: "model:failed"
        case .ready: "model:ready"
        }
    }

    /// The download is the one phase with a real number in it. Everything else
    /// gets nothing rather than a fabricated estimate.
    private static func percentage(_ progress: Double?) -> String {
        guard let progress else { return "" }
        return L10n.format(" — %lld%% of about 600 MB", Int64((progress * 100).rounded()))
    }
}
