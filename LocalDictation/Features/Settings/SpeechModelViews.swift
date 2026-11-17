import AppKit
import SwiftUI

struct SpeechModelSettingsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject var notetakerStatus: NotetakerStatus
    @ObservedObject var selection: SpeechModelSelection = .shared

    var body: some View {
        WitnessSettingsForm {
            WitnessSettingsSection("Speech model") {
                Text("Try different models and choose the one that recognizes your speech best. They differ in speed, supported languages, recognition quality and size. A larger model does not always give a better result.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                SpeechModelControls(coordinator: coordinator, selection: selection, notetakerStatus: notetakerStatus)
            }
            WitnessSettingsSection("On this Mac") {
                Text("Dictation and Notetaker use the same selected model. Audio and transcripts stay on this Mac.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                Text("Sizes are approximate. macOS preparation uses additional disk space. You can remove inactive models to free space.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                Button("Model licenses") {
                    if let url = Bundle.main.url(forResource: "SpeechModels-NOTICES", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

struct SpeechModelControls: View {
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject var selection: SpeechModelSelection = .shared
    @ObservedObject var notetakerStatus: NotetakerStatus
    var beforeRestart: () -> Void = {}
    @State private var choice: DictationEngineChoice = .active
    @State private var removing = false

    private var canRestart: Bool {
        DictationEngineChoice.allowsRestart(dictation: coordinator.state, meetingIsActive: notetakerStatus.isActive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Active model", value: selection.active.title)
            Picker("Choose a model", selection: $choice) {
                ForEach(DictationEngineChoice.allCases) { model in
                    Text(verbatim: model.title + " · " + ModelDownloadProgress.sizeText(model.approximateBytes))
                        .tag(model).disabled(!model.supports(coordinator.languageProfile))
                }
            }
            .disabled(selection.downloading != nil)
            Text(verbatim: L10n.string(choice.detail))
                .font(.callout).foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !choice.supports(coordinator.languageProfile) {
                Text("This model does not support all your selected languages.").foregroundStyle(WitnessStyle.warning)
            }
            if let downloading = selection.downloading {
                Text(verbatim: L10n.format("Downloading %@", downloading.title)).font(.callout.weight(.medium))
                if let progress = selection.progress {
                    ProgressView(value: progress.fraction)
                        .accessibilityLabel("Model download progress")
                        .accessibilityValue(progress.percent.formatted() + "%")
                    Text(verbatim: "\(progress.percent)% · \(ModelDownloadProgress.sizeText(progress.completedBytes)) / \(ModelDownloadProgress.sizeText(progress.totalBytes))")
                        .font(.caption.monospacedDigit()).foregroundStyle(WitnessStyle.muted)
                } else { ProgressView().controlSize(.small) }
                Text("Your model is downloading. We will notify you when it finishes. Restart Witness afterwards to apply it. Your current model keeps working.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted).fixedSize(horizontal: false, vertical: true)
                Button("Cancel download") { selection.cancelDownload() }
            } else if let pending = selection.pending {
                Label(L10n.format("%@ is downloaded and ready to apply.", pending.title), systemImage: "checkmark.circle")
                    .foregroundStyle(WitnessStyle.success)
                    .fixedSize(horizontal: false, vertical: true)
                if !pending.supports(coordinator.languageProfile) {
                    Text("This model does not support all your selected languages.").foregroundStyle(WitnessStyle.warning)
                }
                Button("Restart and apply") {
                    beforeRestart()
                    selection.restart(dictation: coordinator.state, meetingIsActive: notetakerStatus.isActive, profile: coordinator.languageProfile)
                }
                .disabled(!canRestart || !pending.supports(coordinator.languageProfile))
                Button("Keep active model") { selection.keepCurrent() }
                if !canRestart { Text("Finish dictation or the meeting note before restarting.").font(.caption).foregroundStyle(WitnessStyle.muted) }
            }
            if selection.downloading == nil {
                if selection.installed.contains(choice) {
                    Label("Installed", systemImage: "internaldrive").font(.caption).foregroundStyle(WitnessStyle.muted)
                }
                if choice != selection.active && choice != selection.pending {
                    Button(selection.installed.contains(choice) ? "Use this model" : "Download and select") {
                        selection.choose(choice, profile: coordinator.languageProfile)
                    }
                    .disabled(!choice.supports(coordinator.languageProfile))
                    if selection.installed.contains(choice) {
                        Button("Remove model…") { removing = true }
                            .confirmationDialog("Remove this model from your Mac?", isPresented: $removing) {
                                Button("Move to Trash", role: .destructive) { selection.remove(choice) }
                            } message: { Text("You can download this model again later. Your active model will keep working.") }
                    }
                }
            }
            if !selection.notificationsEnabled {
                Text("Notifications are off or could not be delivered. You can check progress here and enable notifications for Witness in System Settings.")
                    .font(.caption).foregroundStyle(WitnessStyle.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let error = selection.error {
                Text(verbatim: error).font(.callout).foregroundStyle(WitnessStyle.warning).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { choice = selection.downloading ?? selection.pending ?? selection.active; selection.refresh() }
        .onChange(of: selection.downloading) { _, model in if let model { choice = model } }
        .onChange(of: selection.pending) { _, model in if let model { choice = model } }
    }
}

struct SpeechModelPreparationView: View {
    @ObservedObject var coordinator: DictationCoordinator
    let choice: DictationEngineChoice
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WitnessBrand()
            Text(verbatim: choice.title).font(.title3.weight(.semibold))
            if case let .failed(message) = coordinator.transcriptionModelState {
                Text(verbatim: message).font(.callout).foregroundStyle(WitnessStyle.warning)
                Button("Try again") { Task { await coordinator.prepareTranscriptionModel() } }
                Button("Choose a model") {
                    SettingsNavigation.request(.speechModel)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Preparing this model for your Mac. This may take a few minutes. We will notify you when it is ready to use.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("You can close this window. Preparation continues while Witness is running.")
                    .font(.caption).foregroundStyle(WitnessStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 440).witnessWindow()
    }
}
