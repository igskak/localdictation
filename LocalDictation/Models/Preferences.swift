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
        case .pushToTalk: "Hold to talk"
        case .toggle: "Press to start and stop"
        }
    }

    var explanation: String {
        switch self {
        case .pushToTalk:
            "The microphone is open only while the key is down. Best for a sentence at a time."
        case .toggle:
            "One press starts, the next finishes. Best for anything longer than a key is comfortable to hold."
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

    static let `default` = Preferences(
        hotkeyKeyCode: HotkeyBinding.optionSpace.keyCode,
        hotkeyModifiers: HotkeyBinding.optionSpace.modifiers.rawValue,
        hotkeyKeyLabel: HotkeyBinding.optionSpace.keyLabel,
        activation: .pushToTalk,
        languageProfile: .default,
        insertsAutomatically: true,
        hasChosenLanguages: false
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
    }

    init(
        hotkeyKeyCode: UInt32,
        hotkeyModifiers: UInt32,
        hotkeyKeyLabel: String,
        activation: RecordingActivation,
        languageProfile: LanguageProfile,
        insertsAutomatically: Bool,
        hasChosenLanguages: Bool
    ) {
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.hotkeyKeyLabel = hotkeyKeyLabel
        self.activation = activation
        self.languageProfile = languageProfile
        self.insertsAutomatically = insertsAutomatically
        self.hasChosenLanguages = hasChosenLanguages
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
