import AVFoundation
import AppKit

/// AVFoundation-backed authorization. Initialization only reads state, so
/// creating this service cannot trigger a system dialog.
final class AVCaptureMicrophonePermissionService: MicrophonePermissionService {
    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )

    var currentAuthorization: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .authorized
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .denied
        }
    }

    func requestAccess() async -> MicrophoneAuthorization {
        guard currentAuthorization.isRequestable else { return currentAuthorization }
        Log.permissions.info("Requesting microphone access after explicit user action")
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        let resolved = currentAuthorization
        Log.permissions.info("Microphone authorization resolved: \(resolved.rawValue, privacy: .public)")
        return resolved
    }

    @MainActor
    func openSystemSettings() {
        guard let url = Self.privacySettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
