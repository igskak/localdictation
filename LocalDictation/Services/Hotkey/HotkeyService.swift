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

    var displayString: String { "\(modifiers.displayString)\(keyLabel)" }
}

enum HotkeyEvent: String, Sendable, Equatable {
    case pressed
    case released
}

enum HotkeyRegistrationError: Error, Sendable, Equatable {
    /// Another application or the system already owns this combination.
    case alreadyInUse
    case handlerInstallationFailed(status: Int32)
    case registrationFailed(status: Int32)

    var message: String {
        switch self {
        case .alreadyInUse:
            "the shortcut is already used by macOS or another app"
        case let .handlerInstallationFailed(status):
            "the event handler could not be installed (OSStatus \(status))"
        case let .registrationFailed(status):
            "registration failed (OSStatus \(status))"
        }
    }
}

/// Global hotkey boundary. Implementations must register and unregister
/// deterministically and report collisions instead of failing silently.
protocol HotkeyService: AnyObject, Sendable {
    var registeredBinding: HotkeyBinding? { get }
    func register(_ binding: HotkeyBinding, handler: @escaping @Sendable (HotkeyEvent) -> Void) throws
    func unregister()
}
