#if DEBUG
import AppKit
import Combine
import SwiftUI

@MainActor
final class DebugMeetingModel: ObservableObject {
    @Published var processID = ""
    @Published var language = "en"
    @Published var consent = false
    @Published var status = "Ready — no audio is being captured."
    @Published var rows: [MeetingTranscriptRow] = []
    @Published var metrics = ""
    @Published var active = false
    private var session: DebugMeetingSession?
    private var generation = UUID()
    private let permission = AVCaptureMicrophonePermissionService()

    func start() {
        guard !active, consent, let pid = pid_t(processID), pid > 0 else { return }
        let profile: LanguageProfile
        switch language {
        case "de": profile = .german
        case "ru": profile = .russian
        case "uk": profile = .ukrainian
        default: profile = .english
        }
        active = true
        let currentGeneration = UUID()
        generation = currentGeneration
        rows = []
        metrics = ""
        status = "Checking microphone permission…"
        Task { [self] in
            let authorization = permission.currentAuthorization == .notDetermined
                ? await permission.requestAccess() : permission.currentAuthorization
            guard active, generation == currentGeneration else { return }
            guard authorization == .authorized else {
                status = "Microphone access is unavailable. Enable it in System Settings."
                active = false
                return
            }
            let meeting = DebugMeetingSession(profile: profile) { [weak self] update in
                Task { @MainActor [weak self] in self?.receive(update) }
            }
            session = meeting
            do { try await meeting.start(processID: pid) }
            catch {
                status = "Could not start. Check the model, selected audio process and permissions."
                active = false
                session = nil
            }
        }
    }

    func stop() {
        guard let session else {
            generation = UUID()
            active = false
            status = "Stopped — no audio was captured."
            return
        }
        status = "Finishing the transcript…"
        Task { await session.stop() }
    }

    private func receive(_ update: DebugMeetingUpdate) {
        switch update {
        case let .status(value): status = value
        case let .rows(value): rows = value
        case let .metrics(value): metrics = value
        case let .finished(partial):
            status = partial ? "Partial transcript — some audio could not be processed." : "Stopped — transcript is held in memory."
            active = false
            session = nil
        }
    }
}

struct DebugMeetingView: View {
    @ObservedObject var model: DebugMeetingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting audio test").font(.title2.bold())
            Text(model.status).accessibilityLabel("Status: \(model.status)")
            Text("Audio stays in memory. Make sure participants have received any required notice or consent. Chrome audio can include other tabs.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Audio process ID", text: $model.processID).frame(width: 150).disabled(model.active)
                Picker("Language", selection: $model.language) {
                    Text("English").tag("en"); Text("Deutsch").tag("de")
                    Text("Русский").tag("ru"); Text("Українська").tag("uk")
                }.frame(width: 180).disabled(model.active)
            }
            Toggle("I will provide the required participant notice or consent", isOn: $model.consent).disabled(model.active)
            HStack {
                Button("Start", action: model.start)
                    .disabled(model.active || !model.consent || (pid_t(model.processID) ?? 0) <= 0)
                Button("Stop", action: model.stop).disabled(!model.active)
            }
            if !model.metrics.isEmpty {
                Text(model.metrics).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if model.rows.isEmpty {
                Text("Transcript will appear here after speech is processed.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.speaker).font(.headline)
                                Text(row.text).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(20).frame(minWidth: 520, minHeight: 400)
    }
}

@MainActor
final class DebugMeetingWindowController: NSObject, NSWindowDelegate {
    private let model = DebugMeetingModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusObservation: AnyCancellable?
    func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Meeting test"
        statusItem = item
        statusObservation = model.$status.sink { [weak item] status in
            Task { @MainActor in
                if status.hasPrefix("Recording") { item?.button?.title = "Recording" }
                else if status.hasPrefix("Finishing") { item?.button?.title = "Finishing" }
                else if status.localizedCaseInsensitiveContains("partial") { item?.button?.title = "Partial" }
                else { item?.button?.title = "Meeting test" }
            }
        }
        window.title = "Witness meeting audio test"
        window.contentViewController = NSHostingController(rootView: DebugMeetingView(model: model))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        model.stop()
        // The item stays visible while the asynchronous stop is completing.
    }
}
#endif
