import Combine
import Sparkle

/// Updates for the direct-distribution app: a check on request, and, unless the
/// user turns it off, one a day that offers a newer version when there is one.
/// Nothing is ever installed without the user confirming it.
/// The controller lives beyond the Settings window so closing Settings cannot
/// cancel a download or installation already in progress.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController
    private var observation: AnyCancellable?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    /// Sparkle's own preference. It is stored by Sparkle in the app's defaults
    /// and starts from `SUEnableAutomaticChecks` in `Info.plist`, so a fresh
    /// install checks and a user who switched it off stays switched off.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
