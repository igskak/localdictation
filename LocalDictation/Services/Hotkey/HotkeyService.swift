import Foundation

struct HotkeyModifiers: OptionSet, Sendable, Equatable, Hashable {
    let rawValue: UInt32

    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let command = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let control = HotkeyModifiers(rawValue: 1 << 2)
    static let shift = HotkeyModifiers(rawValue: 1 << 3)

    var displayString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

/// A push-to-talk binding. `keyCode` is a virtual key code (`kVK_*`).
struct HotkeyBinding: Sendable, Equatable {
    var keyCode: UInt32
    var modifiers: HotkeyModifiers
    var keyLabel: String

    /// Phase 1 default: push-to-talk on Option + Space.
    static let optionSpace = HotkeyBinding(keyCode: 49, modifiers: .option, keyLabel: "Space")

    var isSingleModifier: Bool { modifiers.isEmpty && [54,55,56,58,59,60,61,62,63].contains(keyCode & 0xFFFF) }
    var displayString: String { "\(modifiers.displayString)\(isSingleModifier ? L10n.string(keyLabel) : keyLabel)" }
    static func single(_ code: UInt32, _ label: String) -> Self {
        Self(keyCode: code, modifiers: [], keyLabel: label)
    }
}

enum HotkeyEvent: String, Sendable, Equatable {
    case pressed
    case released
    case cancelled
    case unavailable
}

enum HotkeyRegistrationError: Error, Sendable, Equatable {
    /// Another application or the system already owns this combination.
    case alreadyInUse
    /// A combination with no modifier in it. Registering one takes a bare key
    /// away from every application on the Mac, including this app's own text
    /// fields, so it is refused before it reaches the system rather than after.
    case noModifier
    case keyboardAccessRequired
    case handlerInstallationFailed(status: Int32)
    case registrationFailed(status: Int32)

    var message: String {
        switch self {
        case .keyboardAccessRequired:
            L10n.string("allow Input Monitoring in System Settings, then try again")
        case .alreadyInUse:
            L10n.string("the shortcut is already used by macOS or another app")
        case .noModifier:
            L10n.string("a shortcut needs at least one of ⌘ ⌥ ⌃ ⇧, or it would take that key away from every app")
        case let .handlerInstallationFailed(status):
            L10n.format("the event handler could not be installed (OSStatus %d)", status)
        case let .registrationFailed(status):
            L10n.format("registration failed (OSStatus %d)", status)
        }
    }
}

/// Global hotkey boundary. Implementations must register and unregister
/// deterministically and report collisions instead of failing silently.
protocol HotkeyService: AnyObject, Sendable {
    var registeredBinding: HotkeyBinding? { get }
    func register(_ binding: HotkeyBinding, handler: @escaping @Sendable (HotkeyEvent) -> Void) throws
    func unregister()
    func setActivation(_ activation: RecordingActivation)
}

extension HotkeyService {
    func setActivation(_ activation: RecordingActivation) {}
}

/// The pure part of modifier detection; system adapters supply physical key state.
struct ModifierKeyGesture: Sendable {
    private(set) var held = false
    private(set) var invalid = false
    private(set) var started = false
    mutating func begin(clean: Bool) { held = true; invalid = !clean; started = false }
    mutating func activate() -> Bool {
        guard held, !invalid, !started else { return false }
        started = true
        return true
    }
    mutating func interfere() -> Bool {
        guard held else { return false }
        invalid = true
        let cancel = started
        started = false
        return cancel
    }
    mutating func reset() { self = Self() }
}
