import AppKit
import Combine
import SwiftUI

struct MeetingProcessOption: Identifiable, Hashable {
    let processID: pid_t
    let name: String
    let bundleIdentifier: String?
    let isProducingOutput: Bool

    var id: pid_t { processID }
    var detail: String {
        isProducingOutput ? "Audio active · PID \(processID)" : "No audio now · PID \(processID)"
    }
}

private enum MeetingFailureAction {
    case microphoneSettings
    case privacySettings
    case refreshProcesses
}

@MainActor
final class DebugMeetingModel: ObservableObject {
    @Published var processOptions: [MeetingProcessOption] = []
    @Published var selectedProcessID: pid_t?
    @Published var language = "en"
    @Published var status = "Choose the meeting app to start a local note."
    @Published var rows: [MeetingTranscriptRow] = []
    @Published var metrics = ""
    @Published var active = false
    @Published var paused = false
    @Published var finishing = false
    @Published var refreshingProcesses = false
    @Published var elapsed: TimeInterval = 0
    @Published var failureMessage: String?
    @Published private var failureAction: MeetingFailureAction?

    private var session: DebugMeetingSession?
    private var generation = UUID()
    private let permission = AVCaptureMicrophonePermissionService()
    private let resolver: any MeetingProcessResolving
    private var clockTask: Task<Void, Never>?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var accumulatedPause: TimeInterval = 0

    init(resolver: any MeetingProcessResolving = CoreAudioMeetingProcessResolver()) {
        self.resolver = resolver
    }

    var selectedProcess: MeetingProcessOption? {
        processOptions.first { $0.processID == selectedProcessID }
    }

    var canStart: Bool {
        !active && !finishing && selectedProcessID != nil
    }

    var elapsedLabel: String {
        let seconds = max(Int(elapsed), 0)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    func refreshProcesses() {
        guard !refreshingProcesses, !active else { return }
        refreshingProcesses = true
        failureMessage = nil
        failureAction = nil
        let resolver = self.resolver
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let processes = try resolver.processes().map { process in
                    let application = NSRunningApplication(processIdentifier: process.processID)
                    return MeetingProcessOption(
                        processID: process.processID,
                        name: application?.localizedName ?? "Audio process",
                        bundleIdentifier: application?.bundleIdentifier,
                        isProducingOutput: process.isProducingOutput
                    )
                }.sorted { lhs, rhs in
                    if lhs.isProducingOutput != rhs.isProducingOutput { return lhs.isProducingOutput }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                await MainActor.run { self?.receiveProcesses(processes) }
            } catch {
                await MainActor.run {
                    self?.refreshingProcesses = false
                    self?.failureMessage = "Audio apps could not be listed. Play audio in Zoom or Chrome, then try again."
                    self?.failureAction = .refreshProcesses
                }
            }
        }
    }

    func start() {
        guard canStart, let processID = selectedProcessID else { return }
        active = true
        paused = false
        finishing = false
        failureMessage = nil
        failureAction = nil
        rows = []
        metrics = ""
        elapsed = 0
        accumulatedPause = 0
        pausedAt = nil
        startedAt = Date()
        beginClock()
        let currentGeneration = UUID()
        generation = currentGeneration
        status = "Checking microphone access…"
        Task { [self] in
            let authorization = permission.currentAuthorization == .notDetermined
                ? await permission.requestAccess() : permission.currentAuthorization
            guard active, generation == currentGeneration else { return }
            guard authorization == .authorized else {
                fail("Microphone access is off. Allow it in System Settings, then start again.", action: .microphoneSettings)
                return
            }
            let meeting = DebugMeetingSession(profile: selectedProfile) { [weak self] update in
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
            paused = false
            finishing = false
            stopClock()
            status = rows.isEmpty ? "Stopped — no audio was captured." : "Stopped — transcript is held in memory."
            return
        }
        finishing = true
        paused = false
        status = "Finishing the transcript…"
        Task { await session.stop() }
    }

    var failureActionTitle: String? {
        switch failureAction {
        case .microphoneSettings: "Open Microphone Settings"
        case .privacySettings: "Open Privacy & Security"
        case .refreshProcesses: "Refresh audio apps"
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
        case .refreshProcesses:
            refreshProcesses()
        case nil:
            break
        }
    }

    private var selectedProfile: LanguageProfile {
        switch language {
        case "de": .german
        case "ru": .russian
        case "uk": .ukrainian
        default: .english
        }
    }

    private func receiveProcesses(_ processes: [MeetingProcessOption]) {
        processOptions = processes
        refreshingProcesses = false
        if let selectedProcessID, processes.contains(where: { $0.processID == selectedProcessID }) { return }
        let preferred = processes.first {
            let identity = "\($0.name) \($0.bundleIdentifier ?? "")".lowercased()
            return $0.isProducingOutput && (identity.contains("zoom") || identity.contains("chrome"))
        }
        selectedProcessID = preferred?.processID ?? processes.first(where: \.isProducingOutput)?.processID
        if processes.isEmpty {
            status = "No audio app is visible yet. Start playback in Zoom or Chrome and refresh."
        }
    }

    private func receive(_ update: DebugMeetingUpdate) {
        switch update {
        case let .status(value):
            status = value
            if value.hasPrefix("Recording") {
                if let pausedAt { accumulatedPause += Date().timeIntervalSince(pausedAt) }
                self.pausedAt = nil
                paused = false
            } else if value.hasPrefix("Paused") {
                paused = true
                pausedAt = Date()
            }
        case let .rows(value): rows = value
        case let .metrics(value): metrics = value
        case let .finished(partial):
            updateElapsed()
            active = false
            paused = false
            finishing = false
            session = nil
            stopClock()
            status = partial
                ? "Partial transcript — some audio could not be processed."
                : "Complete — transcript is held in memory."
        }
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
        paused = false
        finishing = false
        stopClock()
        failureMessage = message
        failureAction = action
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
            ("The selected audio app closed or changed. Refresh the list and choose it again.", .refreshProcesses)
        case DebugMeetingError.modelUnavailable:
            ("The selected local speech model is unavailable. Prepare it in Witness and try again.", nil)
        default:
            ("Witness could not start both audio sources. Check Zoom or Chrome, microphone and System Audio permissions.", .privacySettings)
        }
    }
}

struct DebugMeetingView: View {
    @ObservedObject var model: DebugMeetingModel
    @State private var followsLatest = true

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
        .onAppear { model.refreshProcesses() }
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
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.elapsedLabel)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Text(model.active ? (model.paused ? "Paused" : model.finishing ? "Finishing" : "Recording") : "Local only")
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
                sourcePicker
                languagePicker
                sourceHealth
                actionButtons
                notice
                if let failure = model.failureMessage { failureCard(failure) }
                if !model.metrics.isEmpty { metricsCard }
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

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Meeting audio").font(.headline)
                Spacer()
                Button {
                    model.refreshProcesses()
                } label: {
                    Label(model.refreshingProcesses ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(WitnessStyle.muted)
                .disabled(model.refreshingProcesses || model.active)
            }
            Picker("Meeting audio", selection: $model.selectedProcessID) {
                Text("Choose an app…").tag(pid_t?.none)
                ForEach(model.processOptions) { process in
                    Text("\(process.name) · PID \(process.processID)")
                        .tag(pid_t?.some(process.processID))
                }
            }
            .labelsHidden()
            .disabled(model.active || model.refreshingProcesses)
            if let process = model.selectedProcess {
                Text(process.detail)
                    .font(.caption)
                    .foregroundStyle(process.isProducingOutput ? WitnessStyle.success : WitnessStyle.warning)
            }
        }
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript language").font(.headline)
            Picker("Transcript language", selection: $model.language) {
                Text("English").tag("en")
                Text("Deutsch").tag("de")
                Text("Русский").tag("ru")
                Text("Українська").tag("uk")
            }
            .labelsHidden()
            .disabled(model.active)
        }
    }

    private var sourceHealth: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources").font(.headline)
            sourceRow("You", detail: "System microphone", systemImage: "mic", available: true)
            sourceRow("Others", detail: model.selectedProcess?.name ?? "Choose an audio app", systemImage: "waveform", available: model.selectedProcessID != nil)
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
        HStack(spacing: 8) {
            if model.active {
                Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                    .buttonStyle(WitnessSecondaryButtonStyle())
                    .disabled(model.finishing)
                Button("Stop") { model.stop() }
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .disabled(model.finishing)
                    .keyboardShortcut(.return, modifiers: [.command])
            } else {
                Button("Start meeting note") { model.start() }
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .disabled(!model.canStart)
                    .keyboardShortcut(.return, modifiers: [.command])
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
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live transcript").font(.headline)
                    Text("Recognition is delayed and may change at overlapping boundaries.")
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
                    if model.rows.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 32, weight: .light))
                                .foregroundStyle(WitnessStyle.faint)
                                .accessibilityHidden(true)
                            Text("Transcript will appear here").font(.headline)
                            Text("Start a note, then speak or play meeting audio.")
                                .font(.callout)
                                .foregroundStyle(WitnessStyle.muted)
                        }
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                                transcriptRow(row).id(index)
                            }
                        }
                        .padding(20)
                    }
                }
                .onChange(of: model.rows.count) {
                    guard followsLatest, !model.rows.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(model.rows.count - 1, anchor: .bottom)
                    }
                }
                .onChange(of: followsLatest) {
                    guard followsLatest, !model.rows.isEmpty else { return }
                    proxy.scrollTo(model.rows.count - 1, anchor: .bottom)
                }
            }
        }
        .background(WitnessStyle.raisedSurface.opacity(0.34))
    }

    private func transcriptRow(_ row: MeetingTranscriptRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timestamp(row.startFrame))
                .font(.caption.monospacedDigit())
                .foregroundStyle(WitnessStyle.faint)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(row.source == .microphone ? WitnessStyle.accent : WitnessStyle.success)
                Text(row.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(WitnessStyle.surface, in: RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius)
                .stroke(WitnessStyle.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.speaker), \(timestamp(row.startFrame)): \(row.text)")
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
final class DebugMeetingWindowController: NSObject, NSWindowDelegate {
    private let model: DebugMeetingModel
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusObservation: AnyCancellable?

    init(model: DebugMeetingModel = DebugMeetingModel()) {
        self.model = model
    }

    func show() {
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
        window.contentViewController = NSHostingController(rootView: DebugMeetingView(model: model))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        installStatusItem()
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() { model.stop() }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        window = nil
        if !model.active { removeStatusItem() }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Meeting note"
        item.button?.action = #selector(reopen)
        item.button?.target = self
        statusItem = item
        statusObservation = model.$status.sink { [weak item] status in
            Task { @MainActor in
                if status.hasPrefix("Recording") { item?.button?.title = "● Recording" }
                else if status.hasPrefix("Paused") { item?.button?.title = "Ⅱ Paused" }
                else if status.hasPrefix("Finishing") { item?.button?.title = "Finishing…" }
                else if status.localizedCaseInsensitiveContains("partial") { item?.button?.title = "Partial note" }
                else { item?.button?.title = "Meeting note" }
            }
        }
    }

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        statusObservation = nil
    }

    @objc private func reopen() { show() }
}

@MainActor
final class DogfoodNotetakerFacade: NotetakerFacade {
    private let window = DebugMeetingWindowController()

    var menuBarItem: NotetakerMenuItem? {
        NotetakerMenuItem(
            title: "Start meeting note…",
            systemImage: "note.text.badge.plus",
            action: { [weak self] in self?.window.show() }
        )
    }

    func activate() {}
    func deactivate() { window.stop() }
}
