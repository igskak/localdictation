import SwiftUI

/// The selection while it is being made.
///
/// Owned by the window controller rather than by the view, so the selection
/// survives the view being rebuilt and the controller can read it when Continue
/// is pressed. Closing the window answers nothing — see
/// `LanguageSetupWindowController`.
@MainActor
final class LanguageSetupModel: ObservableObject {
    /// Which of the two first-run screens is up.
    ///
    /// One window rather than two, because they are one errand: the question,
    /// and then what to do now that it is answered. A second window would be a
    /// second thing to dismiss.
    enum Step: Sendable, Equatable {
        case welcome
        case languages
        case ready
    }

    @Published var page = 0
    @Published var usesClipboardOnly = false
    @Published var isInteractive = true
    @Published var selection: LanguageProfile
    @Published var step: Step = .languages
    /// Whether the app should open itself at login, as the second screen shows
    /// it. On by default, and decided when the window closes rather than when
    /// the switch is flipped: see `LanguageSetupWindowController`.
    @Published var opensAtLogin = true
    @Published var notificationMessage = "Get a macOS notification when the model is ready."

    init(selection: LanguageProfile) {
        self.selection = selection
    }
    func insertionChoiceIsReady(using coordinator: DictationCoordinator) -> Bool {
        !coordinator.needsAccessibilityTrust || usesClipboardOnly
    }

    func testPrerequisitesAreReady(using coordinator: DictationCoordinator) -> Bool {
        !coordinator.needsLanguageSetup && coordinator.microphoneAuthorization == .authorized
            && coordinator.isHotkeySelectionReady && coordinator.transcriptionModelState.isReady
            && insertionChoiceIsReady(using: coordinator)
    }

    func canAdvance(using coordinator: DictationCoordinator) -> Bool {
        switch page {
        case 0: coordinator.microphoneAuthorization == .authorized
        case 1: insertionChoiceIsReady(using: coordinator)
        case 2: insertionChoiceIsReady(using: coordinator) && coordinator.isHotkeySelectionReady
        case 3: testPrerequisitesAreReady(using: coordinator)
        case 4: testPrerequisitesAreReady(using: coordinator) && !coordinator.onboardingTestText.isEmpty
        default: true
        }
    }

    func synchronizeReadiness(using coordinator: DictationCoordinator) {
        if page == 3 && coordinator.transcriptionModelState.isReady { page = 4 }
        guard page == 4 else { return }
        if isInteractive && testPrerequisitesAreReady(using: coordinator) {
            if !coordinator.isOnboardingTest && coordinator.onboardingTestText.isEmpty {
                coordinator.beginOnboardingTest()
            }
        } else if coordinator.isOnboardingTest {
            coordinator.endOnboardingTest(preserveResult: true)
        }
    }

    func advance(using coordinator: DictationCoordinator) {
        guard canAdvance(using: coordinator), page < 5 else { return }
        clearTest(using: coordinator)
        page += 1
        synchronizeReadiness(using: coordinator)
    }

    func continueWithClipboard(using coordinator: DictationCoordinator) {
        usesClipboardOnly = true
        advance(using: coordinator)
    }

    func clearTest(using coordinator: DictationCoordinator) {
        if coordinator.isOnboardingTest || !coordinator.onboardingTestText.isEmpty {
            coordinator.endOnboardingTest()
        }
    }

    func showRequiredSetup(using coordinator: DictationCoordinator) {
        clearTest(using: coordinator)
        if coordinator.needsLanguageSetup { step = .languages }
        else if coordinator.microphoneAuthorization != .authorized { page = 0 }
        else if !insertionChoiceIsReady(using: coordinator) { page = 1 }
        else if !coordinator.isHotkeySelectionReady { page = 2 }
        else { page = 3 }
    }

}

/// The one question the app asks before it is used.
///
/// It opens with whatever the app already had — the Germany default on a fresh
/// install, or the pair a Phase 6 build stored — so the choice is a correction
/// of something reasonable rather than an empty form.
struct LanguageSetupView: View {
    @ObservedObject var model: LanguageSetupModel
    let confirm: () -> Void
    var skip: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                WitnessBrand()
                Spacer()
                Text("Languages")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(WitnessStyle.faint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Which languages do you speak?")
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.6)
                Text("Choose the languages you speak. Witness detects them automatically as you dictate.")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LanguageSelectionEditor(selection: $model.selection)

            HStack {
                Button("Skip", action: skip)
                    .buttonStyle(.plain)
                    .foregroundStyle(WitnessStyle.muted)
                Text(model.selection.shortLabel)
                    .font(.callout.monospaced())
                    .foregroundStyle(WitnessStyle.muted)
                Spacer()
                Button("Continue", action: confirm)
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }

            Text("You can change this at any time in Settings \u{2192} Languages.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
        }
        .padding(28)
        .frame(width: 520, height: 620)
        .witnessWindow()
    }
}

/// The two first-run screens, in one window.
///
/// Split from `LanguageSetupView` rather than folded into it so the question
/// stays a view over a selection and nothing else — it is the one thing in this
/// window that has to lay out a hundred rows, and `LanguageSetupTests` renders
/// it on its own for exactly that reason.
struct FirstRunView: View {
    @ObservedObject var model: LanguageSetupModel
    @ObservedObject var coordinator: DictationCoordinator
    let confirm: () -> Void
    let finish: () -> Void
    let notifyWhenReady: () -> Void

    var body: some View {
        switch model.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 24) {
                WitnessBrand()
                Spacer(minLength: 0)
                Image(systemName: "waveform")
                    .font(.system(size: 35, weight: .medium))
                    .foregroundStyle(WitnessStyle.accent)
                    .frame(width: 76, height: 76)
                    .background(WitnessStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 23))
                    .accessibilityHidden(true)
                Text("Welcome to Witness")
                    .font(.system(size: 30, weight: .semibold)).tracking(-0.7)
                Text("Choose your languages and a shortcut, then try dictation. Your speech stays on this Mac.")
                    .font(.body).fixedSize(horizontal: false, vertical: true)
                Text("Witness downloads a speech model during setup. This usually takes 5–15 minutes. You can try dictation as soon as it is ready.")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .witnessCard()
                Spacer(minLength: 0)
                HStack {
                    Button("Skip", action: finish)
                        .buttonStyle(.plain).foregroundStyle(WitnessStyle.muted)
                    Spacer()
                    Button("Set up Witness") { model.step = .languages }
                        .buttonStyle(WitnessPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 520, height: 620).witnessWindow()
        case .languages:
            LanguageSetupView(model: model, confirm: confirm, skip: finish)
        case .ready:
            GuidedSetupView(model: model, coordinator: coordinator, notifyWhenReady: notifyWhenReady, finish: finish)
        }
    }
}

struct GuidedSetupView: View {
    @ObservedObject var model: LanguageSetupModel
    @ObservedObject var coordinator: DictationCoordinator
    let notifyWhenReady: () -> Void
    let finish: () -> Void

    private var titles: [String] { ["Microphone access", "Type into other apps", "Choose your shortcut", "Preparing your speech model", "Try your first dictation", "You’re ready to dictate"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                WitnessBrand()
                Spacer()
                Text(verbatim: L10n.format("Step %lld of %lld", Int64(model.page + 1), 6))
                    .font(.caption).foregroundStyle(WitnessStyle.muted)
            }
            WitnessSetupProgress(step: model.page + 1, total: 6)
            Text(LocalizedStringKey(titles[min(model.page, 5)]))
                .font(.system(size: 27, weight: .semibold)).tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .witnessCard(padding: 18)
            }
            .buttonStyle(WitnessSecondaryButtonStyle())
            if !coordinator.transcriptionModelState.isReady && model.page != 3 {
                Text(coordinator.transcriptionModelState.label).font(.caption).foregroundStyle(WitnessStyle.muted)
            }
            Divider()
            HStack(spacing: 14) {
                Button("Skip", action: finish)
                    .buttonStyle(.plain).foregroundStyle(WitnessStyle.muted)
                Button("Back") { leaveTest(); if model.page > 0 { model.page -= 1 } else { model.step = .languages } }
                    .buttonStyle(WitnessSecondaryButtonStyle())
                Spacer()
                Button(L10n.string(model.page == 5 ? "Done" : "Next")) { advance() }
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .disabled(!model.canAdvance(using: coordinator))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 520, height: 620).witnessWindow()
        .onChange(of: coordinator.transcriptionModelState.isReady) { _, _ in synchronize() }
        .onChange(of: coordinator.state) { _, _ in synchronize() }
        .onChange(of: coordinator.microphoneAuthorization) { _, _ in synchronize() }
        .onChange(of: coordinator.registeredHotkey) { _, _ in synchronize() }
        .onChange(of: coordinator.pendingHotkeyBinding) { _, _ in synchronize() }
        .onChange(of: coordinator.needsAccessibilityTrust) { _, _ in synchronize() }
        .onChange(of: model.isInteractive) { _, _ in synchronize() }
        .onAppear { synchronize() }
        .onDisappear { leaveTest() }
    }

    private func synchronize() { model.synchronizeReadiness(using: coordinator) }
    private func enterTest() {
        guard model.isInteractive, model.testPrerequisitesAreReady(using: coordinator) else { return }
        coordinator.beginOnboardingTest()
    }
    private func leaveTest() { model.clearTest(using: coordinator) }
    private func advance() {
        if model.page == 5 { finish(); return }
        model.advance(using: coordinator)
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case 0:
            Text("Witness needs the microphone to hear you. Audio stays in memory and is never saved to disk.")
            if coordinator.microphoneAuthorization == .authorized {
                Label("Microphone allowed", systemImage: "checkmark.circle").foregroundStyle(WitnessStyle.success)
            } else if coordinator.microphoneAuthorization == .notDetermined {
                Button("Allow microphone…") { Task { await coordinator.requestMicrophoneAccess() } }
            } else {
                Text("Enable Witness in System Settings → Privacy & Security → Microphone. On a managed Mac, you may need an administrator’s help.")
                Button("Open Privacy Settings") { coordinator.openSystemSettings() }
                Button("Re-check") { coordinator.refreshAuthorization() }
            }
            Text("Your dictation stays on this Mac. Witness also sends limited setup and trial events. You can turn these off in Settings → Privacy.")
                .font(.caption).foregroundStyle(WitnessStyle.muted)
            DisclosureGroup("About setup and privacy") {
            Text("Your dictation stays on this Mac. Witness can share nine types of setup and trial events, with the app version, macOS version and a random installation ID. These include installation, model download progress and failures, attempts before the model is ready, microphone denial, trial start, the email prompt and offers shown. You can turn sharing off in Settings → Privacy.")
                .font(.caption).foregroundStyle(WitnessStyle.muted)
            }.font(.caption)

        case 1:
            Text("Enable Witness in System Settings → Privacy & Security → Accessibility. This lets it insert text at your cursor. We’ll check the permission when you return.")
            if coordinator.needsAccessibilityTrust {
                Button("Allow typing into other apps") { coordinator.requestAccessibilitySetup() }
                Button("Re-check") { coordinator.refreshAccessibilityAuthorization() }
                Text("You can set this up later. Without this permission, you can paste your dictation from the clipboard into other apps.").font(.callout)
                if model.usesClipboardOnly {
                    Label("Copy and paste selected", systemImage: "doc.on.clipboard")
                } else {
                    Button("Continue with copy and paste") { model.continueWithClipboard(using: coordinator) }
                }
            } else { Label("Witness can type for you", systemImage: "checkmark.circle") }
        case 2:
            HotkeyRecorderRow().environmentObject(coordinator)
            Picker("Mode", selection: Binding(get: { coordinator.activation }, set: { coordinator.setActivation($0) })) {
                ForEach(RecordingActivation.allCases) { Text($0.displayName).tag($0) }
            }
            Text(coordinator.activation.explanation)
        case 3:
            Text("Witness needs a speech model to recognize your voice on this Mac. The first download and preparation usually take 5–15 minutes.")
            Text("The progress appears below. Once the model is ready, you can try your first dictation.")
            if case let .preparing(preparation) = coordinator.transcriptionModelState {
                if let progress = preparation.progress { ProgressView(value: progress) }
                else { ProgressView() }
            }
            Text(coordinator.transcriptionModelState.label)
            if !coordinator.transcriptionModelState.isPreparing && !coordinator.transcriptionModelState.isReady {
                Button("Try again") { Task { await coordinator.prepareTranscriptionModel() } }
            }
            Button("Notify me when ready", action: notifyWhenReady)
            Text(verbatim: L10n.string(model.notificationMessage)).font(.caption)
            Text("You can minimize or close this window. Preparation continues while Witness is running. Return from the menu bar → Setup and practice.").font(.callout).foregroundStyle(WitnessStyle.muted)
        case 4:
            if coordinator.transcriptionModelState.isReady { Label("The speech model is ready", systemImage: "checkmark.circle").foregroundStyle(WitnessStyle.success) }
            if !model.testPrerequisitesAreReady(using: coordinator) {
                Text("A few setup steps are still needed before you can try dictation. Let’s check the microphone, your key and the speech model.")
                Button("Check setup") { model.showRequiredSetup(using: coordinator) }
            }
            Text(coordinator.activation == .pushToTalk
                 ? L10n.format("Hold %@ and say a few words to try dictation.", coordinator.binding.displayString)
                 : L10n.format("Press %@ to start recording.", coordinator.binding.displayString))
            Text(coordinator.activation.explanation)
            Text("Your test result appears here. Nothing is inserted into another app.")
            Text(StatusPresentation(state: coordinator.state, binding: coordinator.binding, activation: coordinator.activation).title)
                .foregroundStyle(WitnessStyle.muted)
            if case let .failed(failure) = coordinator.state {
                Text(failure.message).foregroundStyle(WitnessStyle.warning)
                Button("Try again") { coordinator.recoverFromFailure(); enterTest() }
            }
            if let silence = coordinator.silentResult { Text(silence.message).foregroundStyle(WitnessStyle.warning) }
            if coordinator.state.isCapturing { Button("Stop recording") { coordinator.stopOnboardingRecording() } }
            if !coordinator.onboardingTestText.isEmpty {
                Text(verbatim: coordinator.onboardingTestText).textSelection(.enabled).witnessCard()
                if let result = coordinator.onboardingTestResult, result.deservesAttention {
                    Text("A few words may need a second look. The original recognized text is below to help you check.").foregroundStyle(WitnessStyle.warning)
                    Text(verbatim: result.transcript.text).textSelection(.enabled)
                }
                Button("Try again") { enterTest() }
            }
        default:
            Label("Your first dictation worked", systemImage: "checkmark.circle").foregroundStyle(WitnessStyle.success)
            if coordinator.canInsert && !coordinator.needsAccessibilityTrust && coordinator.insertsAutomatically {
                Label("Automatic insertion is enabled", systemImage: "checkmark.circle")
                Text("Your voice test worked here. You can now try inserting text in another app.")
            } else {
                Label("Automatic insertion is not enabled", systemImage: "info.circle")
                Text("Your voice test worked here. You can copy your dictation from Witness and paste it into another app.")
                if coordinator.needsAccessibilityTrust {
                    Button("Set up automatic insertion") { model.page = 1 }
                } else if !coordinator.insertsAutomatically {
                    Text("You can enable automatic insertion in Settings.").font(.callout)
                }
            }

            Text(verbatim: coordinator.binding.displayString).font(.title)
            Text(coordinator.activation.explanation)
            Text("Find Witness in the menu bar. You can reopen Setup and practice at any time.")
            Toggle("Open Witness when I log in", isOn: $model.opensAtLogin)
            Text("The first three days start at your first successful dictation. Afterwards, an email address activates ten more free days. Your dictation stays on this Mac.").font(.caption)
        }
    }
}
