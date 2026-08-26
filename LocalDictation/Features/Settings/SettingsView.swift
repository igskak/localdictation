import AppKit
import SwiftUI
#if DEBUG
import UniformTypeIdentifiers
#endif

struct SettingsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            boundaryTab
                .tabItem { Label("Boundary", systemImage: "waveform") }

            GlossaryView()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

            LicenseView()
                .tabItem { Label("License", systemImage: "key") }

            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 420)
        .navigationTitle("LocalDictation Settings")
    }

    private var generalTab: some View {
        Form {
            Section("Shortcut") {
                HotkeyRecorderRow()
                Picker("Mode", selection: activationBinding) {
                    ForEach(RecordingActivation.allCases) { activation in
                        Text(activation.displayName).tag(activation)
                    }
                }
                Text(coordinator.activation.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(
                    "Status",
                    value: StatusPresentation(
                        state: coordinator.state,
                        binding: coordinator.binding,
                        activation: coordinator.activation
                    ).title
                )
            }

            Section("Startup") {
                LaunchAtLoginRow()
            }

            Section("Privacy") {
                Text("Audio stays in memory on this Mac. Nothing is written to disk during normal capture and nothing is sent to a network service. A recording is discarded as soon as the app decides no review is needed, and otherwise when the review ends.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("MVP languages", value: "DE, EN, RU, UK")
            }

            Section("Insertion") {
                Toggle("Insert automatically when nothing needs review", isOn: $coordinator.insertsAutomatically)
                Text("On, a result with nothing worth checking goes straight into the application you were typing in. Off, it waits in this menu for an explicit insert. A result that does need review always waits for you either way.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Accessibility access", value: coordinator.accessibilityAuthorization == .trusted ? "Granted" : "Not granted")
                if coordinator.needsAccessibilityTrust {
                    HStack {
                        Button("Allow…") { coordinator.requestAccessibilityTrust() }
                        Button("Open Settings") { coordinator.openAccessibilitySettings() }
                        Button("Re-check") { coordinator.refreshAccessibilityAuthorization() }
                    }
                    Text("Without Accessibility access the text is copied to the clipboard instead. A development build loses this permission on every rebuild, because macOS keys it to the code signature.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Review") {
                Text("The review step appears only when a fragment is worth checking — an amount, a date, a name, a dictionary near-miss, or a word the app removed. When nothing is marked, the text is simply ready and the recording is discarded immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Phase") {
                Text("Phase 6 adds the trial, activation, and licensing. Dictation itself is unchanged: the words still go straight into the application you were typing in, and everything about them still stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let location = coordinator.preferencesLocationDescription {
                    LabeledContent("Settings file", value: location)
                        .font(.caption)
                }
                if let error = coordinator.preferencesErrorDescription {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            // A settings window closed mid-capture would otherwise leave the
            // app with no shortcut registered and no sign of why.
            coordinator.cancelHotkeyCapture()
        }
    }

    /// The picker needs a two-way binding; the coordinator owns the value and
    /// persists it, so the setter goes through its method rather than writing
    /// the property.
    private var activationBinding: Binding<RecordingActivation> {
        Binding(
            get: { coordinator.activation },
            set: { coordinator.setActivation($0) }
        )
    }

    private var boundaryTab: some View {
        Form {
            Section("Voice activity thresholds") {
                LabeledContent("Speech threshold (RMS)") {
                    Slider(
                        value: $coordinator.configuration.voiceActivity.speechThreshold,
                        in: 0.002...0.2
                    ) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("0.002")
                    } maximumValueLabel: {
                        Text("0.2")
                    }
                }
                LabeledContent(
                    "Current",
                    value: String(format: "%.3f", coordinator.configuration.voiceActivity.speechThreshold)
                )

                LabeledContent("Silence threshold (RMS)") {
                    Slider(
                        value: $coordinator.configuration.voiceActivity.silenceThreshold,
                        in: 0.001...0.2
                    )
                }
                LabeledContent(
                    "Current",
                    value: String(format: "%.3f", coordinator.configuration.voiceActivity.silenceThreshold)
                )
            }

            Section("Boundaries") {
                LabeledContent("Trailing silence") {
                    Slider(
                        value: $coordinator.configuration.voiceActivity.trailingSilenceDuration,
                        in: 0.2...5
                    )
                }
                LabeledContent(
                    "Current",
                    value: String(format: "%.1f s", coordinator.configuration.voiceActivity.trailingSilenceDuration)
                )

                LabeledContent("Maximum utterance") {
                    Slider(
                        value: $coordinator.configuration.voiceActivity.maximumUtteranceDuration,
                        in: 5...300
                    )
                }
                LabeledContent(
                    "Current",
                    value: String(format: "%.0f s", coordinator.configuration.voiceActivity.maximumUtteranceDuration)
                )
                LabeledContent(
                    "Buffer capacity",
                    value: "\(coordinator.configuration.bufferCapacityFrames) frames"
                )
            }

            Section {
                Text("Trailing silence is reported, never used to trim captured speech. Changes apply to the next recording; Phase 1 keeps settings in memory only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        Form {
            Section("Input") {
                LabeledContent("Device", value: coordinator.diagnostics.format?.inputDescription ?? "Not opened yet")
                LabeledContent("Normalized output", value: coordinator.diagnostics.format?.outputDescription ?? "16000 Hz · mono · Float32")
            }

            Section("Current buffer") {
                let snapshot = coordinator.diagnostics.snapshot
                LabeledContent("Duration", value: String(format: "%.2f s", snapshot.duration))
                LabeledContent("Frames", value: "\(snapshot.frameCount) / \(snapshot.capacityFrames)")
                LabeledContent("Utilization", value: String(format: "%.1f %%", snapshot.utilization * 100))
                LabeledContent("Peak level", value: String(format: "%.3f", snapshot.peakLevel))
                LabeledContent("Dropped frames", value: "\(snapshot.droppedFrameCount)")
                LabeledContent("Voice activity", value: snapshot.voiceActivity.state.label)
                LabeledContent("Speech start", value: snapshot.voiceActivity.speechStart.map { String(format: "%.2f s", $0) } ?? "—")
                LabeledContent("Trailing silence", value: String(format: "%.2f s", snapshot.voiceActivity.trailingSilence))
            }

            if let summary = coordinator.diagnostics.lastUtterance {
                Section("Last utterance") {
                    LabeledContent("Duration", value: String(format: "%.2f s", summary.duration))
                    LabeledContent("Frames", value: "\(summary.frameCount)")
                    LabeledContent("Sample rate", value: "\(Int(summary.sampleRate)) Hz")
                    LabeledContent("Peak level", value: String(format: "%.3f", summary.peakLevel))
                    LabeledContent("Dropped frames", value: "\(summary.droppedFrameCount)")
                    LabeledContent("End reason", value: summary.endReason.rawValue)
                }
            }

            if let risk = coordinator.diagnostics.lastRisk {
                Section("Last result") {
                    LabeledContent("Cleanup edits", value: "\(risk.editCount)")
                    LabeledContent("Edit kinds", value: risk.editKinds.isEmpty ? "\u{2014}" : risk.editKinds.joined(separator: ", "))
                    LabeledContent("Risk spans", value: "\(risk.spanCount)")
                    LabeledContent("Flagged", value: "\(risk.flaggedSpanCount)")
                    LabeledContent("Signals", value: risk.spanCategories.isEmpty ? "\u{2014}" : risk.spanCategories.joined(separator: ", "))
                    LabeledContent("Highest weight", value: String(format: "%.2f", risk.maximumWeight))
                    LabeledContent("Attention", value: risk.deservesAttention ? "Offered" : "None")
                }

                Section("Last insertion") {
                    LabeledContent("Outcome", value: coordinator.diagnostics.lastInsertion?.outcome ?? "\u{2014}")
                    LabeledContent("Target", value: coordinator.diagnostics.lastInsertion?.targetIdentity ?? "\u{2014}")
                    Text("The method and the application, which is what anyone asks first when an app misbehaves. The inserted text appears nowhere in here and in no log line.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Audio lifetime") {
                    LabeledContent("Retained frames", value: "\(coordinator.retainedAudioFrameCount)")
                    Text("A recording is held only while a review can still use it. Zero here means the app is no longer holding the last utterance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = coordinator.diagnostics.lastErrorDescription {
                Section("Last error") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            #if DEBUG
            Section("Debug export") {
                Button("Export last utterance as WAV…") {
                    exportLastUtterance()
                }
                .disabled(coordinator.diagnostics.lastUtterance == nil)

                Text("Debug builds only. Writes a file solely to the location you choose in the save panel; normal capture never touches the file system.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
    }

    #if DEBUG
    @MainActor
    private func exportLastUtterance() {
        guard let data = coordinator.makeDebugWAVData() else { return }

        let panel = NSSavePanel()
        panel.title = "Export last utterance"
        panel.nameFieldStringValue = "localdictation-utterance.wav"
        panel.allowedContentTypes = [UTType.wav]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            Log.audio.notice("Debug export written to a user-selected location")
        } catch {
            Log.audio.error("Debug export failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}

/// The user's vocabulary, scoped by language.
///
/// The only screen in the app that writes anything to disk. It stores terms and
/// their language — never a transcript, never audio.
struct GlossaryView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    @State private var term = ""
    @State private var language: SpeechLanguage = .german

    var body: some View {
        Form {
            Section("Add a term") {
                HStack {
                    TextField("Name, product, or term", text: $term)
                        .onSubmit(add)
                    Picker("", selection: $language) {
                        ForEach(SpeechLanguage.allCases, id: \.self) { language in
                            Text(language.rawValue.uppercased()).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    Button("Add", action: add)
                        .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("A word that comes out close to one of your terms, but not equal to it, is marked for review. An exact match is not: it came out right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(SpeechLanguage.allCases, id: \.self) { language in
                let entries = coordinator.glossary.entries(for: language)
                if !entries.isEmpty {
                    Section(language.displayName) {
                        ForEach(entries) { entry in
                            HStack {
                                Text(entry.term)
                                Spacer()
                                Button {
                                    coordinator.removeGlossaryTerm(id: entry.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this term")
                            }
                        }
                    }
                }
            }

            if coordinator.glossary.entries.isEmpty {
                Section {
                    Text("No terms yet. Add the names and words you dictate often and would notice being wrong.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Storage") {
                if let location = coordinator.glossaryLocationDescription {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("This file is the only thing the app persists. Transcripts and recordings stay in memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = coordinator.glossaryErrorDescription {
                Section("Last error") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        guard coordinator.addGlossaryTerm(term, language: language) else { return }
        term = ""
    }
}

/// The control that takes a new shortcut.
///
/// A local key monitor rather than a first-responder `NSView`: the app already
/// has one global hotkey mechanism, and adding a second event path for a
/// control the user touches twice a year is more machinery than the job needs.
/// The monitor only ever runs while the button has been pressed, it consumes
/// the key so nothing else in the settings window reacts to it, and the
/// coordinator has unregistered the existing shortcut for the duration — so
/// what the user presses is what they get, including the shortcut they already
/// have.
private struct HotkeyRecorderRow: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var monitor: Any?
    @State private var failure: String?

    var body: some View {
        LabeledContent("Shortcut") {
            HStack(spacing: 8) {
                Text(coordinator.isCapturingHotkey ? "Press a combination…" : coordinator.binding.displayString)
                    .font(.body.monospaced())
                    .foregroundStyle(coordinator.isCapturingHotkey ? Color.accentColor : .primary)

                Spacer()

                if coordinator.isCapturingHotkey {
                    Button("Cancel") { stopCapture(cancelling: true) }
                } else {
                    Button("Change…") { startCapture() }
                    Button("Reset") {
                        failure = nil
                        coordinator.resetHotkey()
                    }
                    .disabled(coordinator.binding == .optionSpace)
                }
            }
        }

        if coordinator.registeredHotkey == nil, !coordinator.isCapturingHotkey {
            Text("The shortcut is not registered, so the hotkey does nothing. Pick another combination.")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let failure {
            Text(failure)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("At least one of ⌘ ⌥ ⌃ ⇧ is required. A bare key would be taken away from every application on this Mac.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func startCapture() {
        failure = nil
        coordinator.beginHotkeyCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
            // Swallowed: a settings window that types the user's shortcut into
            // whatever had focus is not what they asked for.
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 { // Escape leaves the shortcut alone.
            stopCapture(cancelling: true)
            return
        }

        let candidate = HotkeyBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: HotkeyModifiers(event.modifierFlags),
            keyLabel: HotkeyKeyLabel.label(
                forKeyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers
            )
        )

        removeMonitor()
        if let error = coordinator.finishHotkeyCapture(with: candidate) {
            failure = "\(candidate.displayString) cannot be used: \(error.message)."
        } else {
            failure = nil
        }
    }

    private func stopCapture(cancelling: Bool) {
        removeMonitor()
        if cancelling { coordinator.cancelHotkeyCapture() }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

/// Whether the app is there when the user logs in.
private struct LaunchAtLoginRow: View {
    @StateObject private var controller = LaunchAtLoginController()

    var body: some View {
        Toggle(
            "Open at login",
            isOn: Binding(
                get: { controller.state.isEnabled },
                set: { controller.setEnabled($0) }
            )
        )
        .disabled(isRefused)

        Text("An app with no Dock icon is one nobody remembers to open, and a hotkey belonging to an app that is not running reads as a broken hotkey.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let explanation = controller.state.explanation {
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            if controller.state == .requiresApproval {
                HStack {
                    Button("Open Login Items") { controller.openSystemSettings() }
                    Button("Re-check") { controller.refresh() }
                }
            }
        }
    }

    private var isRefused: Bool {
        if case .unavailable = controller.state { return true }
        return controller.state == .requiresApproval
    }
}
