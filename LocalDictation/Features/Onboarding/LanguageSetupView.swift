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
                    .font(.largeTitle.weight(.medium))
                    .tracking(-1.2)
                Text("Choose the languages you use for dictation. Witness recognizes speech within this selection, so you can speak without switching languages manually.")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LanguageSelectionEditor(selection: $model.selection)

            HStack {
                Button("Skip", action: skip)
                Text(model.selection.shortLabel)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue", action: confirm)
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }

            Text("You can change this at any time in Settings \u{2192} Languages.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("Welcome to Witness").font(.largeTitle)
                Text("Choose your languages and a comfortable key, then try dictation. Your speech stays on this Mac.")
                Text("During setup, Witness downloads a speech model. This usually takes 5–15 minutes. We’ll let you know here when it’s ready to try.")
                    .foregroundStyle(WitnessStyle.muted)
                Spacer()
                HStack {
                    Button("Skip", action: finish)
                    Spacer()
                    Button("Set up Witness") { model.step = .languages }
                        .buttonStyle(WitnessPrimaryButtonStyle())
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

    private var titles: [String] { ["Microphone access", "Type into other apps", "Choose your key", "Preparing your speech model", "Try your first dictation", "Ready when you are"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                WitnessBrand()
                Spacer()
                Text(verbatim: "\(model.page + 1) / 6").foregroundStyle(WitnessStyle.muted)
            }
            Text(verbatim: L10n.string(titles[min(model.page, 5)])).font(.largeTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !coordinator.transcriptionModelState.isReady && model.page != 3 {
                Text(coordinator.transcriptionModelState.label).font(.caption).foregroundStyle(WitnessStyle.muted)
            }
            HStack {
                Button("Skip", action: finish)
                Button("Back") { leaveTest(); if model.page > 0 { model.page -= 1 } else { model.step = .languages } }
                Spacer()
                Button(L10n.string(model.page == 5 ? "Done" : "Next")) { advance() }
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .disabled(!canAdvance)
            }
        }
        .padding(28).frame(width: 520, height: 620).witnessWindow()
        .onChange(of: coordinator.transcriptionModelState.isReady) { _, ready in
            if ready && model.page == 3 { model.page = 4; enterTest() }
        }
        .onAppear {
            if model.page == 3 && coordinator.transcriptionModelState.isReady { model.page = 4 }
            if model.page == 4 { enterTest() }
        }
        .onDisappear { leaveTest() }
    }

    private var canAdvance: Bool {
        switch model.page {
        case 0: coordinator.microphoneAuthorization == .authorized
        case 2: coordinator.registeredHotkey != nil && coordinator.preferencesErrorDescription == nil
        case 3: coordinator.transcriptionModelState.isReady
        case 4: !coordinator.onboardingTestText.isEmpty
        default: true
        }
    }
    private func enterTest() {
        guard coordinator.microphoneAuthorization == .authorized,
              coordinator.registeredHotkey != nil,
              coordinator.transcriptionModelState.isReady else { return }
        coordinator.beginOnboardingTest()
    }
    private func leaveTest() { if coordinator.isOnboardingTest { coordinator.endOnboardingTest() } }
    private func advance() {
        if model.page == 5 { finish(); return }
        leaveTest()
        model.page += 1
        if model.page == 3 && coordinator.transcriptionModelState.isReady { model.page = 4 }
        if model.page == 4 { enterTest() }
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
                Text("Microphone access is off for Witness. You can enable it in Privacy & Security → Microphone. On a managed Mac, an administrator may need to help.")
                Button("Open Privacy Settings") { coordinator.openSystemSettings() }
                Button("Re-check") { coordinator.refreshAuthorization() }
            }
            Text("Your dictation stays on this Mac. Witness also sends limited setup and trial events. You can turn these off in Settings → Privacy.")
                .font(.caption).foregroundStyle(WitnessStyle.muted)
            DisclosureGroup("About setup and privacy") {
            Text("Nothing you dictate ever leaves this Mac. Nine events about setting it up and about the trial do — the install, the speech model arriving or failing to, a press that finds it still arriving, a refused microphone, the trial starting, the email ask, and the offers — with no more than an app version, a macOS version, and a random number made at install. Settings → Privacy turns them off.")
                .font(.caption).foregroundStyle(WitnessStyle.muted)
            }.font(.caption)

        case 1:
            Text("To let Witness type at your cursor, enable it in Privacy & Security → Accessibility. When you come back, we’ll check the permission for you.")
            if coordinator.needsAccessibilityTrust {
                Button("Open Accessibility Settings") { coordinator.openAccessibilitySettings() }
                Button("Re-check") { coordinator.refreshAccessibilityAuthorization() }
                Text("You can set this up later. Without this permission, you can paste your dictation from the clipboard into other apps.").font(.callout)
            } else { Label("Witness can type for you", systemImage: "checkmark.circle") }
        case 2:
            HotkeyRecorderRow().environmentObject(coordinator)
            Picker("Mode", selection: Binding(get: { coordinator.activation }, set: { coordinator.setActivation($0) })) {
                ForEach(RecordingActivation.allCases) { Text($0.displayName).tag($0) }
            }
            Text(coordinator.activation.explanation)
        case 3:
            Text("To keep your speech private, Witness recognizes it on this Mac. First, we need to download a speech model. This usually takes 5–15 minutes, depending on your connection and Mac.")
            Text("Please leave this window open so we can guide you to your first dictation when the model is ready. You can follow the progress below. Your audio stays on your Mac.")
            if case let .preparing(preparation) = coordinator.transcriptionModelState {
                if let progress = preparation.progress { ProgressView(value: progress) }
                else { ProgressView() }
            }
            Text(coordinator.transcriptionModelState.label)
            Button("Try again") { Task { await coordinator.prepareTranscriptionModel() } }
                .disabled(coordinator.transcriptionModelState.isPreparing)
            Button("Notify me when ready", action: notifyWhenReady)
            Text(verbatim: L10n.string(model.notificationMessage)).font(.caption)
            Text("You’re welcome to minimize this window while you wait. If you close it, preparation continues while Witness is running. You can return anytime from the menu bar → Set up / Try dictation.").font(.callout).foregroundStyle(WitnessStyle.muted)
        case 4:
            if coordinator.transcriptionModelState.isReady { Label("The speech model is ready", systemImage: "checkmark.circle").foregroundStyle(WitnessStyle.success) }
            if !coordinator.isOnboardingTest {
                Text("A few setup steps are still needed before you can try dictation. Let’s check the microphone, your key and the speech model.")
                Button("Check setup") { model.page = 0 }
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
                if let result = coordinator.result, result.deservesAttention {
                    Text("A few words may need a second look. The original recognized text is below to help you check.").foregroundStyle(WitnessStyle.warning)
                    Text(verbatim: coordinator.transcript?.text ?? "").textSelection(.enabled)
                }
                Button("Try again") { enterTest() }
            }
        default:
            Label("Your first dictation worked", systemImage: "checkmark.circle").foregroundStyle(WitnessStyle.success)
            Text(verbatim: coordinator.binding.displayString).font(.title)
            Text(coordinator.activation.explanation)
            Text("Witness lives in the menu bar. Place your cursor in another app and use your key. Set up / Try dictation is always available in the menu.")
            Toggle("Open Witness when I log in", isOn: $model.opensAtLogin)
            Text("The first three days start at your first successful dictation. Afterwards, an email address activates ten more free days. Your dictation stays on this Mac.").font(.caption)
        }
    }
}
