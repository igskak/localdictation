import AppKit
import SwiftUI

struct SpeechModelSettingsView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject var notetakerStatus: NotetakerStatus
    @ObservedObject var selection: SpeechModelSelection = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Try different models and choose the one that recognizes your speech best. They differ in speed, supported languages, recognition quality and size. A larger model does not always give a better result.")
                    .font(.callout).foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                SpeechModelControls(coordinator: coordinator, selection: selection, notetakerStatus: notetakerStatus)
                Divider()
                Label("Your selected model works for dictation, meetings and files. Audio and transcripts stay on this Mac.", systemImage: "lock")
                    .font(.caption).foregroundStyle(WitnessStyle.muted)
                Text("Sizes are approximate. macOS preparation uses additional disk space. You can remove inactive models to free space.")
                    .font(.caption).foregroundStyle(WitnessStyle.muted)
                Button("Model licenses") {
                    if let url = Bundle.main.url(forResource: "SpeechModels-NOTICES", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }.buttonStyle(.plain).font(.caption).foregroundStyle(WitnessStyle.accent)
            }.padding(28)
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
        DictationEngineChoice.allowsRestart(dictation: coordinator.state, meetingIsActive: notetakerStatus.isActive, fileIsActive: coordinator.isFileTranscriptionRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                WitnessIconTile(systemImage: "waveform", tint: WitnessStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active model").font(.caption).foregroundStyle(WitnessStyle.muted)
                    Text(verbatim: selection.active.title).font(.callout.weight(.semibold))
                }
                Spacer(minLength: 0)
                if coordinator.transcriptionModelState.isReady {
                    Label("Ready", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(WitnessStyle.success)
                } else {
                    Text(coordinator.transcriptionModelState.label).font(.caption).foregroundStyle(WitnessStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.witnessCard(padding: 14)
            Text("Choose a model").font(.caption.weight(.semibold)).foregroundStyle(WitnessStyle.muted)
            VStack(spacing: 0) {
                ForEach(DictationEngineChoice.allCases) { model in
                    if model != DictationEngineChoice.allCases.first { Divider() }
                    Button { choice = model } label: {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: choice == model ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(choice == model ? WitnessStyle.accent : WitnessStyle.muted)
                                .padding(.top, 2).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(verbatim: model.title).font(.callout.weight(.semibold))
                                    if model == selection.active {
                                        Text("Current").font(.caption2).foregroundStyle(WitnessStyle.muted)
                                    }
                                }
                                Text(LocalizedStringKey(model.detail)).font(.caption).foregroundStyle(WitnessStyle.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Text(verbatim: ModelDownloadProgress.sizeText(model.approximateBytes))
                                .font(.caption.monospacedDigit()).foregroundStyle(WitnessStyle.muted).fixedSize()
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(choice == model ? WitnessStyle.accent.opacity(0.06) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selection.downloading != nil || !model.supports(coordinator.languageProfile))
                    .accessibilityAddTraits(choice == model ? [.isSelected] : [])
                    .accessibilityHint(!model.supports(coordinator.languageProfile)
                        ? L10n.string("This model does not support all your selected languages.") : "")
                }
            }
            .background(WitnessStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(WitnessStyle.line, lineWidth: 1).allowsHitTesting(false) }
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
                    selection.restart(dictation: coordinator.state, meetingIsActive: notetakerStatus.isActive, fileIsActive: coordinator.isFileTranscriptionRunning, profile: coordinator.languageProfile)
                }
                .buttonStyle(WitnessPrimaryButtonStyle())
                .disabled(!canRestart || !pending.supports(coordinator.languageProfile))
                Button("Keep active model") { selection.keepCurrent() }
                if !canRestart { Text("Wait for your dictation, meeting or file to finish before restarting.").font(.caption).foregroundStyle(WitnessStyle.muted) }
            }
            if selection.downloading == nil {
                if selection.installed.contains(choice) {
                    Label("Installed", systemImage: "internaldrive").font(.caption).foregroundStyle(WitnessStyle.muted)
                }
                if choice != selection.active && choice != selection.pending {
                    Button(selection.installed.contains(choice) ? "Use this model" : "Download and select") {
                        selection.choose(choice, profile: coordinator.languageProfile)
                    }
                    .buttonStyle(WitnessPrimaryButtonStyle())
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
