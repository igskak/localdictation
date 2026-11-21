import Combine
import Sparkle

/// Updates for the direct-distribution app: a check on request, and, unless the
/// user turns it off, one a day that offers a newer version when there is one.
/// Nothing is ever installed without the user confirming it.
/// The controller lives beyond the Settings window so closing Settings cannot
/// cancel a download or installation already in progress.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater(startingUpdater: true)

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isWaitingToRestart = false
    private var controller: SPUStandardUpdaterController!
    private var observation: AnyCancellable?
    private let mayRestart: @MainActor () -> Bool
    private var pendingInstallation: Task<Void, Never>?

    /// Layout previews and tests can construct the adapter without starting
    /// Sparkle's scheduler or making an update request.
    init(startingUpdater: Bool, mayRestart: @escaping @MainActor () -> Bool = {
        DictationEngineChoice.allowsRestart(dictation: AppDelegate.coordinator?.state ?? .launching,
            meetingIsActive: AppDelegate.notetaker?.status.isActive ?? false,
            fileIsActive: AppDelegate.coordinator?.isFileTranscriptionRunning ?? false)
    }) {
        self.mayRestart = mayRestart
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
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

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunchIfNeeded(installHandler)
    }

    /// A confirmed installation may finish downloading while a meeting starts.
    /// Recheck at Sparkle's relaunch boundary, not only at the Settings button.
    func postponeRelaunchIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard !mayRestart() else { return false }
        pendingInstallation?.cancel()
        isWaitingToRestart = true
        pendingInstallation = Task { [weak self] in
            while let self, !self.mayRestart() {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.isWaitingToRestart = false
            self.pendingInstallation = nil
            installHandler()
        }
        return true
    }

    func cancelPendingInstallation() {
        pendingInstallation?.cancel()
        pendingInstallation = nil
        isWaitingToRestart = false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        cancelPendingInstallation()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
