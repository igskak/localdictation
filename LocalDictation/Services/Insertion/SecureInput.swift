import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// What the app can find out about system-wide secure input.
///
/// `IsSecureEventInputEnabled()` is a single process-wide bit: while it is set,
/// no application may observe or synthesize keyboard events, which is exactly
/// what protects a password field and exactly what makes dictation impossible.
/// The app refuses in that state, deliberately, and `docs/PHASE_4_COMPATIBILITY.md`
/// names the consequence as the worst failure mode in the insertion path —
/// *every* dictation everywhere is refused, and applications are known to leave
/// the flag on after a password field or when they quit with one focused.
///
/// The bit alone cannot be acted on: "an application has secure input enabled"
/// tells the user there is a problem, in a Mac full of applications, and gives
/// them nothing to do about it. So the holder is asked for by name.
struct SecureInputState: Sendable, Equatable {
    var isEnabled: Bool
    /// The name macOS shows for the application holding the flag, when the
    /// window server names one. Application identity, never window contents —
    /// the same rule `FrontmostApplication` follows.
    var holderName: String?
    var holderBundleIdentifier: String?

    init(isEnabled: Bool = false, holderName: String? = nil, holderBundleIdentifier: String? = nil) {
        self.isEnabled = isEnabled
        self.holderName = holderName
        self.holderBundleIdentifier = holderBundleIdentifier
    }

    static let off = SecureInputState()

    /// Identity for logs: a bundle identifier where there is one, and never the
    /// localized name, which is what the *user* is shown instead.
    var logIdentity: String? { holderBundleIdentifier }
}

/// Secure input behind a protocol, so a refusal is a tested behaviour rather
/// than something only reproducible by focusing a real password field.
@MainActor
protocol SecureInputSource: AnyObject {
    var secureInputState: SecureInputState { get }
}

@MainActor
final class SystemSecureInput: SecureInputSource {
    var secureInputState: SecureInputState {
        guard IsSecureEventInputEnabled() else { return .off }
        guard let pid = Self.holdingProcessIdentifier(),
              let application = NSRunningApplication(processIdentifier: pid)
        else {
            // The flag is on and nothing owns up to it. That happens — a
            // process that has exited without clearing it is one of the ways
            // this gets stuck — and the honest answer is the general sentence
            // rather than a guess at which application it was.
            return SecureInputState(isEnabled: true)
        }
        return SecureInputState(
            isEnabled: true,
            holderName: application.localizedName,
            holderBundleIdentifier: application.bundleIdentifier
        )
    }

    /// Who is holding the flag, according to the window server.
    ///
    /// `CGSessionCopyCurrentDictionary()` is public CoreGraphics and describes
    /// the login session; the secure-input owner is one of the entries it
    /// carries. The key is not a declared constant, so every step here is
    /// optional and the whole thing degrades to "somebody" rather than failing:
    /// a missing key costs the user a name, not an answer.
    private static func holdingProcessIdentifier() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        guard let number = session["kCGSSessionSecureInputPID"] as? NSNumber else { return nil }
        let pid = number.int32Value
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return pid
    }
}
