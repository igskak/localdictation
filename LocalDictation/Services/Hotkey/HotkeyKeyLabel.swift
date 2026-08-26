import AppKit
import Carbon.HIToolbox
import Foundation

/// What to call a key on screen.
///
/// A `HotkeyBinding` carries its own label because the alternative is deriving
/// one at display time, and there is no cheap derivation that is right: a
/// virtual key code names a *position* on the keyboard, so key 12 is `Q` on
/// QWERTY, `A` on AZERTY, and `'` on Dvorak. The label is therefore taken from
/// the event that recorded the binding, where the system has already applied
/// the user's own layout, and stored with it.
///
/// This table covers what an event cannot answer for: keys that produce no
/// character, or produce an unprintable one. Everything else comes from
/// `charactersIgnoringModifiers`.
enum HotkeyKeyLabel {
    private static let named: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Return): "Return",
        UInt16(kVK_ANSI_KeypadEnter): "Enter",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Escape): "Escape",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_ForwardDelete): "Forward Delete",
        UInt16(kVK_Help): "Help",
        UInt16(kVK_Home): "Home",
        UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up",
        UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1",
        UInt16(kVK_F2): "F2",
        UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7",
        UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11",
        UInt16(kVK_F12): "F12",
    ]

    /// The label for a key, given what the system said the key produces.
    ///
    /// Falls back to the key code rather than to an empty string: a binding
    /// that displays as nothing is one the user cannot tell from an unset one.
    static func label(forKeyCode keyCode: UInt16, characters: String?) -> String {
        if let named = named[keyCode] { return named }
        guard let characters, let first = characters.first else { return "Key \(keyCode)" }
        // Control characters and other unprintables reach here for keys the
        // table does not name; showing one would put a glyph nobody recognizes
        // in the middle of a shortcut.
        guard let scalar = first.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else {
            return "Key \(keyCode)"
        }
        return String(first).uppercased()
    }
}

extension HotkeyModifiers {
    /// The modifiers macOS reports on an event, reduced to the four that can
    /// take part in a global shortcut.
    ///
    /// Caps Lock, Fn, and the numeric-keypad flag are dropped rather than
    /// carried: `RegisterEventHotKey` does not take them, so keeping them would
    /// mean storing a binding that can never be registered.
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
