import AppKit
import ApplicationServices

/// Reads only a bounded slice around the focused selection. The returned value
/// is consumed by cleanup and is never logged or persisted.
@MainActor
final class AXTextContextService: TextContextService {
    nonisolated static let beforeLimit = 64
    nonisolated static let afterLimit = 32
    // Five bounded AX reads are performed below. A per-read 25 ms timeout
    // keeps their worst-case total within the phase's 150 ms fallback cap.
    private static let messagingTimeout: Float = 0.025

    private let permissionService: any AccessibilityPermissionService
    private let frontmost: any FrontmostApplicationSource
    private let secureInput: any SecureInputSource

    init(
        permissionService: any AccessibilityPermissionService,
        frontmost: any FrontmostApplicationSource,
        secureInput: any SecureInputSource
    ) {
        self.permissionService = permissionService
        self.frontmost = frontmost
        self.secureInput = secureInput
    }

    func context(for target: InsertionTarget?) -> TextContextAvailability {
        guard permissionService.currentAuthorization.allowsInsertion,
              !secureInput.secureInputState.isEnabled,
              let target,
              let current = frontmost.frontmostApplication,
              !current.isTerminated,
              current.processIdentifier == target.processIdentifier
        else { return .unavailable }

        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
        guard let focusedValue = copy(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return .unavailable }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        let subrole = copy(focused, kAXSubroleAttribute) as? String
        guard subrole != (kAXSecureTextFieldSubrole as String),
              !(subrole?.localizedCaseInsensitiveContains("secure") ?? false),
              let value = copy(focused, kAXValueAttribute) as? String,
              let range = selectedRange(of: focused)
        else { return .unavailable }

        let nsValue = value as NSString
        guard range.location >= 0, range.length >= 0, range.location + range.length <= nsValue.length else {
            return .unavailable
        }
        let windows = Self.boundedWindows(value: value, selection: NSRange(location: range.location, length: range.length))
        let role = copy(focused, kAXRoleAttribute) as? String
        return .available(
            DictationTextContext(
                category: .classify(bundleIdentifier: target.bundleIdentifier),
                fieldRole: role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) ? .editableText : .other,
                textBeforeCaret: windows.before,
                textAfterCaret: windows.after,
                hasSelection: range.length > 0
            )
        )
    }

    nonisolated static func boundedWindows(value: String, selection: NSRange) -> (before: String, after: String) {
        let text = value as NSString
        let location = min(max(selection.location, 0), text.length)
        let selectionEnd = min(max(NSMaxRange(selection), location), text.length)
        let beforeStart = max(0, location - beforeLimit)
        let afterEnd = min(text.length, selectionEnd + afterLimit)
        return (
            text.substring(with: NSRange(location: beforeStart, length: location - beforeStart)),
            text.substring(with: NSRange(location: selectionEnd, length: afterEnd - selectionEnd))
        )
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let value = copy(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

