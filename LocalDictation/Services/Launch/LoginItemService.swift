import AppKit
import ServiceManagement

/// Whether the app starts itself when the user logs in.
///
/// Table stakes for a menu bar utility: an app with no Dock icon and no window
/// is one the user has no habit of launching, so an app that is not running is
/// an app whose hotkey does nothing. That reads as the shortcut being broken
/// rather than as the app being closed.
///
/// Four states rather than a boolean, because macOS has four answers and three
/// of them need different sentences. `requiresApproval` in particular is the
/// one that cannot be fixed from inside the app: the user switched the app off
/// under Login Items, and only they can switch it back on.
enum LoginItemState: Sendable, Equatable {
    case enabled
    case disabled
    /// Registered, then switched off by the user in System Settings. macOS will
    /// not let the app undo that, and it should not.
    case requiresApproval
    /// The registration could not be made or read. Carries the reason, because
    /// the most common one is specific and worth saying out loud: a build run
    /// from Xcode is not in `/Applications`, and macOS refuses to make a login
    /// item out of it.
    case unavailable(String)

    var isEnabled: Bool { self == .enabled }

    var explanation: String? {
        switch self {
        case .enabled, .disabled:
            nil
        case .requiresApproval:
            "macOS is holding this off. Open Login Items in System Settings and allow Witness there."
        case let .unavailable(reason):
            reason
        }
    }
}

@MainActor
protocol LoginItemService: AnyObject {
    var state: LoginItemState { get }
    /// Returns the state afterwards rather than throwing: every outcome here is
    /// something to show, including the refusals.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> LoginItemState
    func openSystemSettings()
}

@MainActor
final class SMAppServiceLoginItem: LoginItemService {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var state: LoginItemState { Self.state(for: service.status) }

    /// The pure half, so the mapping is testable without registering anything
    /// on the machine running the tests.
    static func state(for status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled:
            .enabled
        case .notRegistered:
            .disabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable("macOS cannot find this copy of the app to start it. Move Witness to your Applications folder and try again.")
        @unknown default:
            .unavailable("macOS gave an answer this app does not recognize.")
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LoginItemState {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            Log.application.info("Open at login set to \(enabled, privacy: .public)")
        } catch {
            // A development build is the usual answer and deserves its own
            // sentence: macOS will not make a login item out of an app running
            // from DerivedData, and "operation not permitted" on its own sends
            // people looking for a permission that does not exist.
            let reason = """
            macOS refused: \(error.localizedDescription) \
            A build running from Xcode cannot open at login — move LocalDictation to your \
            Applications folder and open it from there.
            """
            Log.application.error("Open at login failed: \(error.localizedDescription, privacy: .public)")
            return .unavailable(reason)
        }
        return state
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Watches the login-item state for a view.
///
/// Owned by the settings window rather than by `DictationCoordinator`: whether
/// the app opens at login has nothing to do with a dictation, and the
/// coordinator is already the state owner for everything that does.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var state: LoginItemState

    private let service: any LoginItemService

    init(service: any LoginItemService = SMAppServiceLoginItem()) {
        self.service = service
        state = service.state
    }

    func refresh() {
        state = service.state
    }

    func setEnabled(_ enabled: Bool) {
        state = service.setEnabled(enabled)
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
