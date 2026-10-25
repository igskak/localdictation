import AppKit
import Combine
import Foundation

/// What the file feature needs from the rest of the app, kept narrow so tests
/// run it without a dictation coordinator, an entitlement service or a window.
@MainActor
protocol FileTranscriptionHost: AnyObject {
    var sharedEngine: (any TranscriptionService)? { get }
    var languageProfile: LanguageProfile { get }
    /// A dictation is being recorded or is still being recognised.
    var isDictationBusy: Bool { get }
    /// The Mac is locked and may not use the product until it is licensed.
    var isLocked: Bool { get }
    var isMeetingActive: Bool { get }
    func showPaywall()
    func setFileRunning(_ running: Bool)
    /// A file produced text: the same moment a first dictation would count.
    func noteFileProducedText()
    func report(_ event: TelemetryEvent)
}

extension DictationCoordinator: FileTranscriptionHost {
    var sharedEngine: (any TranscriptionService)? { sharedTranscriptionService }
    var isLocked: Bool { isLockedForFileTranscription }
    var isMeetingActive: Bool { false }
    func showPaywall() { requestPaywallForFileTranscription() }
    func setFileRunning(_ running: Bool) { setFileTranscriptionRunning(running) }
    func noteFileProducedText() { noteFileTranscriptionProduced() }
    func report(_ event: TelemetryEvent) { reportFileTranscription(event) }
}

/// What the menu bar item observes, so the person who closed the window can
/// still see that Witness is busy with a file. Exists whether or not the
/// feature does, which keeps the app's scene free of optionals.
@MainActor
final class FileTranscriptionStatus: ObservableObject {
    @Published fileprivate(set) var isRunning = false

    var systemImage: String? { isRunning ? "waveform.badge.magnifyingglass" : nil }
    var accessibilityLabel: String? { isRunning ? L10n.string("Witness is transcribing a file") : nil }
}

/// The model step a run is waiting on, with the moment it was first seen.
struct FileModelWait: Equatable {
    let preparation: ModelPreparation
    let since: Date

    /// What the person reads. The phases that count bytes say how far they are;
    /// the compilation, which Core ML does not measure, says how long it has
    /// been seen to take instead of inventing a percentage.
    var message: String {
        switch preparation.phase {
        case .downloading, .loading:
            TranscriptionModelState.preparing(preparation).label
        case .compilingForThisSystem:
            L10n.string("macOS is preparing the speech model for this Mac. This happens once per macOS version and takes several minutes, on some Macs a quarter of an hour or more. macOS does not say how far it has got, so there is no percentage; the clock shows that it is still running. You can cancel and come back to it.")
        }
    }

    /// Only a download is counted in something, so only it gets a bar.
    var fraction: Double? { preparation.phase == .downloading ? preparation.progress : nil }
}

enum FileTranscriptionPhase: Equatable {
    case idle
    case running(fileName: String, progress: FileTranscriptionProgress?)
    case failed(FileTranscriptionFailure)
}

/// One file at a time: choose, run, open the note. Nothing here sees the audio
/// or the words; it holds a name, a fraction and a closed set of failures.
@MainActor
final class FileTranscriptionCoordinator: ObservableObject {
    static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "mp4", "mov"]

    /// While the model is being made ready for this run: what the engine says it
    /// is doing and since when. Nil once the first passage has been recognised,
    /// and whenever the model was already there.
    @Published private(set) var modelWait: FileModelWait?
    @Published private(set) var phase: FileTranscriptionPhase = .idle {
        didSet { status.isRunning = isRunning }
    }

    private weak var host: (any FileTranscriptionHost)?
    private let store: any MeetingStoring
    private let makeSource: (URL) -> any AudioFileReading
    private let makeDiarizer: () -> (any StreamingSpeakerDiarizationService)?
    private let status: FileTranscriptionStatus
    /// Set by the feature once the windows exist.
    var openResult: (UUID) -> Void
    var showWindow: () -> Void
    private var task: Task<Void, Never>?
    private var waitPolling: Task<Void, Never>?
    private var session: FileTranscriptionSession?

    init(
        host: any FileTranscriptionHost,
        store: any MeetingStoring = FileMeetingStore(),
        makeSource: @escaping (URL) -> any AudioFileReading = { AVAssetAudioFileSource(url: $0) },
        makeDiarizer: @escaping () -> (any StreamingSpeakerDiarizationService)? = { nil },
        status: FileTranscriptionStatus = FileTranscriptionStatus(),
        openResult: @escaping (UUID) -> Void = { _ in },
        showWindow: @escaping () -> Void = {}
    ) {
        self.host = host
        self.store = store
        self.makeSource = makeSource
        self.makeDiarizer = makeDiarizer
        self.status = status
        self.openResult = openResult
        self.showWindow = showWindow
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func accepts(_ url: URL) -> Bool {
        url.isFileURL && Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    func presentWindow() { showWindow() }

    func start(url: URL) {
        guard !isRunning else { return }
        guard let host else { return }
        guard accepts(url) else {
            phase = .failed(.unsupportedType)
            return
        }
        guard !host.isLocked else {
            host.showPaywall()
            return
        }
        guard !host.isDictationBusy, !host.isMeetingActive else {
            phase = .failed(.busy)
            return
        }
        guard let engine = host.sharedEngine else {
            phase = .failed(.modelUnavailable)
            return
        }

        let name = url.lastPathComponent
        phase = .running(fileName: name, progress: nil)
        host.setFileRunning(true)
        host.report(.fileTranscriptionStarted)
        let session = FileTranscriptionSession(
            source: makeSource(url),
            engine: engine,
            profile: host.languageProfile,
            persistence: MeetingPersistenceRecorder(store: store),
            title: url.deletingPathExtension().lastPathComponent,
            originalFile: url,
            diarizer: makeDiarizer(),
            emit: { [weak self] progress in
                Task { @MainActor in self?.receive(progress) }
            }
        )
        self.session = session
        startPollingModel(engine: engine, profile: host.languageProfile)
        task = Task { [weak self] in
            do {
                let result = try await session.run()
                self?.finish(result)
            } catch let failure as FileTranscriptionFailure {
                self?.finish(failure)
            } catch {
                self?.finish(.recognitionStopped)
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        let session = session
        task?.cancel()
        Task { await session?.cancel() }
    }

    func dismissFailure() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: -

    /// Core ML reports no progress while it compiles the model for this Mac, so
    /// the most that can honestly be shown is which step it is in and a clock.
    /// The engine already knows the step; this only asks it twice a second until
    /// the first passage is recognised.
    private func startPollingModel(engine: any TranscriptionService, profile: LanguageProfile) {
        waitPolling?.cancel()
        waitPolling = Task { [weak self] in
            while !Task.isCancelled {
                let state = await engine.modelState(for: profile)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                if case let .preparing(preparation) = state {
                    let since = self.modelWait?.since ?? Date()
                    self.modelWait = FileModelWait(preparation: preparation, since: since)
                } else {
                    self.modelWait = nil
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func receive(_ progress: FileTranscriptionProgress) {
        if modelWait != nil || waitPolling != nil {
            waitPolling?.cancel()
            waitPolling = nil
            modelWait = nil
        }
        guard case let .running(name, previous) = phase else { return }
        if let previous, previous.recognisedFrames > progress.recognisedFrames { return }
        phase = .running(fileName: name, progress: progress)
    }

    private func finish(_ result: FileTranscriptionResult) {
        endRun()
        phase = .idle
        if !result.rows.isEmpty { host?.noteFileProducedText() }
        host?.report(.fileTranscriptionCompleted(.init(seconds: result.metrics.audioSeconds)))
        openResult(result.meetingID)
    }

    private func finish(_ failure: FileTranscriptionFailure) {
        endRun()
        phase = failure == .cancelled ? .idle : .failed(failure)
        if let reason = failure.telemetryReason { host?.report(.fileTranscriptionFailed(reason)) }
    }

    private func endRun() {
        waitPolling?.cancel()
        waitPolling = nil
        modelWait = nil
        host?.setFileRunning(false)
        task = nil
        session = nil
    }
}

extension FileTranscriptionFailure {
    /// What is reported, if anything. A cancel is the person's choice and the
    /// two refusals happen before a file is touched, so none of them is a
    /// failure of the feature.
    var telemetryReason: TelemetryEvent.FileFailure? {
        switch self {
        case let .file(error):
            switch error {
            case .unreadable: .unreadable
            case .noAudioTrack: .noAudioTrack
            case .protectedContent: .protectedContent
            case .empty: .empty
            }
        case .modelUnavailable: .modelUnavailable
        case .recognitionStopped: .recognitionStopped
        case .storageFailed: .storageFailed
        case .cancelled, .unsupportedType, .busy: nil
        }
    }

    /// The sentence the person reads. Content-free by construction: it names a
    /// kind of problem, never the file or what was said in it.
    var message: String {
        switch self {
        case .unsupportedType:
            L10n.string("Witness can transcribe m4a, mp3, wav, aiff, caf, mp4 and mov files.")
        case .busy:
            L10n.string("Finish the dictation or meeting that is running first, then choose the file again.")
        case .modelUnavailable:
            L10n.string("The speech model is not ready yet. The menu bar shows how far it has got; choose the file again when it is.")
        case let .file(error):
            switch error {
            case .noAudioTrack: L10n.string("This file has no audio track.")
            case .protectedContent: L10n.string("This file is copy-protected, so Witness cannot read its audio.")
            case .empty: L10n.string("This file contains no audio.")
            case .unreadable: L10n.string("Witness could not read this file. It may be damaged or in a format macOS cannot open.")
            }
        case .recognitionStopped:
            L10n.string("Recognition stopped before the file was finished. Nothing was saved. Try again; if it repeats, restart Witness.")
        case .storageFailed:
            L10n.string("The transcript could not be saved on this Mac. Check free disk space and try again.")
        case .cancelled:
            L10n.string("Cancelled. Nothing was saved.")
        }
    }
}
