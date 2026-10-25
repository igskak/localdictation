import AppKit
import Combine
import SwiftUI

struct MeetingProcessOption: Identifiable, Hashable {
    let processID: pid_t
    let name: String
    let bundleIdentifier: String?
    let isProducingOutput: Bool
    let isUsingInput: Bool
    let isFrontmost: Bool

    init(
        processID: pid_t,
        name: String,
        bundleIdentifier: String?,
        isProducingOutput: Bool,
        isUsingInput: Bool = false,
        isFrontmost: Bool = false
    ) {
        self.processID = processID
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isProducingOutput = isProducingOutput
        self.isUsingInput = isUsingInput
        self.isFrontmost = isFrontmost
    }

    var id: pid_t { processID }
    var detail: String {
        isProducingOutput ? "Audio active · PID \(processID)" : "No audio now · PID \(processID)"
    }

    var applicationKind: MeetingApplicationKind {
        MeetingApplicationKind.classify(name: name, bundleIdentifier: bundleIdentifier)
    }
}

enum MeetingProcessSelection {
    static func preferred(in options: [MeetingProcessOption]) -> MeetingProcessOption? {
        options
            .filter { score($0) > 0 }
            .sorted {
                let lhsScore = score($0)
                let rhsScore = score($1)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if $0.name != $1.name {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.processID < $1.processID
            }
            .first
    }

    private static func score(_ option: MeetingProcessOption) -> Int {
        let frontmost = option.isFrontmost ? 50 : 0
        let microphone = option.isUsingInput ? 100 : 0
        return switch (option.isProducingOutput, option.applicationKind) {
        case (true, .zoom): 900 + microphone
        case (true, .chrome), (true, .safari): 700 + microphone + frontmost
        case (false, .zoom): 400 + microphone
        case (false, .chrome), (false, .safari): 300 + microphone + frontmost
        case (true, .other): 100
        case (false, .other): 0
        }
    }
}

private enum MeetingFailureAction {
    case microphoneSettings
    case privacySettings
    case retryStart
}

@MainActor
final class DebugMeetingModel: ObservableObject {
    @Published var processOptions: [MeetingProcessOption] = []
    @Published var selectedProcessID: pid_t?
    @Published private(set) var languageProfile: LanguageProfile
    @Published var status = "Ready. Press Record when your meeting starts."
    @Published var rows: [MeetingTranscriptRow] = []
    @Published var metrics = ""
    @Published var diarizationState: DiarizationDisplayState = .unavailable
    @Published var active = false
    @Published var preparing = false
    @Published var paused = false
    @Published var finishing = false
    @Published var elapsed: TimeInterval = 0
    @Published var failureMessage: String?
    @Published private var failureAction: MeetingFailureAction?

    var onRecordingStarted: (MeetingCandidate) -> Void = { _ in }
    var onRecordingFinished: () -> Void = {}

    private var session: DebugMeetingSession?
    private var generation = UUID()
    private let permission = AVCaptureMicrophonePermissionService()
    private let resolver: any MeetingProcessResolving
    private let store: any MeetingStoring
    private let menuBarStatus: NotetakerStatus
    private let languageProfileProvider: @MainActor () -> LanguageProfile
    private let onMeetingFinished: (UUID?) -> Void
    private var clockTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var accumulatedPause: TimeInterval = 0
    private var captureStartReported = false

    init(
        languageProfileProvider: @escaping @MainActor () -> LanguageProfile = { .default },
        resolver: any MeetingProcessResolving = CoreAudioMeetingProcessResolver(),
        store: any MeetingStoring = FileMeetingStore(),
        menuBarStatus: NotetakerStatus = NotetakerStatus(),
        onMeetingFinished: @escaping (UUID?) -> Void = { _ in }
    ) {
        self.languageProfileProvider = languageProfileProvider
        languageProfile = languageProfileProvider()
        self.resolver = resolver
        self.store = store
        self.menuBarStatus = menuBarStatus
        self.onMeetingFinished = onMeetingFinished
    }

    var selectedProcess: MeetingProcessOption? {
        processOptions.first { $0.processID == selectedProcessID }
    }

    var canStart: Bool {
        !active && !finishing
    }

    var elapsedLabel: String {
        let seconds = max(Int(elapsed), 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    func start(preferredProcessID: pid_t? = nil) {
        guard canStart else { return }
        refreshLanguageProfile()
        let sessionProfile = languageProfile
        active = true
        preparing = true
        paused = false
        finishing = false
        failureMessage = nil
        failureAction = nil
        captureStartReported = false
        rows = []
        metrics = ""
        diarizationState = .unavailable
        elapsed = 0
        accumulatedPause = 0
        pausedAt = nil
        startedAt = Date()
        beginClock()
        let currentGeneration = UUID()
        generation = currentGeneration
        menuBarStatus.update(.preparing)
        status = "Finding Zoom, Chrome, or Safari audio…"
        Task { [self] in
            do {
                let options = try await discoverProcesses()
                guard active, generation == currentGeneration else { return }
                receiveProcesses(options, preferredProcessID: preferredProcessID)
            } catch {
                fail("Witness could not inspect local audio apps. Check that Zoom, Chrome, or Safari is open, then try again.", action: .retryStart)
                return
            }
            guard let processID = selectedProcessID else {
                fail("No meeting audio was found. Open Zoom, Chrome, or Safari, then press Record again.", action: .retryStart)
                return
            }
            status = "Checking microphone access…"
            let authorization = permission.currentAuthorization == .notDetermined
                ? await permission.requestAccess() : permission.currentAuthorization
            guard active, generation == currentGeneration else { return }
            guard authorization == .authorized else {
                fail("Microphone access is off. Allow it in System Settings, then start again.", action: .microphoneSettings)
                return
            }
            let persistence = MeetingPersistenceRecorder(store: store)
            let meeting = DebugMeetingSession(
                profile: sessionProfile,
                title: defaultMeetingTitle,
                persistence: persistence
            ) { [weak self] update in
                Task { @MainActor [weak self] in self?.receive(update) }
            }
            session = meeting
            do {
                try await meeting.start(processID: processID)
            } catch {
                let failure = failure(for: error)
                fail(failure.message, action: failure.action)
                session = nil
            }
        }
    }

    func togglePause() {
        guard let session, active, !finishing else { return }
        if paused {
            status = "Resuming…"
            Task { await session.resume() }
        } else {
            status = "Pausing…"
            Task { await session.pause() }
        }
    }

    func stop() {
        guard let session else {
            generation = UUID()
            active = false
            preparing = false
            paused = false
            finishing = false
            stopClock()
            menuBarStatus.update(.idle)
            status = rows.isEmpty ? "Stopped — no audio was captured." : "Stopped — transcript is held in memory."
            return
        }
        finishing = true
        preparing = false
        paused = false
        menuBarStatus.update(.finishing)
        status = "Finishing the transcript…"
        Task { await session.stop() }
    }

    var failureActionTitle: String? {
        switch failureAction {
        case .microphoneSettings: "Open Microphone Settings"
        case .privacySettings: "Open Privacy & Security"
        case .retryStart: "Try Again"
        case nil: nil
        }
    }

    func performFailureAction() {
        switch failureAction {
        case .microphoneSettings:
            permission.openSystemSettings()
        case .privacySettings:
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }
            NSWorkspace.shared.open(url)
        case .retryStart:
            start()
        case nil:
            break
        }
    }

    /// Sample the app profile between meetings. Once capture starts, the local
    /// decoder keeps that profile stable until the note is finished.
    func refreshLanguageProfile() {
        guard !active else { return }
        languageProfile = languageProfileProvider()
    }

    private var defaultMeetingTitle: String {
        let source = selectedProcess?.name ?? "Meeting"
        return "\(source) — \(Date().formatted(date: .abbreviated, time: .shortened))"
    }

    private func discoverProcesses() async throws -> [MeetingProcessOption] {
        let resolver = self.resolver
        let processes = try await Task.detached(priority: .userInitiated) {
            try resolver.processes()
        }.value
        return processes.map { process in
            let application = NSRunningApplication(processIdentifier: process.processID)
            let bundleIdentifier = process.bundleIdentifier ?? application?.bundleIdentifier
            let kind = MeetingApplicationKind.classify(
                name: application?.localizedName ?? "",
                bundleIdentifier: bundleIdentifier
            )
            let fallbackName = switch kind {
            case .zoom: "Zoom"
            case .chrome: "Google Chrome"
            case .safari: "Safari"
            case .other: "Audio process"
            }
            return MeetingProcessOption(
                processID: process.processID,
                name: application?.localizedName ?? fallbackName,
                bundleIdentifier: bundleIdentifier,
                isProducingOutput: process.isProducingOutput,
                isUsingInput: process.isUsingInput,
                isFrontmost: application?.isActive == true
            )
        }
    }

    private func receiveProcesses(_ processes: [MeetingProcessOption], preferredProcessID: pid_t?) {
        processOptions = processes
        if let preferredProcessID,
           processes.contains(where: { $0.processID == preferredProcessID }) {
            selectedProcessID = preferredProcessID
        } else {
            selectedProcessID = MeetingProcessSelection.preferred(in: processes)?.processID
        }
    }

    private func receive(_ update: DebugMeetingUpdate) {
        switch update {
        case let .status(value):
            status = value
            if value.hasPrefix("Recording") {
                preparing = false
                if let pausedAt { accumulatedPause += Date().timeIntervalSince(pausedAt) }
                self.pausedAt = nil
                paused = false
                menuBarStatus.update(.recording)
                if !captureStartReported,
                   let selectedProcess,
                   let candidate = MeetingCandidateDetector().candidate(for: selectedProcess) {
                    captureStartReported = true
                    onRecordingStarted(candidate)
                }
            } else if value.hasPrefix("Paused") {
                preparing = false
                paused = true
                pausedAt = Date()
                menuBarStatus.update(.paused)
            }
        case let .diarization(value):
            diarizationState = value
        case let .rows(value): rows = value
        case let .metrics(value): metrics = value
        case let .finished(partial, persisted, issues):
            let finishedSession = session
            updateElapsed()
            active = false
            preparing = false
            paused = false
            finishing = false
            session = nil
            captureStartReported = false
            stopClock()
            onRecordingFinished()
            if partial {
                menuBarStatus.update(.attention)
                status = partialCompletionStatus(persisted: persisted, issues: issues)
            } else {
                menuBarStatus.update(.idle)
                status = persisted ? "Complete — transcript saved locally." : "Stopped — no transcript was saved."
            }
            Task {
                let meetingID = await finishedSession?.meetingID
                onMeetingFinished(meetingID)
            }
        }
    }

    private func partialCompletionStatus(persisted: Bool, issues: [MeetingPartialIssue]) -> String {
        guard persisted else { return "Partial transcript remains in memory — local storage failed." }
        if issues.contains(.transcriptionStopped) {
            return "Partial transcript saved locally — recognition stopped before every passage was processed."
        }
        if issues.contains(.captureStopped) {
            return "Partial transcript saved locally — audio capture stopped before the meeting ended."
        }
        if issues.contains(.audioIntervalMissed) {
            return "Partial transcript saved locally — a short audio interval was missed."
        }
        return "Partial transcript saved locally — some audio could not be processed."
    }

    private func beginClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.updateElapsed()
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }

    private func updateElapsed() {
        guard let startedAt else { return }
        let currentPause = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = max(0, Date().timeIntervalSince(startedAt) - accumulatedPause - currentPause)
    }

    private func fail(_ message: String, action: MeetingFailureAction? = nil) {
        active = false
        preparing = false
        paused = false
        finishing = false
        captureStartReported = false
        stopClock()
        failureMessage = message
        failureAction = action
        menuBarStatus.update(.attention)
        status = "Could not start the meeting note."
    }

    private func failure(for error: Error) -> (message: String, action: MeetingFailureAction?) {
        switch error {
        case SystemAudioPermissionError.denied:
            ("System Audio Recording is off for Witness. Allow it in System Settings, then start again.", .privacySettings)
        case MeetingMicrophoneError.permissionUnavailable:
            ("Microphone access is off for Witness. Allow it in System Settings, then start again.", .microphoneSettings)
        case MeetingMicrophoneError.noInput:
            ("No usable microphone was found. Connect or select an input, then start again.", .microphoneSettings)
        case SystemAudioCaptureError.processNotFound:
            ("Zoom, Chrome, or Safari closed or changed while Witness was starting. Open the meeting and try again.", .retryStart)
        case DebugMeetingError.modelUnavailable:
            ("The selected local speech model is unavailable. Prepare it in Witness and try again.", nil)
        case is MeetingStoreError:
            ("The meeting could not be saved locally. Check available disk space and folder access, then try again.", nil)
        default:
            ("Witness could not start both audio sources. Check the meeting app, microphone and System Audio permissions.", .privacySettings)
        }
    }
}

struct DebugMeetingView: View {
    @ObservedObject var model: DebugMeetingModel
    let openHistory: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLatest = true

    init(model: DebugMeetingModel, openHistory: @escaping () -> Void = {}) {
        self.model = model
        self.openHistory = openHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(WitnessStyle.line)
            HSplitView {
                controls
                    .frame(minWidth: 280, idealWidth: 310, maxWidth: 340)
                transcript
                    .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 620)
        .witnessWindow()
    }

    private var header: some View {
        HStack(spacing: 12) {
            WitnessBrand()
            Text("Meeting Note")
                .font(.title3.weight(.semibold))
            Text("TEST BUILD")
                .font(.caption2.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(WitnessStyle.warning)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(WitnessStyle.warning.opacity(0.12), in: Capsule())
            Button(action: openHistory) {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .foregroundStyle(WitnessStyle.muted)
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help("Open meeting note history")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.elapsedLabel)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Text(model.active ? (model.preparing ? "Starting" : model.paused ? "Paused" : model.finishing ? "Finishing" : "Recording") : "Local only")
                    .font(.caption)
                    .foregroundStyle(model.active ? WitnessStyle.accent : WitnessStyle.muted)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                actionButtons
                if let failure = model.failureMessage { failureCard(failure) }
                automaticSourceNote
                notice
                DisclosureGroup("Recording details") {
                    VStack(alignment: .leading, spacing: 16) {
                        languageProfileSummary
                        sourceHealth
                        if !model.metrics.isEmpty { metricsCard }
                    }
                    .padding(.top, 10)
                }
                .font(.callout.weight(.medium))
            }
            .padding(20)
        }
        .background(WitnessStyle.canvas)
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 10) {
            WitnessIconTile(systemImage: statusIcon, tint: statusTint)
            Text(model.status)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(model.failureMessage == nil ? (model.active ? .accent : .neutral) : .warning)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting status: \(model.status)")
    }

    private var automaticSourceNote: some View {
        Label {
            Text("Witness automatically records your microphone and the open Zoom, Chrome, or Safari meeting.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(WitnessStyle.accent)
        }
        .font(.callout)
        .foregroundStyle(WitnessStyle.muted)
        .accessibilityElement(children: .combine)
    }

    private var languageProfileSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript languages").font(.headline)
            Text(model.languageProfile.displayName)
                .font(.callout.weight(.medium))
                .foregroundStyle(WitnessStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Uses your Witness language profile. Change it in Settings before starting a meeting.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcript languages: \(model.languageProfile.displayName). Uses your Witness language profile.")
    }

    private var sourceHealth: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources").font(.headline)
            sourceRow("You", detail: "System microphone", systemImage: "mic", available: true)
            sourceRow("Others", detail: model.selectedProcess?.name ?? "Selected automatically when recording", systemImage: "waveform", available: model.selectedProcessID != nil)
            sourceRow(
                "Speaker separation",
                detail: diarizationDetail,
                systemImage: "person.2.wave.2",
                available: model.diarizationState == .active
            )
        }
    }

    private var diarizationDetail: String {
        switch model.diarizationState {
        case .unavailable: "Starts with recording"
        case .preparing: "Loading the bundled local model"
        case .active: "Nemotron 3 · local · 10.6 s model window"
        case .fallback: "Model unavailable — using You/Others"
        case .failed: "Stopped safely — using You/Others"
        }
    }

    private func sourceRow(_ title: String, detail: String, systemImage: String, available: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(available ? WitnessStyle.success : WitnessStyle.faint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(WitnessStyle.muted)
            }
            Spacer()
            Text(model.active ? (model.paused ? "Paused" : "On") : (available ? "Ready" : "Missing"))
                .font(.caption.weight(.medium))
                .foregroundStyle(available ? WitnessStyle.success : WitnessStyle.warning)
        }
        .padding(10)
        .background(WitnessStyle.surface, in: RoundedRectangle(cornerRadius: WitnessStyle.compactCornerRadius))
        .accessibilityElement(children: .combine)
    }

    private var actionButtons: some View {
        Group {
            if model.preparing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Starting local recording…")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Cancel") { model.stop() }
                        .buttonStyle(WitnessSecondaryButtonStyle())
                }
            } else if model.active {
                HStack(spacing: 8) {
                Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                    .buttonStyle(WitnessSecondaryButtonStyle())
                    .disabled(model.finishing)
                Button("Stop") { model.stop() }
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .disabled(model.finishing)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            } else {
                Button("Record") { model.start() }
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .disabled(!model.canStart)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityHint("Automatically records the microphone and meeting audio from Zoom, Chrome, or Safari")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(WitnessStyle.muted)
                .accessibilityHidden(true)
            Text("Witness does not notify other participants. Follow the recording and consent rules that apply to your call. Audio and transcript processing stay on this Mac.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs attention", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(WitnessStyle.warning)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let title = model.failureActionTitle {
                Button(title) { model.performFailureAction() }
                    .buttonStyle(WitnessSecondaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard(.warning)
    }

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Technical metrics").font(.headline)
            Text(model.metrics)
                .font(.caption.monospaced())
                .foregroundStyle(WitnessStyle.muted)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .witnessCard()
    }

    private var transcript: some View {
        let groups = MeetingTranscriptPresentation.groups(from: model.rows)
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live transcript").font(.headline)
                    Text("Recognition is assembled locally into speaker turns. Uncertain model guesses are marked.")
                        .font(.caption)
                        .foregroundStyle(WitnessStyle.muted)
                }
                Spacer()
                Toggle("Follow latest", isOn: $followsLatest)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider().overlay(WitnessStyle.line)
            ScrollViewReader { proxy in
                ScrollView {
                    if groups.isEmpty {
                        VStack(spacing: 10) {
                            if model.active {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Listening for speech")
                                Text(model.preparing ? "Preparing local recognition…" : "Listening for speech…")
                                    .font(.headline)
                                Text("The first live text normally appears after about 8–10 seconds of speech.")
                                    .font(.callout)
                                    .foregroundStyle(WitnessStyle.muted)
                                    .multilineTextAlignment(.center)
                            } else {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(WitnessStyle.faint)
                                    .accessibilityHidden(true)
                                Text("Transcript will appear here").font(.headline)
                                Text("Start a note, then speak or play meeting audio.")
                                    .font(.callout)
                                    .foregroundStyle(WitnessStyle.muted)
                            }
                        }
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                                transcriptGroup(group).id(index)
                            }
                        }
                        .padding(20)
                    }
                }
                .onChange(of: groups.count) {
                    guard followsLatest, !groups.isEmpty else { return }
                    if reduceMotion {
                        proxy.scrollTo(groups.count - 1, anchor: .bottom)
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(groups.count - 1, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: followsLatest) {
                    guard followsLatest, !groups.isEmpty else { return }
                    proxy.scrollTo(groups.count - 1, anchor: .bottom)
                }
            }
        }
        .background(WitnessStyle.raisedSurface.opacity(0.34))
    }

    private func transcriptGroup(_ group: MeetingTranscriptPresentationGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timestamp(group.startFrame))
                .font(.caption.monospacedDigit())
                .foregroundStyle(WitnessStyle.faint)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(group.speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(group.source == .microphone ? WitnessStyle.accent : WitnessStyle.success)
                    if let confidence = group.rows.compactMap(\.speakerConfidence).min() {
                        Text("\(Int((confidence * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(confidence >= 0.6 ? WitnessStyle.muted : WitnessStyle.warning)
                    }
                    if group.recognitionNeedsReview {
                        Label("Low confidence", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WitnessStyle.warning)
                    }
                }
                Text(group.recognitionNeedsReview ? "Model guess: \(group.text)" : group.text)
                    .font(.body)
                    .foregroundStyle(group.recognitionNeedsReview ? WitnessStyle.muted : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(WitnessStyle.surface, in: RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius)
                .stroke(group.recognitionNeedsReview ? WitnessStyle.warning.opacity(0.55) : WitnessStyle.line,
                        lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.speaker), \(timestamp(group.startFrame)): "
            + (group.recognitionNeedsReview ? "Low confidence model guess: " : "")
            + group.text
        )
    }

    private func timestamp(_ frame: Int64) -> String {
        let seconds = max(Int(frame / 16_000), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var statusIcon: String {
        if model.failureMessage != nil { return "exclamationmark.triangle" }
        if model.finishing { return "hourglass" }
        if model.paused { return "pause.fill" }
        if model.active { return "record.circle" }
        return "note.text"
    }

    private var statusTint: Color {
        if model.failureMessage != nil { return WitnessStyle.warning }
        if model.active { return model.paused ? WitnessStyle.warning : WitnessStyle.accent }
        return WitnessStyle.muted
    }
}

@MainActor
final class DebugMeetingWindowController: NSObject {
    private let model: DebugMeetingModel
    var openHistory: () -> Void = {}
    private var window: NSWindow?

    init(model: DebugMeetingModel = DebugMeetingModel()) {
        self.model = model
    }

    func show() {
        model.refreshLanguageProfile()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Witness Meeting Note — Test Build"
        window.contentMinSize = NSSize(width: 780, height: 620)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DebugMeetingView(model: model, openHistory: { [weak self] in
            self?.openHistory()
        }))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() { model.stop() }
}

private enum MeetingPromptMode: Equatable {
    case start
    case finish
}

private struct MeetingPromptView: View {
    let title: String
    let detail: String
    let systemImage: String
    let primaryTitle: String
    let secondaryTitle: String
    let isDestructive: Bool
    let primaryAction: () -> Void
    let secondaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                WitnessIconTile(
                    systemImage: systemImage,
                    tint: isDestructive ? WitnessStyle.warning : WitnessStyle.accent
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(WitnessStyle.ink)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(WitnessStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .accessibilityHint(isDestructive
                        ? "Stops capture and saves the local meeting note"
                        : "Starts local microphone and meeting audio recording")
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(WitnessSecondaryButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 380)
        .witnessWindow()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A compact, non-activating decision surface. It stays above the meeting app
/// without stealing keyboard focus. The start suggestion expires quietly;
/// stopping a recording always requires an explicit user action.
@MainActor
private final class MeetingPromptPanelController {
    private var panel: NSPanel?
    private var mode: MeetingPromptMode?
    private var autoDismissTask: Task<Void, Never>?

    func showStart(_ suggestion: NotetakerSuggestion, timeout: @escaping () -> Void) {
        present(
            mode: .start,
            title: suggestion.title,
            detail: suggestion.detail,
            systemImage: "video.badge.waveform",
            primaryTitle: "Start recording",
            secondaryTitle: "Not now",
            isDestructive: false,
            primaryAction: suggestion.start,
            secondaryAction: suggestion.dismiss
        )
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.mode == .start else { return }
            self.autoDismissTask = nil
            self.panel?.orderOut(nil)
            self.mode = nil
            timeout()
        }
    }

    func showFinish(stop: @escaping () -> Void, continueRecording: @escaping () -> Void) {
        present(
            mode: .finish,
            title: "Has the meeting ended?",
            detail: "Meeting audio has been quiet for a while. Witness is still recording and will only stop when you choose.",
            systemImage: "waveform.slash",
            primaryTitle: "Stop recording",
            secondaryTitle: "Keep recording",
            isDestructive: true,
            primaryAction: stop,
            secondaryAction: continueRecording
        )
    }

    func dismiss(_ expectedMode: MeetingPromptMode? = nil) {
        if let expectedMode, mode != expectedMode { return }
        autoDismissTask?.cancel()
        autoDismissTask = nil
        panel?.orderOut(nil)
        mode = nil
    }

    private func present(
        mode: MeetingPromptMode,
        title: String,
        detail: String,
        systemImage: String,
        primaryTitle: String,
        secondaryTitle: String,
        isDestructive: Bool,
        primaryAction: @escaping () -> Void,
        secondaryAction: @escaping () -> Void
    ) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        let dismissingPrimary = { [weak self] in
            self?.dismiss(mode)
            primaryAction()
        }
        let dismissingSecondary = { [weak self] in
            self?.dismiss(mode)
            secondaryAction()
        }
        let view = MeetingPromptView(
            title: title,
            detail: detail,
            systemImage: systemImage,
            primaryTitle: primaryTitle,
            secondaryTitle: secondaryTitle,
            isDestructive: isDestructive,
            primaryAction: dismissingPrimary,
            secondaryAction: dismissingSecondary
        )
        let panel = panel ?? makePanel()
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: 380, height: panel.contentView?.fittingSize.height ?? 170))
        position(panel)
        self.panel = panel
        self.mode = mode
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - frame.width - 24,
            y: visible.minY + 24
        ))
    }
}

@MainActor
final class DogfoodNotetakerFacade: NotetakerFacade {
    let status: NotetakerStatus
    private(set) var suggestion: NotetakerSuggestion?
    private let window: DebugMeetingWindowController
    private let library: MeetingLibraryWindowController
    private let recordingModel: DebugMeetingModel
    private let prompt = MeetingPromptPanelController()
    private var detection: MeetingDetectionCoordinator?

    init(languageProfileProvider: @escaping @MainActor () -> LanguageProfile = { .default }) {
        let store = FileMeetingStore()
        let status = NotetakerStatus()
        let libraryModel = MeetingLibraryModel(store: store)
        let recordingModel = DebugMeetingModel(
            languageProfileProvider: languageProfileProvider,
            store: store,
            menuBarStatus: status
        ) { [weak libraryModel] meetingID in
            Task { await libraryModel?.refresh(selecting: meetingID) }
        }
        let window = DebugMeetingWindowController(model: recordingModel)
        let library = MeetingLibraryWindowController(model: libraryModel) { [weak window] in
            window?.show()
        }
        window.openHistory = { [weak library] in library?.show() }
        self.status = status
        self.window = window
        self.library = library
        self.recordingModel = recordingModel
        let detection = MeetingDetectionCoordinator(
            model: recordingModel,
            onSuggestion: { [weak self] candidate in
                self?.presentSuggestion(for: candidate)
            },
            onCallEndSuggestion: { [weak self] visible in
                self?.presentCallEndSuggestion(visible)
            }
        )
        self.detection = detection
        recordingModel.onRecordingStarted = { [weak detection] candidate in
            detection?.recordingStarted(candidate: candidate)
        }
        recordingModel.onRecordingFinished = { [weak detection] in
            detection?.recordingFinished()
        }
    }

    var menuBarItem: NotetakerMenuItem? {
        NotetakerMenuItem(
            title: status.isActive ? "Open meeting note" : "Record meeting note…",
            systemImage: status.isActive ? "record.circle" : "note.text.badge.plus",
            action: { [weak self] in self?.window.show() }
        )
    }

    var historyMenuItem: NotetakerMenuItem? {
        NotetakerMenuItem(
            title: "Meeting note history…",
            systemImage: "clock.arrow.circlepath",
            action: { [weak self] in self?.library.show() }
        )
    }

    var stopMenuItem: NotetakerMenuItem? {
        guard status.isActive, status.state != .finishing else { return nil }
        return NotetakerMenuItem(
            title: "Stop meeting recording",
            systemImage: "stop.circle",
            action: { [weak self] in self?.recordingModel.stop() }
        )
    }

    func activate() {
        recordingModel.refreshLanguageProfile()
        detection?.activate()
        Task(priority: .utility) {
            await ProductionDiarizationFactory.warmUpIfAvailable()
        }
    }

    func deactivate() {
        detection?.deactivate()
        prompt.dismiss()
        window.stop()
    }

    private func presentSuggestion(for candidate: MeetingCandidate?) {
        guard let candidate else {
            suggestion = nil
            prompt.dismiss(.start)
            if status.state == .suggestion {
                status.update(.idle)
            } else {
                status.update(status.state)
            }
            return
        }
        suggestion = NotetakerSuggestion(
            platform: candidate.platform,
            start: { [weak self] in self?.startSuggestedMeeting() },
            dismiss: { [weak self] in self?.dismissSuggestion() }
        )
        if let suggestion {
            prompt.showStart(suggestion, timeout: { [weak self] in self?.expireSuggestion() })
        }
        if status.state == .idle || status.state == .suggestion {
            status.update(.suggestion)
        } else {
            status.update(status.state)
        }
    }

    private func startSuggestedMeeting() {
        guard let candidate = detection?.acceptSuggestion() else { return }
        suggestion = nil
        prompt.dismiss(.start)
        window.show()
        recordingModel.start(preferredProcessID: candidate.processIdentifier)
    }

    private func dismissSuggestion() {
        detection?.dismissSuggestion()
        suggestion = nil
        prompt.dismiss(.start)
        if status.state == .suggestion { status.update(.idle) }
    }

    private func expireSuggestion() {
        detection?.expireSuggestion()
        suggestion = nil
        if status.state == .suggestion { status.update(.idle) }
    }

    private func presentCallEndSuggestion(_ visible: Bool) {
        guard visible, status.state == .recording else {
            prompt.dismiss(.finish)
            return
        }
        prompt.showFinish(
            stop: { [weak self] in self?.recordingModel.stop() },
            continueRecording: { [weak self] in self?.detection?.continueRecording() }
        )
    }
}
