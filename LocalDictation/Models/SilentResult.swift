import Foundation

/// Why a dictation produced no text at all.
///
/// This is the one outcome the app used to handle by saying nothing. Insertion
/// is skipped for empty text, the review policy prices an empty result as
/// quiet, and the state returns to `.ready` — so a user who had just spoken a
/// whole sentence was left reading silence, which reads as a broken app rather
/// than as an empty answer. `docs/PHASE_4_COMPATIBILITY.md` records two
/// utterances of 8.8 s and 10.1 s that did exactly this on a real Mac.
///
/// The two cases are separated because they have different answers. Audio that
/// never reached speech level is a microphone problem: the wrong input device,
/// a muted one, a Mac listening to something the user is not speaking into.
/// Audio that did carry speech and came back empty is the engine's answer, and
/// the useful thing to say is which profile it was asked in — dictating German
/// on a Russian profile is the cheapest way to get nothing back.
///
/// Every field is non-content: a duration, a level, a device name, and a
/// profile label. Nothing derived from what was said can reach here, which is
/// what makes it safe to show and to log.
enum SilentResult: Sendable, Equatable {
    /// The microphone was open and nothing in it ever reached speech level.
    case nothingHeard(duration: TimeInterval, peakLevel: Float, inputDeviceName: String?)
    /// Speech was heard and the engine returned no words for it.
    case nothingRecognized(duration: TimeInterval, profileLabel: String)

    var title: String {
        switch self {
        case .nothingHeard: "Nothing was heard"
        case .nothingRecognized: "Nothing was recognized"
        }
    }

    /// The sentence the user reads, in the menu and in the panel that appears
    /// where they are already looking.
    var message: String {
        switch self {
        case let .nothingHeard(duration, peakLevel, inputDeviceName):
            let device = inputDeviceName.map { "“\($0)”" } ?? "the current input device"
            return """
            The microphone was open for \(Self.seconds(duration)) and never picked up speech \
            (peak level \(Self.level(peakLevel))). Check that \(device) is what you are speaking \
            into, and that it is not muted.
            """
        case let .nothingRecognized(duration, profileLabel):
            return """
            \(Self.seconds(duration)) of speech came back empty, so nothing was inserted. \
            Say it again, or check that the language profile — \(profileLabel) — is the one you spoke.
            """
        }
    }

    var systemImage: String {
        switch self {
        case .nothingHeard: "mic.slash"
        case .nothingRecognized: "waveform.badge.exclamationmark"
        }
    }

    /// Non-content label for the unified log, in the same shape as
    /// `InsertionOutcome.logLabel`.
    var logLabel: String {
        switch self {
        case let .nothingHeard(duration, peakLevel, _):
            "silent:nothingHeard duration=\(Self.seconds(duration)) peak=\(Self.level(peakLevel))"
        case let .nothingRecognized(duration, profileLabel):
            "silent:nothingRecognized duration=\(Self.seconds(duration)) profile=\(profileLabel)"
        }
    }

    private static func seconds(_ duration: TimeInterval) -> String {
        String(format: "%.1f s", duration)
    }

    private static func level(_ level: Float) -> String {
        String(format: "%.3f", level)
    }
}
