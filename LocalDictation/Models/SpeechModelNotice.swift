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
/// Every field is non-content: a phase, a percentage, two byte counts, a
/// duration, and the name of a keyboard shortcut. Nothing derived from anything
/// the user said can reach it.
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
    case transcribingFile

    /// The one notice that is good news, and the one nobody is waiting to
    /// dismiss: it stays up until they do.
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var title: String {
        switch self {
        case let .preparing(preparation, _):
            L10n.string(preparation.phase == .downloading ? "Downloading the speech model" : "Preparing your speech model")
        case .starting: L10n.string("Downloading the speech model")
        case .failed: L10n.string("The speech model is not ready")
        case .ready: L10n.string("Ready to dictate")
        case .transcribingFile: L10n.string("Transcribing a file")
        }
    }

    /// The sentence the user reads, in the panel that appears where they are
    /// already looking rather than in a menu they have no reason to open.
    var message: String { message(activation: .pushToTalk, automaticallyInserts: true) }

    func message(activation: RecordingActivation, automaticallyInserts: Bool, currentHotkey: String? = nil) -> String {
        func instruction(_ originalHotkey: String) -> String {
            let key = currentHotkey ?? originalHotkey
            switch activation {
            case .pushToTalk:
                return L10n.format("Hold %@ while you speak, then release it to finish.", key)
            case .toggle:
                return L10n.format("Press %@ to start, then press it again to finish.", key)
            }
        }
        switch self {
        case let .preparing(preparation, hotkey):
            switch preparation.phase {
            case .downloading:
                return L10n.format(
                    "Witness is downloading the speech model%@. Nothing has been recorded. When it is ready: %@",
                    Self.progressClause(preparation), instruction(hotkey)
                )
            case .loading:
                return L10n.format(
                    "The speech model is loading. Nothing has been recorded. Once it is ready: %@", instruction(hotkey)
                )
            case .compilingForThisSystem:
                return L10n.format(
                    "macOS is preparing the speech model for this Mac. This may take a few minutes. Nothing has been recorded. When it is ready: %@",
                    instruction(hotkey)
                )
            }
        case let .starting(hotkey):
            if DictationEngineChoice.active != .whisper {
                return "The selected speech model download has started. Nothing has been recorded. We will let you know when it is ready. Then: " + instruction(hotkey)
            }
            return L10n.format(
                "The speech model download has started: about %@. Nothing has been recorded. We will let you know when it is ready. Then: %@",
                SpeechModelDownloadSize.pinnedVariantSizeText, instruction(hotkey)
            )
        case let .failed(detail):
            return L10n.format(
                "The speech model is not ready, so nothing was recorded. %@ Witness is retrying. Check progress in the menu bar.", detail
            )
        case .transcribingFile:
            return L10n.string("You can dictate again when your file is ready. To stop it, open the file window.")
        case let .ready(hotkey):
            let delivery = automaticallyInserts
                ? L10n.string("Text will appear at your cursor.")
                : L10n.string("You can copy your dictation from Witness.")
            return L10n.format("The speech model is ready. %@ %@", instruction(hotkey), delivery)
        }
    }

    var systemImage: String {
        switch self {
        case .preparing, .starting: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        case .ready: "checkmark.circle"
        case .transcribingFile: "waveform"
        }
    }

    /// Non-content label for the unified log, in the same shape as
    /// `SilentResult.logLabel`.
    var logLabel: String {
        switch self {
        case let .preparing(preparation, _):
            "model:\(preparation.phase)\(Self.logPercentage(preparation.progress))"
        case .starting: "model:startingDownload"
        case .failed: "model:failed"
        case .ready: "model:ready"
        case .transcribingFile: "model:busyWithFile"
        }
    }

    /// The download is the one phase with real numbers in it. Everything else
    /// gets nothing rather than a fabricated estimate.
    ///
    /// A measured download says how much is left and how long that is likely to
    /// take, which is the whole reason the panel is worth reading: the person has
    /// just pressed a key and been told to wait, and "wait" without a figure is
    /// what they would have got from an app that had stopped.
    private static func progressClause(_ preparation: ModelPreparation) -> String {
        if let download = preparation.download {
            if let time = download.remainingTimeText {
                return L10n.format(
                    " — %lld%%, %@ left, %@",
                    Int64(download.percent),
                    download.remainingSizeText,
                    time
                )
            }
            return L10n.format(" — %lld%%, %@ left", Int64(download.percent), download.remainingSizeText)
        }
        guard let progress = preparation.progress else { return "" }
        return L10n.format(
            " — %lld%% of about %@",
            Int64((progress * 100).rounded()),
            SpeechModelDownloadSize.pinnedVariantSizeText
        )
    }

    /// The log wants the number and none of the sentence around it.
    private static func logPercentage(_ progress: Double?) -> String {
        guard let progress else { return "" }
        return " \(Int((progress * 100).rounded()))%"
    }
}
