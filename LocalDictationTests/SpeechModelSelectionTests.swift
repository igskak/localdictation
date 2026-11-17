import CryptoKit
import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import Witness

private final class ModelStorageFixture: SpeechModelStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<DictationEngineChoice> = [.whisper]
    private(set) var removed: [DictationEngineChoice] = []
    func isInstalled(_ choice: DictationEngineChoice) -> Bool { lock.withLock { values.contains(choice) } }
    func install(_ choice: DictationEngineChoice) { lock.withLock { _ = values.insert(choice) } }
    func remove(_ choice: DictationEngineChoice) { lock.withLock { values.remove(choice); removed.append(choice) } }
}

private actor ModelDownloadFixture: SpeechModelDownloading {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var callback: (@Sendable (ModelDownloadProgress) -> Void)?
    private var choice: DictationEngineChoice?
    let storage: ModelStorageFixture
    var started: Bool { continuation != nil }
    init(storage: ModelStorageFixture) { self.storage = storage }
    func download(_ choice: DictationEngineChoice, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        self.choice = choice; callback = progress
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func report(_ bytes: Int64) { callback?(ModelDownloadProgress(completedBytes: bytes, totalBytes: 100)) }
    func reportBytes(_ bytes: Int64, total: Int64) { callback?(ModelDownloadProgress(completedBytes: bytes, totalBytes: total)) }
    func finish() {
        if let choice { storage.install(choice) }
        continuation?.resume(); continuation = nil
    }
    func fail() { continuation?.resume(throwing: ModelArtifactError.transferFailed); continuation = nil }
}

@MainActor
private final class ModelNotificationsFixture: SpeechModelNotifications {
    var allowed = true
    var downloadedModels: [DictationEngineChoice] = []
    var readyModels: [DictationEngineChoice] = []
    func enableIfNeeded() -> Bool { allowed }
    func downloaded(_ choice: DictationEngineChoice) { downloadedModels.append(choice) }
    func ready(_ choice: DictationEngineChoice) { readyModels.append(choice) }
}

@MainActor
final class SpeechModelSelectionTests: XCTestCase {
    private func preferences() throws -> UserDefaults {
        let suite = "SpeechModelSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DictationEngineChoice.whisper.rawValue, forKey: DictationEngineChoice.defaultsKey)
        return defaults
    }
    private let profile = LanguageProfile(.english, .russian, .ukrainian)

    func testDownloadKeepsWorkingModelAndCommitsOnlyAfterSuccess() async throws {
        let defaults = try preferences(), storage = ModelStorageFixture()
        let downloader = ModelDownloadFixture(storage: storage), notifications = ModelNotificationsFixture()
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: downloader, notifications: notifications, defaults: defaults)
        selection.choose(.parakeetUltra, profile: profile)
        while !(await downloader.started) { await Task.yield() }
        await downloader.report(40)
        try await waitUntil("download progress") { selection.progress?.percent == 40 }
        await downloader.report(20)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(selection.progress?.percent, 40)
        XCTAssertEqual(selection.active, .whisper)
        XCTAssertEqual(DictationEngineChoice.saved(in: defaults), .whisper)
        XCTAssertNil(selection.pending)
        await downloader.finish()
        try await waitUntil("download ready") { selection.pending == .parakeetUltra && selection.downloading == nil }
        XCTAssertEqual(notifications.downloadedModels, [.parakeetUltra])
        XCTAssertEqual(DictationEngineChoice.saved(in: defaults), .whisper)
        XCTAssertEqual(defaults.string(forKey: SpeechModelSelection.pendingKey), "parakeet-ultra")
    }

    func testCancellationIgnoresLateProgressAndCompletion() async throws {
        let storage = ModelStorageFixture(), downloader = ModelDownloadFixture(storage: ModelStorageFixture())
        let defaults = try preferences()
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: downloader, notifications: ModelNotificationsFixture(), defaults: defaults)
        selection.choose(.whisperLarge, profile: profile)
        while !(await downloader.started) { await Task.yield() }
        selection.cancelDownload()
        await downloader.report(90); await downloader.finish()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(selection.pending); XCTAssertNil(selection.progress); XCTAssertNil(selection.error)
        XCTAssertNil(defaults.string(forKey: SpeechModelSelection.pendingKey))
        XCTAssertEqual(DictationEngineChoice.saved(in: defaults), .whisper)
    }

    func testKeepingCurrentDuringDownloadDoesNotStageLateCompletion() async throws {
        let storage = ModelStorageFixture(), defaults = try preferences()
        let downloader = ModelDownloadFixture(storage: storage)
        let notifications = ModelNotificationsFixture()
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: downloader,
            notifications: notifications, defaults: defaults)
        selection.choose(.parakeetUltra, profile: profile)
        while !(await downloader.started) { await Task.yield() }
        selection.keepCurrent()
        XCTAssertNil(selection.downloading)
        await downloader.finish()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(selection.pending)
        XCTAssertTrue(notifications.downloadedModels.isEmpty)
        XCTAssertNil(defaults.string(forKey: SpeechModelSelection.pendingKey))
        XCTAssertEqual(DictationEngineChoice.saved(in: defaults), .whisper)
    }

    func testFailureCanBeRetriedAndDoesNotChangeActiveModel() async throws {
        let storage = ModelStorageFixture(), defaults = try preferences()
        let downloader = ModelDownloadFixture(storage: storage), notifications = ModelNotificationsFixture()
        notifications.allowed = false
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: downloader, notifications: notifications, defaults: defaults)
        selection.choose(.whisperLarge, profile: profile)
        while !(await downloader.started) { await Task.yield() }
        await downloader.fail()
        try await waitUntil("download error") { selection.error != nil }
        XCTAssertEqual(selection.active, .whisper); XCTAssertNil(selection.pending)
        selection.choose(.whisperLarge, profile: profile)
        while !(await downloader.started) { await Task.yield() }
        await downloader.finish()
        try await waitUntil("retry succeeded") { selection.pending == .whisperLarge }
        XCTAssertFalse(selection.notificationsEnabled)
        XCTAssertTrue(notifications.downloadedModels.isEmpty)
    }

    func testInstalledModelNeedsNoDownloadAndCanBeUnselected() throws {
        let storage = ModelStorageFixture(), defaults = try preferences()
        storage.install(.parakeetUltra)
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: ModelDownloadFixture(storage: storage), notifications: ModelNotificationsFixture(), defaults: defaults)
        selection.choose(.parakeetUltra, profile: profile)
        XCTAssertEqual(selection.pending, .parakeetUltra); XCTAssertNil(selection.downloading)
        selection.keepCurrent()
        XCTAssertNil(selection.pending); XCTAssertNil(defaults.string(forKey: SpeechModelSelection.pendingKey))
    }

    func testActivePendingAndDownloadingModelsCannotBeDeleted() async throws {
        let storage = ModelStorageFixture(), defaults = try preferences()
        storage.install(.whisperLarge); storage.install(.parakeetUltra)
        let downloader = ModelDownloadFixture(storage: storage)
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: downloader, notifications: ModelNotificationsFixture(), defaults: defaults)
        selection.choose(.whisperLarge, profile: profile)
        selection.remove(.whisper); selection.remove(.whisperLarge)
        selection.choose(.parakeetV3, profile: profile)
        while !(await downloader.started) { await Task.yield() }
        selection.remove(.parakeetV3)
        selection.remove(.parakeetUltra)
        XCTAssertEqual(storage.removed, [.parakeetUltra])
        selection.cancelDownload(); await downloader.finish()
    }

    func testMissingPendingFilesDoNotOfferANonworkingRestart() throws {
        let storage = ModelStorageFixture(), defaults = try preferences()
        defaults.set("whisper-large-v3", forKey: SpeechModelSelection.pendingKey)
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: ModelDownloadFixture(storage: storage), notifications: ModelNotificationsFixture(), defaults: defaults)
        XCTAssertNil(selection.pending)
        XCTAssertNotNil(selection.error)
        XCTAssertNil(defaults.string(forKey: SpeechModelSelection.pendingKey))
        XCTAssertEqual(DictationEngineChoice.saved(in: defaults), .whisper)
    }

    func testUnsupportedLanguageCannotStartDownload() throws {
        let storage = ModelStorageFixture()
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: ModelDownloadFixture(storage: storage), notifications: ModelNotificationsFixture(), defaults: try preferences())
        selection.choose(.parakeetUltra, profile: LanguageProfile(SpeechLanguage(rawValue: "ja")!))
        XCTAssertNotNil(selection.error); XCTAssertNil(selection.downloading); XCTAssertNil(selection.pending)
    }

    func testExportModelSelectionStates() async throws {
        let folder = URL(fileURLWithPath: "/tmp/witness-model-selection-preview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = ModelStorageFixture(), defaults = try preferences()
        let downloader = ModelDownloadFixture(storage: storage), notifications = ModelNotificationsFixture()
        let selection = SpeechModelSelection(active: .whisper, storage: storage, downloader: downloader, notifications: notifications, defaults: defaults)
        let engine = FakeTranscriptionService()
        let coordinator = DictationCoordinator(permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(), captureService: FakeAudioCaptureService(), transcriptionService: engine,
            preferencesStore: InMemoryPreferencesStore())
        func snapshot(_ name: String, _ view: some View, size: NSSize = NSSize(width: 900, height: 700)) async throws {
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            for _ in 0..<3 { await Task.yield() }
            hosting.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(hosting.fittingSize.width, size.width + 1, name)
            XCTAssertLessThanOrEqual(hosting.fittingSize.height, size.height + 1, name)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
            window.close()
        }
        func settings(_ scheme: ColorScheme = .light) -> some View {
            SettingsView(initialSelection: .speechModel, updater: AppUpdater(startingUpdater: false), modelSelection: selection)
                .environmentObject(coordinator).environment(\.colorScheme, scheme)
        }
        try await snapshot("01-models-light", settings())
        try await snapshot("02-models-dark", settings(.dark))
        selection.choose(.parakeetUltra, profile: profile)
        while !(await downloader.started) { await Task.yield() }
        await downloader.reportBytes(265_572_090, total: 632_314_500)
        try await waitUntil("preview progress") { selection.progress?.percent == 42 }
        try await snapshot("03-downloading", settings())
        await downloader.fail()
        try await waitUntil("preview failure") { selection.error != nil }
        try await snapshot("04-download-error", settings())
        selection.choose(.parakeetUltra, profile: profile)
        while !(await downloader.started) { await Task.yield() }
        await downloader.finish()
        try await waitUntil("preview ready") { selection.pending != nil }
        try await snapshot("05-restart-ready", settings())
        for locale in ["de", "es", "it", "fr"] {
            try await snapshot("06-ready-" + locale, settings().environment(\.locale, Locale(identifier: locale)))
        }
        engine.setModelState(.ready)
        await coordinator.refreshTranscriptionModelState()
        let onboarding = LanguageSetupModel(selection: profile)
        onboarding.page = 6
        try await snapshot("07-onboarding-models", GuidedSetupView(modelSelection: selection, model: onboarding, coordinator: coordinator,
            notifyWhenReady: {}, finish: {}).environmentObject(coordinator), size: NSSize(width: 520, height: 620))
        engine.setModelState(.preparing(ModelPreparation(phase: .compilingForThisSystem)))
        await coordinator.refreshTranscriptionModelState()
        try await snapshot("08-preparing", SpeechModelPreparationView(coordinator: coordinator, choice: .parakeetUltra), size: NSSize(width: 440, height: 340))
        coordinator.deactivate()
    }

    func testPreparationPopupClosesAndNotifiesExactlyOnceWhenReady() async throws {
        let defaults = try preferences()
        defaults.set("whisper", forKey: SpeechModelLaunchSelection.preparationKey)
        let engine = FakeTranscriptionService()
        engine.setModelState(.preparing(ModelPreparation(phase: .compilingForThisSystem)))
        let coordinator = DictationCoordinator(permissionService: FakeMicrophonePermissionService(authorization: .authorized),
            hotkeyService: FakeHotkeyService(), captureService: FakeAudioCaptureService(), transcriptionService: engine,
            preferencesStore: InMemoryPreferencesStore())
        await coordinator.refreshTranscriptionModelState()
        let notifications = ModelNotificationsFixture()
        let presenter = SpeechModelPreparationController(coordinator: coordinator, choice: .whisper, notifications: notifications, defaults: defaults)
        presenter.start()
        let firstWindow = presenter.window
        presenter.start()
        XCTAssertTrue(presenter.window === firstWindow)
        XCTAssertNotNil(presenter.window)
        engine.setModelState(.failed("Test failure"))
        await coordinator.refreshTranscriptionModelState()
        XCTAssertNotNil(presenter.window)
        XCTAssertNotNil(defaults.string(forKey: SpeechModelLaunchSelection.preparationKey))
        engine.setModelState(.ready)
        await coordinator.refreshTranscriptionModelState()
        try await waitUntil("preparation finished") { presenter.window == nil && notifications.readyModels.count == 1 }
        await coordinator.refreshTranscriptionModelState()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(notifications.readyModels, [.whisper])
        XCTAssertNil(defaults.string(forKey: SpeechModelLaunchSelection.preparationKey))
    }

    func testLaunchAppliesOnlyCompletedCompatibleSelectionAndMarksPreparation() throws {
        let storage = ModelStorageFixture(), defaults = try preferences()
        defaults.set("parakeet-ultra", forKey: SpeechModelLaunchSelection.pendingKey)
        XCTAssertEqual(SpeechModelLaunchSelection.resolve(defaults: defaults, storage: storage, profile: profile), .whisper)
        storage.install(.parakeetUltra)
        XCTAssertEqual(SpeechModelLaunchSelection.resolve(defaults: defaults, storage: storage, profile: LanguageProfile(SpeechLanguage(rawValue: "ja")!)), .whisper)
        XCTAssertEqual(SpeechModelLaunchSelection.resolve(defaults: defaults, storage: storage, profile: profile), .parakeetUltra)
        XCTAssertNil(defaults.string(forKey: SpeechModelLaunchSelection.pendingKey))
        XCTAssertEqual(defaults.string(forKey: SpeechModelLaunchSelection.preparationKey), "parakeet-ultra")
        XCTAssertEqual(SpeechModelLaunchSelection.resolve(defaults: defaults, storage: storage, profile: profile), .parakeetUltra)
    }
}

private actor ModelTransportFixture: SpeechModelTransport {
    let data: Data
    let corrupt: Bool
    private(set) var requests = 0
    init(data: Data, corrupt: Bool = false) { self.data = data; self.corrupt = corrupt }
    func manifest(at url: URL) -> Data { data }
    func file(at url: URL, progress: @escaping @Sendable (Int64) -> Void) throws -> URL {
        requests += 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data((corrupt ? "bad" : "abc").utf8).write(to: url)
        progress(1); progress(3)
        return url
    }
}

final class SpeechModelArtifactTests: XCTestCase {
    private func manifest(_ choice: DictationEngineChoice, extra: [[String: Any]] = []) throws -> Data {
        let hash = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        let names = choice.modelBundles.flatMap { [$0 + "/model.mil", $0 + "/coremldata.bin", $0 + "/weights/weight.bin"] }
            + ["config.json", "parakeet_v3_vocab.json"]
        return try JSONSerialization.data(withJSONObject: names.map {
            ["type": "file", "path": choice.artifactPrefix + $0, "size": 3, "lfs": ["oid": hash, "size": 3]] as [String: Any]
        } + extra)
    }
    func testPinnedManifestsAndSmallTransferWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["WITNESS_MODEL_DOWNLOAD_HTTP_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in static model metadata and tiny-file HTTP test")
        }
        let transport = URLSessionSpeechModelTransport()
        for choice in DictationEngineChoice.allCases {
            let url = URL(string: "https://huggingface.co/api/models/\(choice.artifactRepository)/tree/\(choice.artifactRevision)/\(choice.artifactPrefix)?recursive=true")!
            let files = try RemoteSpeechModelDownloader.files(in: await transport.manifest(at: url), for: choice)
            XCTAssertEqual(files.reduce(Int64(0)) { $0 + $1.size }, choice.approximateBytes)
            let config = try XCTUnwrap(files.first { $0.relativePath == "config.json" })
            let remote = URL(string: "https://huggingface.co/\(choice.artifactRepository)/resolve/\(choice.artifactRevision)/\(config.remotePath)")!
            let temporary = try await transport.file(at: remote) { _ in }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let data = try Data(contentsOf: temporary)
            XCTAssertEqual(Int64(data.count), config.size)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    func testManifestRefusesTraversalDuplicatesAndMissingFiles() throws {
        let choice = DictationEngineChoice.parakeetUltra
        XCTAssertThrowsError(try RemoteSpeechModelDownloader.files(in: manifest(choice, extra: [["type": "file", "path": "../outside", "size": 3]]), for: choice))
        XCTAssertThrowsError(try RemoteSpeechModelDownloader.files(in: manifest(choice, extra: [["type": "file", "path": "config.json", "size": 3]]), for: choice))
        XCTAssertThrowsError(try RemoteSpeechModelDownloader.files(in: Data("[]".utf8), for: choice))
        XCTAssertEqual(try RemoteSpeechModelDownloader.files(in: manifest(choice), for: choice).count, 14)
    }
    func testDownloadChecksEveryFileAndReusesCompletedFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = LocalSpeechModelStorage(base: base), choice = DictationEngineChoice.parakeetUltra
        let transport = ModelTransportFixture(data: try manifest(choice))
        let downloader = RemoteSpeechModelDownloader(storage: storage, transport: transport, availableBytes: { _ in Int64.max })
        try await downloader.download(choice) { _ in }
        XCTAssertTrue(storage.isInstalled(choice))
        try await downloader.download(choice) { _ in }
        let count = await transport.requests
        XCTAssertEqual(count, 14)
    }
    func testCorruptFileCannotBeInstalled() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = LocalSpeechModelStorage(base: base), choice = DictationEngineChoice.parakeetUltra
        let downloader = RemoteSpeechModelDownloader(storage: storage, transport: ModelTransportFixture(data: try manifest(choice), corrupt: true), availableBytes: { _ in Int64.max })
        do { try await downloader.download(choice) { _ in }; XCTFail("Corrupted content accepted") }
        catch { XCTAssertTrue(error is ModelArtifactError) }
        XCTAssertFalse(storage.isInstalled(choice))
    }
    func testLowDiskSpaceStopsBeforeDownloadingFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let choice = DictationEngineChoice.parakeetUltra
        let transport = ModelTransportFixture(data: try manifest(choice))
        let downloader = RemoteSpeechModelDownloader(storage: LocalSpeechModelStorage(base: base), transport: transport, availableBytes: { _ in 0 })
        do { try await downloader.download(choice) { _ in }; XCTFail("No disk space check") }
        catch { XCTAssertTrue(error is ModelArtifactError) }
        let count = await transport.requests
        XCTAssertEqual(count, 0)
    }
}
