import AppKit
import Combine
import Foundation
import UserNotifications
import SwiftUI

@MainActor
protocol SpeechModelNotifications {
    func enableIfNeeded() async -> Bool
    func downloaded(_ choice: DictationEngineChoice) async throws
    func ready(_ choice: DictationEngineChoice) async throws
}

@MainActor
struct SystemSpeechModelNotifications: SpeechModelNotifications {
    func enableIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }
    func downloaded(_ choice: DictationEngineChoice) async throws {
        try await send(id: "speech-model-downloaded", title: L10n.string("Your model has downloaded"),
            body: L10n.format("%@ is downloaded. Restart Witness to apply it.", choice.title))
    }
    func ready(_ choice: DictationEngineChoice) async throws {
        try await send(id: "speech-model-ready", title: L10n.string("Witness is ready"),
            body: L10n.format("%@ is ready. You can start dictating.", choice.title))
    }
    private func send(id: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

@MainActor
final class SpeechModelSelection: ObservableObject {
    static let shared = SpeechModelSelection()
    static let pendingKey = "SpeechModelDownloadedSelection"
    static let preparationKey = "SpeechModelPreparationAfterRestart"

    @Published private(set) var installed: Set<DictationEngineChoice> = []
    @Published private(set) var pending: DictationEngineChoice?
    @Published private(set) var downloading: DictationEngineChoice?
    @Published private(set) var progress: ModelDownloadProgress?
    @Published private(set) var error: String?
    @Published private(set) var notificationsEnabled = true
    let active: DictationEngineChoice
    private let storage: any SpeechModelStorage
    private let downloader: any SpeechModelDownloading
    private let notifications: any SpeechModelNotifications
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(active: DictationEngineChoice = .active, storage: any SpeechModelStorage = LocalSpeechModelStorage.live,
         downloader: any SpeechModelDownloading = RemoteSpeechModelDownloader(),
         notifications: any SpeechModelNotifications = SystemSpeechModelNotifications(), defaults: UserDefaults = .standard) {
        self.active = active; self.storage = storage; self.downloader = downloader
        self.notifications = notifications; self.defaults = defaults
        pending = defaults.string(forKey: Self.pendingKey).flatMap(DictationEngineChoice.init(rawValue:))
        refresh()
    }

    func refresh() {
        installed = Set(DictationEngineChoice.allCases.filter(storage.isInstalled))
        if let pending, pending == active || !installed.contains(pending) {
            self.pending = nil
            defaults.removeObject(forKey: Self.pendingKey)
            if pending != active { error = ModelArtifactError.invalidFile.errorDescription }
        }
    }

    func choose(_ choice: DictationEngineChoice, profile: LanguageProfile) {
        guard downloading == nil, choice != active else { return }
        guard choice.supports(profile) else { error = L10n.string("This model does not support all your selected languages."); return }
        error = nil; progress = nil
        if storage.isInstalled(choice) {
            makePending(choice)
            Task { [weak self, notifications] in
                let enabled = await notifications.enableIfNeeded()
                self?.notificationsEnabled = enabled
            }
            return
        }
        let token = UUID(); generation = token; downloading = choice
        task = Task { [weak self, downloader, notifications] in
            let enabled = await notifications.enableIfNeeded()
            guard let self, self.generation == token else { return }
            self.notificationsEnabled = enabled
            do {
                try await downloader.download(choice) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.downloading == choice else { return }
                        if let previous = self.progress, previous.totalBytes == progress.totalBytes,
                           previous.completedBytes > progress.completedBytes { return }
                        self.progress = progress
                    }
                }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                guard self.storage.isInstalled(choice) else { throw ModelArtifactError.invalidFile }
                self.makePending(choice)
                self.downloading = nil; self.task = nil; self.progress = nil; self.refresh()
                if enabled {
                    do { try await notifications.downloaded(choice) }
                    catch { self.notificationsEnabled = false }
                }
            } catch {
                guard self.generation == token else { return }
                self.downloading = nil; self.task = nil; self.progress = nil; self.refresh()
                if !(error is CancellationError) { self.error = (error as? LocalizedError)?.errorDescription ?? L10n.string("The model could not be downloaded. Check your connection and try again.") }
            }
        }
    }

    private func makePending(_ choice: DictationEngineChoice) {
        pending = choice
        defaults.set(choice.rawValue, forKey: Self.pendingKey)
    }

    func cancelDownload() {
        generation = UUID(); task?.cancel(); task = nil; downloading = nil; progress = nil; error = nil
        refresh()
    }

    func keepCurrent() {
        if downloading != nil { cancelDownload() }
        pending = nil; defaults.removeObject(forKey: Self.pendingKey); error = nil
    }

    func remove(_ choice: DictationEngineChoice) {
        guard choice != active, choice != pending, choice != downloading else { return }
        do { try storage.remove(choice); refresh(); error = nil }
        catch { self.error = L10n.string("The model could not be removed. Please try again.") }
    }

    func restart(dictation: RecordingState, meetingIsActive: Bool, fileIsActive: Bool = false, profile: LanguageProfile) {
        guard let pending, pending.supports(profile), storage.isInstalled(pending), downloading == nil,
              DictationEngineChoice.allowsRestart(dictation: dictation, meetingIsActive: meetingIsActive, fileIsActive: fileIsActive) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"", "witness-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try process.run(); NSApp.terminate(nil) }
        catch { self.error = L10n.string("Could not restart Witness. Quit and reopen it to apply the selected model.") }
    }
}

/// Local-only preferences. An unfinished or incompatible download never replaces
/// the currently working model, including across an ordinary quit/reopen.
enum SpeechModelLaunchSelection {
    static let pendingKey = "SpeechModelDownloadedSelection"
    static let preparationKey = "SpeechModelPreparationAfterRestart"
    static func resolve(defaults: UserDefaults, storage: any SpeechModelStorage, profile: LanguageProfile) -> DictationEngineChoice {
        let previous = DictationEngineChoice.saved(in: defaults)
        guard let raw = defaults.string(forKey: pendingKey), let next = DictationEngineChoice(rawValue: raw),
              next != previous, next.supports(profile), storage.isInstalled(next) else { return previous }
        defaults.set(next.rawValue, forKey: DictationEngineChoice.defaultsKey)
        defaults.set(next.rawValue, forKey: preparationKey)
        defaults.removeObject(forKey: pendingKey)
        return next
    }
}

/// Owns a non-modal preparation popup after a model change. The marker survives
/// errors/restarts; successful preparation clears it and sends one notification.
@MainActor
final class SpeechModelPreparationController {
    private let coordinator: DictationCoordinator
    private let notifications: any SpeechModelNotifications
    private let defaults: UserDefaults
    private var observation: AnyCancellable?
    private(set) var window: NSWindow?
    private var completed = false
    private let choice: DictationEngineChoice

    init(coordinator: DictationCoordinator, choice: DictationEngineChoice = .active,
         notifications: any SpeechModelNotifications = SystemSpeechModelNotifications(), defaults: UserDefaults = .standard) {
        self.coordinator = coordinator; self.choice = choice; self.notifications = notifications; self.defaults = defaults
    }

    func start() {
        guard window == nil, observation == nil, !completed,
              defaults.string(forKey: SpeechModelLaunchSelection.preparationKey) == choice.rawValue else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 270),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L10n.string("Preparing your speech model")
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SpeechModelPreparationView(coordinator: coordinator, choice: choice))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center(); panel.orderFrontRegardless(); window = panel
        observation = coordinator.$transcriptionModelState.sink { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if state.isReady { await self.finish() }
                else if let window = self.window, let view = window.contentView {
                    view.layoutSubtreeIfNeeded()
                    window.setContentSize(view.fittingSize)
                }
            }
        }
    }

    private func finish() async {
        guard !completed else { return }
        completed = true; observation = nil; window?.close(); window = nil
        defaults.removeObject(forKey: SpeechModelLaunchSelection.preparationKey)
        try? await notifications.ready(choice)
    }
}
