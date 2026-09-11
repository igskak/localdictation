import Foundation

/// How the hotkey starts and ends a recording.
///
/// `docs/PRODUCT_SCOPE.md` has listed both modes in the MVP since the first
/// draft, and only the first was built. They are not preferences about the same
/// thing: push-to-talk is a key held for the length of a sentence, and toggle
/// is two presses around a paragraph. A user dictating a long note cannot hold
/// a key for four minutes, and a user dictating into a chat does not want to
/// remember that the microphone is still open.
enum RecordingActivation: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
    /// Hold to record, release to finish.
    case pushToTalk
    /// Press to start, press again to finish.
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk: L10n.string("Hold to talk")
        case .toggle: L10n.string("Press to start and stop")
        }
    }

    var explanation: String {
        switch self {
        case .pushToTalk:
            L10n.string("The microphone is open only while the key is down. Best for a sentence at a time.")
        case .toggle:
            L10n.string("One press starts, the next finishes. Best for anything longer than a key is comfortable to hold.")
        }
    }
}

/// The choices that survive a launch.
///
/// The third thing this app writes to disk, after the dictionary and the
/// licensing record, and named as one rather than slipped into `UserDefaults`
/// where it would not appear in any of the sentences this project has written
/// about what it stores. Everything here is a choice the user made about the
/// app itself — a key combination, how that key behaves, which languages to
/// recognize, whether text goes in by itself. None of it is derived from
/// anything that was said, and a test asserts the exact field list, the same
/// way one does for `license.json`.
///
/// A settings file is not optional for these. A shortcut that reverts to
/// ⌥Space on every launch is not a configurable shortcut, and a language
/// selection that resets is a product asking the same question every morning.
struct Preferences: Sendable, Equatable, Codable {
    var hotkeyKeyCode: UInt32
    var hotkeyModifiers: UInt32
    var hotkeyKeyLabel: String
    var activation: RecordingActivation
    var languageProfile: LanguageProfile
    var insertsAutomatically: Bool
    /// Whether the user has ever been asked which languages they speak.
    ///
    /// Not the same question as "is a profile stored". Every build since
    /// Phase 1 has stored a profile, because there has always been a default,
    /// and a default nobody chose is exactly what `docs/PHASE_7.md` replaces.
    /// False on a file written by an older build, which is correct: that user
    /// has not been asked either, and their stored pair is what the picker
    /// opens with.
    var hasChosenLanguages: Bool
    /// Whether the three licensing-funnel events may be sent.
    ///
    /// On by default, and the only field here that is on by default *and*
    /// sends something. That asymmetry is deliberate and is the whole of the
    /// decision: an opt-in measurement of where people give up is measured on
    /// the people who did not give up, which answers a different question than
    /// the one it was built for. What it owes in exchange is that the first-run
    /// screen says it out loud, `docs/PRIVACY.md` names all five fields, and
    /// this switch is one click away in Settings → Privacy.
    ///
    /// It gates `trial_started`, `activation_requested` and `paywall_shown`.
    /// Nothing else is transmitted at all — see `TelemetryEvent.transmitted`.
    var sharesProductEvents: Bool

    static let `default` = Preferences(
        hotkeyKeyCode: HotkeyBinding.optionSpace.keyCode,
        hotkeyModifiers: HotkeyBinding.optionSpace.modifiers.rawValue,
        hotkeyKeyLabel: HotkeyBinding.optionSpace.keyLabel,
        activation: .pushToTalk,
        languageProfile: .default,
        insertsAutomatically: true,
        hasChosenLanguages: false,
        sharesProductEvents: true
    )

    /// Decoded field by field only so the newest one can be absent.
    ///
    /// The other six stay required. A file missing one of those is a file
    /// something went wrong with, and `FilePreferencesStore` already treats
    /// that as the recoverable state it is.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyKeyCode = try container.decode(UInt32.self, forKey: .hotkeyKeyCode)
        hotkeyModifiers = try container.decode(UInt32.self, forKey: .hotkeyModifiers)
        hotkeyKeyLabel = try container.decode(String.self, forKey: .hotkeyKeyLabel)
        activation = try container.decode(RecordingActivation.self, forKey: .activation)
        languageProfile = try container.decode(LanguageProfile.self, forKey: .languageProfile)
        insertsAutomatically = try container.decode(Bool.self, forKey: .insertsAutomatically)
        hasChosenLanguages = try container.decodeIfPresent(Bool.self, forKey: .hasChosenLanguages) ?? false
        // Absent on a file written by a build that had nothing to transmit.
        // `true` is the same answer that build gave in practice — it sent
        // nothing because there was nowhere to send it, and this one asks on
        // the first-run screen before the first of these events can happen.
        sharesProductEvents = try container.decodeIfPresent(Bool.self, forKey: .sharesProductEvents) ?? true
    }

    init(
        hotkeyKeyCode: UInt32,
        hotkeyModifiers: UInt32,
        hotkeyKeyLabel: String,
        activation: RecordingActivation,
        languageProfile: LanguageProfile,
        insertsAutomatically: Bool,
        hasChosenLanguages: Bool,
        sharesProductEvents: Bool = true
    ) {
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.hotkeyKeyLabel = hotkeyKeyLabel
        self.activation = activation
        self.languageProfile = languageProfile
        self.insertsAutomatically = insertsAutomatically
        self.hasChosenLanguages = hasChosenLanguages
        self.sharesProductEvents = sharesProductEvents
    }

    var hotkeyBinding: HotkeyBinding {
        get {
            HotkeyBinding(
                keyCode: hotkeyKeyCode,
                modifiers: HotkeyModifiers(rawValue: hotkeyModifiers),
                keyLabel: hotkeyKeyLabel
            )
        }
        set {
            hotkeyKeyCode = newValue.keyCode
            hotkeyModifiers = newValue.modifiers.rawValue
            hotkeyKeyLabel = newValue.keyLabel
        }
    }
}
