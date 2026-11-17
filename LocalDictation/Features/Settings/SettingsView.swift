import AppKit
import SwiftUI
#if DEBUG
import UniformTypeIdentifiers
#endif

enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation
    case speechModel
    case languages, cleanup, dictionary, privacy, license, updates, diagnostics, audio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .speechModel: "Speech model"
        case .dictation: "Dictation"
        case .languages: "Languages"
        case .cleanup: "Text cleanup"
        case .dictionary: "Dictionary"
        case .privacy: "Privacy"
        case .license: "License"
        case .updates: "Updates"
        case .diagnostics: "Diagnostics"
        case .audio: "Audio tuning"
        }
    }
    var symbol: String {
        switch self {
        case .speechModel: "cpu"
        case .dictation: "mic"
        case .languages: "globe"
        case .cleanup: "slider.horizontal.3"
        case .dictionary: "character.book.closed"
        case .privacy: "hand.raised"
        case .license: "key"
        case .updates: "arrow.down.circle"
        case .diagnostics: "stethoscope"
        case .audio: "waveform"
        }
    }
}

/// A request survives the Settings window being constructed after the action.
/// Nothing is persisted; an already-open window also receives the request.
@MainActor
enum SettingsNavigation {
    static let didRequest = Notification.Name("WitnessSettingsDestinationRequested")
    private static var pending: SettingsSection?

    static func request(_ section: SettingsSection) {
        pending = section
        NotificationCenter.default.post(name: didRequest, object: nil)
    }

    static func consume() -> SettingsSection? {
        defer { pending = nil }
        return pending
    }
}

struct SettingsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject private var updater: AppUpdater
    @ObservedObject private var modelSelection: SpeechModelSelection
    @State private var availableAudioInputs: [SystemAudioInput.Device] = []
    @State private var selection: SettingsSection = .dictation

    init(initialSelection: SettingsSection = .dictation, updater: AppUpdater = .shared, modelSelection: SpeechModelSelection = .shared) {
        _selection = State(initialValue: initialSelection)
        self.updater = updater
        self.modelSelection = modelSelection
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(selection.title))
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.6)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                page
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 600, idealHeight: 700)
        .witnessWindow()
        .navigationTitle("Witness Settings")
        .onAppear {
            refreshAudioInputs()
            if let requested = SettingsNavigation.consume() { selection = requested }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigation.didRequest)) { _ in
            if let requested = SettingsNavigation.consume() { selection = requested }
        }
        .onChange(of: selection) { coordinator.cancelHotkeyCapture() }
        .onDisappear { coordinator.cancelHotkeyCapture() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            WitnessBrand().padding(.horizontal, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsSection.allCases) { section in
                        Button {
                            selection = section
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.symbol)
                                    .frame(width: 20)
                                    .accessibilityHidden(true)
                                Text(LocalizedStringKey(section.title))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .font(.callout.weight(selection == section ? .semibold : .regular))
                            .foregroundStyle(selection == section ? WitnessStyle.accent : WitnessStyle.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selection == section ? WitnessStyle.accent.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == section ? [.isSelected] : [])
                        .padding(.top, section == .diagnostics ? 16 : 0)
                    }
                }
            }
            Spacer(minLength: 0)
            Label("On this Mac", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 28)
        .frame(width: 215)
        .background(WitnessStyle.sidebar)
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .speechModel:
            SpeechModelSettingsView(notetakerStatus: AppDelegate.notetaker?.status ?? NotetakerStatus(), selection: modelSelection)
        case .dictation: dictationPage
        case .languages: LanguagesView()
        case .cleanup: cleanupPage
        case .dictionary: GlossaryView()
        case .privacy: privacyPage
        case .license: LicenseView()
        case .updates: updatesPage
        case .diagnostics: DiagnosticsView()
        case .audio: BoundarySettingsView()
        }
    }

    private var dictationPage: some View {
        WitnessSettingsForm {
            WitnessSettingsSection("Shortcut") {
                HotkeyRecorderRow()
                LabeledContent("Mode") {
                    Picker("Mode", selection: activationBinding) {
                        ForEach(RecordingActivation.allCases) { activation in
                            Text(activation.displayName).tag(activation)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text(coordinator.activation.explanation)
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WitnessSettingsSection("Microphone") {
                LabeledContent("Input source") {
                    Picker("Input source", selection: audioInputBinding) {
                        Text("Mac built-in microphone").tag(AudioInputSelection.builtIn)
                        Text("macOS default input").tag(AudioInputSelection.systemDefault)
                        ForEach(availableAudioInputs) { device in
                            Text(device.name).tag(AudioInputSelection.device(uid: device.uid))
                        }
                        if case let .device(uid) = coordinator.audioInputSelection,
                           !availableAudioInputs.contains(where: { $0.uid == uid }) {
                            Text("Previously selected microphone (unavailable)").tag(AudioInputSelection.device(uid: uid))
                        }
                    }
                    .labelsHidden()
                }
                Button("Refresh microphones") { refreshAudioInputs() }
                if case let .device(uid) = coordinator.audioInputSelection,
                   !availableAudioInputs.contains(where: { $0.uid == uid }) {
                    Text("The selected microphone is unavailable. Witness will use another available microphone until it returns.")
                        .font(.callout).foregroundStyle(WitnessStyle.warning)
                }
                if coordinator.audioInputSelection == .builtIn,
                   !availableAudioInputs.contains(where: \.isBuiltIn) {
                    Text("The Mac microphone is unavailable. Witness will use another available microphone.")
                        .font(.callout).foregroundStyle(WitnessStyle.warning)
                }
                Text("Microphone changes apply to the next recording.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
            }
            WitnessSettingsSection("Insertion") {
                Toggle("Insert text automatically", isOn: $coordinator.insertsAutomatically)
                Text("When enabled, text is inserted at your cursor. Any review marks remain available afterwards.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                LabeledContent("Accessibility access", value: L10n.string(coordinator.accessibilityAuthorization == .trusted ? "Granted" : "Not granted"))
                if coordinator.needsAccessibilityTrust {
                    HStack {
                        Button("Allow…") { coordinator.requestAccessibilityTrust() }
                        Button("Open Settings") { coordinator.openAccessibilitySettings() }
                        Button("Re-check") { coordinator.refreshAccessibilityAuthorization() }
                    }
                    Text("Without Accessibility access, you can copy your dictation and paste it into another app.")
                        .font(.callout).foregroundStyle(WitnessStyle.muted)
                }
            }
            WitnessSettingsSection("Startup") { LaunchAtLoginRow() }
            if let error = coordinator.preferencesErrorDescription {
                WitnessSettingsSection("Last error") { Text(error).foregroundStyle(WitnessStyle.warning) }
            }
        }
        .witnessSettingsForm()
    }

    private var cleanupPage: some View {
        WitnessSettingsForm {
            WitnessSettingsSection("Cleanup") {
                Picker("Level", selection: cleanupLevelBinding) {
                    ForEach(CleanupLevel.allCases) { level in Text(level.displayName).tag(level) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Cleanup level")
                Text(coordinator.cleanupLevel.explanation)
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WitnessSettingsSection("Example (English)") {
                Text(coordinator.cleanupLevel.example)
                    .font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WitnessSettingsSection("Review") {
                Text("Witness marks details worth checking, such as amounts, dates, names and cleanup changes. A mark is a prompt to check, not a verdict.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                Text("All cleanup runs on this Mac. Raw recognized text remains available in review.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
            }
        }.witnessSettingsForm()
    }

    private var privacyPage: some View {
        WitnessSettingsForm {
            WitnessSettingsSection("On this Mac") {
                Label("Speech recognition and text cleanup run locally.", systemImage: "lock.shield")
                Text("Audio stays in memory until processing or review ends. Recordings and transcripts are not saved or sent to a server.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
            }
            WitnessSettingsSection("Product events") {
                Toggle("Share setup and trial events", isOn: $coordinator.sharesProductEvents)
                Text("Nine event types help us understand setup and the trial. They never include your audio, text, dictionary or app contents.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                DisclosureGroup("What is shared") {
                    Text("Shared events cover installation; model download start, completion or failure; attempts before the model is ready; microphone denial; trial start; the email prompt; and offers shown. Each includes the app version, macOS version and a random installation ID. The six setup events are sent once per installation. Turning this off stops all nine event types.")
                        .font(.callout).foregroundStyle(WitnessStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            WitnessSettingsSection("Privacy policy") {
                Link("Read the privacy policy", destination: URL(string: "https://witnessmac.com/en/privacy")!)
                Text("The policy lists what is sent for activation, payments, updates and product events, who receives it and how long it is kept.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
            }
        }.witnessSettingsForm()
    }

    private var updatesPage: some View {
        WitnessSettingsForm {
            WitnessSettingsSection("Updates") {
                LabeledContent("Installed version", value: AppVersion.short)
                Button("Check for updates…") { updater.checkForUpdates() }
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .disabled(!updater.canCheckForUpdates)
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                Text("Witness checks GitHub for updates once a day. You choose when to install them.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
            }
        }.witnessSettingsForm()
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

    private var audioInputBinding: Binding<AudioInputSelection> {
        Binding(
            get: { coordinator.audioInputSelection },
            set: { coordinator.setAudioInputSelection($0) }
        )
    }

    private var cleanupLevelBinding: Binding<CleanupLevel> {
        Binding(
            get: { coordinator.cleanupLevel },
            set: { coordinator.cleanupLevel = $0 }
        )
    }

    private func refreshAudioInputs() {
        availableAudioInputs = SystemAudioInput.availableInputDevices()
    }

}

struct BoundarySettingsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        WitnessSettingsForm {
            WitnessSettingsSection("Voice activity thresholds") {
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
                    value: L10n.format("%.3f", coordinator.configuration.voiceActivity.speechThreshold)
                )

                LabeledContent("Silence threshold (RMS)") {
                    Slider(
                        value: $coordinator.configuration.voiceActivity.silenceThreshold,
                        in: 0.001...0.2
                    )
                }
                LabeledContent(
                    "Current",
                    value: L10n.format("%.3f", coordinator.configuration.voiceActivity.silenceThreshold)
                )
            }

            WitnessSettingsSection("Boundaries") {
                LabeledContent("Trailing silence") {
                    Slider(
                        value: $coordinator.configuration.voiceActivity.trailingSilenceDuration,
                        in: 0.2...5
                    )
                }
                LabeledContent(
                    "Current",
                    value: L10n.format("%.1f s", coordinator.configuration.voiceActivity.trailingSilenceDuration)
                )

                LabeledContent("Maximum utterance") {
                    Slider(
                        value: $coordinator.configuration.voiceActivity.maximumUtteranceDuration,
                        in: 5...600
                    )
                }
                LabeledContent(
                    "Current",
                    value: L10n.format("%.0f s", coordinator.configuration.voiceActivity.maximumUtteranceDuration)
                )
                LabeledContent(
                    "Buffer capacity",
                    value: L10n.format(
                        "%lld frames",
                        Int64(coordinator.configuration.bufferCapacityFrames)
                    )
                )
            }

            WitnessSettingsSection {
                Text("These settings apply to the next recording and reset when Witness restarts. Trailing silence is measured but never used to trim speech.")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
            }
        }
        .background(WitnessStyle.canvas)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        WitnessSettingsForm {
            WitnessSettingsSection("Input") {
                LabeledContent("Device", value: coordinator.diagnostics.format?.inputDescription ?? L10n.string("Not opened yet"))
                LabeledContent(
                    "Normalized output",
                    value: coordinator.diagnostics.format?.outputDescription
                        ?? L10n.format("%1$lld Hz · mono · Float32", Int64(AudioTargetFormat.sampleRate))
                )
            }

            WitnessSettingsSection("Current buffer") {
                let snapshot = coordinator.diagnostics.snapshot
                LabeledContent("Duration", value: L10n.format("%.2f s", snapshot.duration))
                LabeledContent(
                    "Frames",
                    value: L10n.format(
                        "%1$lld / %2$lld",
                        Int64(snapshot.frameCount),
                        Int64(snapshot.capacityFrames)
                    )
                )
                LabeledContent("Utilization", value: L10n.format("%.1f %%", snapshot.utilization * 100))
                LabeledContent("Peak level", value: L10n.format("%.3f", snapshot.peakLevel))
                LabeledContent("Dropped frames", value: L10n.format("%lld", Int64(snapshot.droppedFrameCount)))
                LabeledContent("Voice activity", value: snapshot.voiceActivity.state.label)
                LabeledContent("Speech start", value: snapshot.voiceActivity.speechStart.map { L10n.format("%.2f s", $0) } ?? "—")
                LabeledContent("Trailing silence", value: L10n.format("%.2f s", snapshot.voiceActivity.trailingSilence))
            }

            if let summary = coordinator.diagnostics.lastUtterance {
                WitnessSettingsSection("Last utterance") {
                    LabeledContent("Duration", value: L10n.format("%.2f s", summary.duration))
                    LabeledContent("Frames", value: L10n.format("%lld", Int64(summary.frameCount)))
                    LabeledContent("Sample rate", value: L10n.format("%lld Hz", Int64(summary.sampleRate.rounded())))
                    LabeledContent("Peak level", value: L10n.format("%.3f", summary.peakLevel))
                    LabeledContent("Dropped frames", value: L10n.format("%lld", Int64(summary.droppedFrameCount)))
                    LabeledContent("End reason", value: summary.endReason.label)
                }
            }

            if let risk = coordinator.diagnostics.lastRisk {
                WitnessSettingsSection("Last result") {
                    LabeledContent("Cleanup edits", value: L10n.format("%lld", Int64(risk.editCount)))
                    LabeledContent("Edit kinds", value: risk.editKinds.isEmpty ? "\u{2014}" : risk.editKinds.joined(separator: ", "))
                    LabeledContent("Risk spans", value: L10n.format("%lld", Int64(risk.spanCount)))
                    LabeledContent("Flagged", value: L10n.format("%lld", Int64(risk.flaggedSpanCount)))
                    LabeledContent("Signals", value: risk.spanCategories.isEmpty ? "\u{2014}" : risk.spanCategories.joined(separator: ", "))
                    LabeledContent("Highest weight", value: L10n.format("%.2f", risk.maximumWeight))
                    LabeledContent("Attention", value: L10n.string(risk.deservesAttention ? "Offered" : "None"))
                }

                WitnessSettingsSection("Last insertion") {
                    LabeledContent("Outcome", value: coordinator.diagnostics.lastInsertion?.outcome ?? "\u{2014}")
                    LabeledContent("Target", value: coordinator.diagnostics.lastInsertion?.targetIdentity ?? "\u{2014}")
                    Text("Shows the insertion method and target app. Dictated text is not included in diagnostics or logs.")
                        .font(.callout)
                        .foregroundStyle(WitnessStyle.muted)
                }

                WitnessSettingsSection("Audio lifetime") {
                    LabeledContent(
                        "Retained frames",
                        value: L10n.format("%lld", Int64(coordinator.retainedAudioFrameCount))
                    )
                    Text("Audio is kept in memory while review is available. Zero means the last recording has been released.")
                        .font(.caption)
                        .foregroundStyle(WitnessStyle.muted)
                }
            }

            if let error = coordinator.diagnostics.lastErrorDescription {
                WitnessSettingsSection("Last error") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(WitnessStyle.warning)
                }
            }

            #if DEBUG
            WitnessSettingsSection("Debug export") {
                Button("Export last utterance as WAV…") {
                    exportLastUtterance()
                }
                .disabled(coordinator.diagnostics.lastUtterance == nil)

                Text("Debug builds only. Writes a file solely to the location you choose in the save panel; normal capture never touches the file system.")
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
            }
            #endif
        }
        .background(WitnessStyle.canvas)
    }

    #if DEBUG
    @MainActor
    private func exportLastUtterance() {
        guard let data = coordinator.makeDebugWAVData() else { return }

        let panel = NSSavePanel()
        panel.title = L10n.string("Export last utterance")
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

/// The languages the user speaks, after the first run has asked.
///
/// The same editor as the first-run window, because it is the same question. A
/// tab of its own rather than a section in General: a hundred languages is a
/// list, and a list does not belong inside a form of switches.
private struct LanguagesView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                WitnessIconTile(systemImage: "globe", tint: WitnessStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your languages")
                        .font(.headline)
                    Text("Witness recognizes the languages you select.")
                        .font(.caption)
                        .foregroundStyle(WitnessStyle.muted)
                }
            }

            LanguageSelectionEditor(selection: $coordinator.languageProfile)

            Text("Choose the languages you use regularly. A smaller selection can help with short or similar-sounding phrases.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(WitnessStyle.canvas)
    }
}

/// The user's vocabulary, scoped by language.
///
/// The only screen in the app that writes anything to disk. It stores terms and
/// their language — never a transcript, never audio.
struct GlossaryView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    @State private var term = ""
    @State private var replacement = ""
    /// Nil until the user picks one, which is what lets the picker follow the
    /// preferred language instead of a hardcoded German.
    @State private var language: SpeechLanguage?

    var body: some View {
        WitnessSettingsForm {
            WitnessSettingsSection("Add a term or correction") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Preferred spelling or phrase", text: $term)
                        .onSubmit(add)
                    TextField("Optional: when Witness writes…", text: $replacement)
                        .onSubmit(add)
                    HStack {
                        Text(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "Mark similar spellings"
                             : "Replace the second phrase with the preferred spelling")
                            .font(.caption)
                            .foregroundStyle(WitnessStyle.muted)
                        Spacer()
                    Picker("", selection: chosenLanguage) {
                        // The languages the user speaks, not a fixed four. A
                        // term is scoped by language, so offering a language
                        // they never dictate in would file it where no
                        // utterance can reach it.
                        ForEach(coordinator.languageProfile.languages) { language in
                            Text(language.rawValue.uppercased()).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    Button("Add", action: add)
                        .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Text("Add a correction to replace a specific phrase. Without one, the term is only used to flag similar spellings. Your dictionary stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
            }

            // Every language that has terms, including one the user has since
            // deselected: a list that hid them would look like the terms were
            // gone, and they are not.
            ForEach(languagesWithTerms) { language in
                let entries = coordinator.glossary.entries(for: language)
                if !entries.isEmpty {
                    WitnessSettingsSection(language.displayName) {
                        ForEach(entries) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.term)
                                    if let trigger = entry.normalizedReplacement {
                                        Text(verbatim: L10n.format(
                                            "When Witness writes “%@”, replace it with “%@”.",
                                            trigger,
                                            entry.normalizedTerm
                                        ))
                                            .font(.caption)
                                            .foregroundStyle(WitnessStyle.muted)
                                    }
                                }
                                Spacer()
                                Button {
                                    coordinator.removeGlossaryTerm(id: entry.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove this term")
                                .help("Remove this term")
                            }
                        }
                    }
                }
            }

            if coordinator.glossary.entries.isEmpty {
                WitnessSettingsSection {
                    Text("Add names, words or phrases you use often.")
                        .font(.callout)
                        .foregroundStyle(WitnessStyle.muted)
                }
            }

            WitnessSettingsSection("Storage") {
                if let location = coordinator.glossaryLocationDescription {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(WitnessStyle.muted)
                        .textSelection(.enabled)
                }
                Text("Your dictionary is saved on this Mac. Recordings and transcripts stay in memory.")
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
            }

            if let error = coordinator.glossaryErrorDescription {
                WitnessSettingsSection("Last error") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(WitnessStyle.warning)
                }
            }
        }
        .background(WitnessStyle.canvas)
    }

    /// The language a new term is filed under: the one the user picked, while
    /// they still speak it, and otherwise their preferred language.
    private var chosenLanguage: Binding<SpeechLanguage> {
        Binding(
            get: {
                guard let language, coordinator.languageProfile.contains(language) else {
                    return coordinator.languageProfile.primary
                }
                return language
            },
            set: { language = $0 }
        )
    }

    /// Every language that has terms in it, including one the user has since
    /// deselected — a list that hid those would look like the terms were gone.
    private var languagesWithTerms: [SpeechLanguage] {
        Set(coordinator.glossary.entries.map(\.language)).sorted()
    }

    private func add() {
        guard coordinator.addGlossaryTerm(
            term,
            replacement: replacement,
            language: chosenLanguage.wrappedValue
        ) else { return }
        term = ""
        replacement = ""
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
struct HotkeyRecorderRow: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var monitor: Any?
    @State private var failure: String?
    @State private var saved = false
    @State private var captureSession = HotkeyCaptureSession()
    private var pendingBinding: HotkeyBinding? { coordinator.pendingHotkeyBinding }

    var body: some View {
        Group {
            content
        }
        // The monitor is a system-wide registration, not a piece of view state:
        // a settings window closed mid-capture would leave it installed,
        // swallowing every key this app's windows ever see afterwards. The
        // coordinator's own cancel does not cover this — it puts the shortcut
        // back and knows nothing about the monitor.
        .onDisappear { stopCapture(cancelling: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if let pendingBinding, coordinator.hotkeySelectionError == .keyboardAccessRequired, CGPreflightListenEventAccess() { apply(pendingBinding) }
        }
    }

    @ViewBuilder
    private var content: some View {
        LabeledContent("Activation key") {
            HStack(spacing: 8) {
                Text(verbatim: coordinator.isCapturingHotkey ? L10n.string("Press a key or combination…") : coordinator.binding.displayString)
                    .font(.body.monospaced())
                    .foregroundStyle(coordinator.isCapturingHotkey ? Color.accentColor : .primary)

                Spacer()

                if coordinator.isCapturingHotkey {
                    Button("Cancel") { stopCapture(cancelling: true) }
                } else {
                    Button("Change…") { startCapture() }
                    Button("Reset") {
                        failure = nil
                        saved = false
                        coordinator.resetHotkey()
                        saved = coordinator.registeredHotkey == coordinator.binding && coordinator.preferencesErrorDescription == nil
                    }
                    .disabled(coordinator.binding == .optionSpace)
                }
            }
        }

        if let pendingBinding, coordinator.hotkeySelectionError == .keyboardAccessRequired {
            Text("To use this key on its own, allow keyboard access in macOS. You can also choose a combination instead.")
                .font(.callout).foregroundStyle(WitnessStyle.muted)
            HStack {
                Button("Allow keyboard access…") { _ = CGRequestListenEventAccess() }
                Button("Check again") { apply(pendingBinding) }
            }
        }

        if pendingBinding != nil, coordinator.registeredHotkey == coordinator.binding {
            Button("Keep current shortcut") {
                coordinator.keepCurrentHotkey()
                failure = coordinator.preferencesErrorDescription
                saved = false
            }
        }

        if coordinator.registeredHotkey == nil, !coordinator.isCapturingHotkey, pendingBinding == nil {
            Text("This key isn’t ready to use yet. Check keyboard access or choose another shortcut.")
                .font(.callout)
                .foregroundStyle(WitnessStyle.warning)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let failure {
            Text(failure)
                .font(.callout)
                .foregroundStyle(WitnessStyle.warning)
                .fixedSize(horizontal: false, vertical: true)
        }

        if saved {
            Text("Saved. Your shortcut is ready to use.")
                .font(.callout)
                .foregroundStyle(WitnessStyle.success)
                .accessibilityAddTraits(.updatesFrequently)
        }

        Text(verbatim: L10n.string(coordinator.isCapturingHotkey
             ? "Press and release a key such as ⌥, or press a combination. It saves automatically. Escape cancels."
             : "Use ⌘, ⌥, ⌃, ⇧ or Fn on its own, or a key combination. Letters, numbers and Space need a modifier."))
            .font(.callout)
            .foregroundStyle(WitnessStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func startCapture() {
        failure = nil
        saved = false
        captureSession = HotkeyCaptureSession()
        // Defensive: one monitor at a time, whatever the view did.
        removeMonitor()
        coordinator.beginHotkeyCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            capture(event)
            // Swallowed: a settings window that types the user's shortcut into
            // whatever had focus is not what they asked for.
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if let candidate = captureSession.modifierChanged(
                keyCode: UInt32(event.keyCode), activeModifierCount: relevant.rawValue.nonzeroBitCount
            ) { apply(candidate) }
            return
        }
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

        apply(candidate)
    }

    private func apply(_ candidate: HotkeyBinding) {
        removeMonitor()
        saved = false
        if let error = coordinator.finishHotkeyCapture(with: candidate) {
            if error == .keyboardAccessRequired {
                failure = nil
            } else {
                failure = L10n.format("%1$@ cannot be used: %2$@.", candidate.displayString, error.message)
            }
        } else {
            failure = coordinator.preferencesErrorDescription
            saved = failure == nil && coordinator.registeredHotkey == candidate
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

        Text("Witness needs to be running for your shortcut to work.")
            .font(.callout)
            .foregroundStyle(WitnessStyle.muted)
            .fixedSize(horizontal: false, vertical: true)

        if let explanation = controller.state.explanation {
            Text(explanation)
                .font(.callout)
                .foregroundStyle(WitnessStyle.warning)
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
