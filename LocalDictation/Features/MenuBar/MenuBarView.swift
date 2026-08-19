import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @Environment(\.openSettings) private var openSettings

    private var presentation: StatusPresentation {
        StatusPresentation(state: coordinator.state, binding: coordinator.binding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if coordinator.state == .recording || coordinator.state == .finishing {
                RecordingLevelView(snapshot: coordinator.diagnostics.snapshot)
            }

            if coordinator.hasTranscriptionEngine {
                LanguageProfilePicker(selection: $coordinator.languageProfile)

                if !coordinator.transcriptionModelState.isReady {
                    ModelStateView(state: coordinator.transcriptionModelState) {
                        Task { await coordinator.prepareTranscriptionModel() }
                    }
                }
            }

            if let result = coordinator.result, !result.isEmpty {
                if coordinator.state.isReviewing {
                    ReviewStripView(result: result)
                } else {
                    ResultView(result: result, prefersRaw: coordinator.prefersRawTranscript)
                }
            }

            if let summary = coordinator.diagnostics.lastUtterance {
                LastUtteranceView(summary: summary)
            }

            actions

            Divider()

            HStack {
                Button("Settings") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            coordinator.refreshAuthorization()
            Task { await coordinator.refreshTranscriptionModelState() }
        }
        .onChange(of: coordinator.languageProfile) {
            Task { await coordinator.refreshTranscriptionModelState() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(tintColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if presentation.showsPermissionRequest {
            Button("Allow microphone access…") {
                Task { await coordinator.requestMicrophoneAccess() }
            }
        }

        if presentation.showsSystemSettingsShortcut {
            HStack {
                Button("Open Privacy Settings") {
                    coordinator.openSystemSettings()
                }
                Button("Re-check") {
                    coordinator.refreshAuthorization()
                }
            }
        }

        if presentation.showsRecoveryAction {
            Button("Try again") {
                coordinator.recoverFromFailure()
            }
        }
    }

    private var tintColor: Color {
        switch presentation.tint {
        case .neutral: .secondary
        case .ready: .green
        case .active: .red
        case .warning: .orange
        }
    }
}

private struct RecordingLevelView: View {
    let snapshot: CaptureSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(Double(snapshot.peakLevel), 1)) {
                Text("Input level")
                    .font(.caption)
            }
            HStack {
                Text(String(format: "%.1f s", snapshot.duration))
                Spacer()
                Text(snapshot.voiceActivity.state.label)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct LastUtteranceView: View {
    let summary: UtteranceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Last utterance")
                .font(.caption)
            Text(
                String(
                    format: "%.2f s · %d frames · peak %.2f",
                    summary.duration,
                    summary.frameCount,
                    summary.peakLevel
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct LanguageProfilePicker: View {
    @Binding var selection: LanguageProfile

    var body: some View {
        Picker("Language", selection: $selection) {
            Section("Single") {
                ForEach(LanguageProfile.single) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            Section("Mixed") {
                ForEach(LanguageProfile.mixed) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
        }
        .font(.caption)
    }
}

private struct ModelStateView: View {
    let state: TranscriptionModelState
    let prepare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch state {
            case .unavailable, .failed:
                Button("Prepare speech model…", action: prepare)
            case .preparing:
                ProgressView().controlSize(.small)
            case .ready:
                EmptyView()
            }
        }
    }
}

/// The finished result, shown when the risk policy found nothing worth an
/// interruption.
///
/// It is deliberately plain. A review that appears every time is a review
/// nobody reads, so the quiet path has no marks, no strip, and no decision to
/// make — just the text. Phase 3 still inserts into no other application: the
/// copy button is the single, explicit way this text leaves the app.
private struct ResultView: View {
    let result: DictationResult
    /// Carried out of the review: a user who recovered the raw transcript keeps
    /// it afterwards, rather than having the cleaned text quietly return.
    let prefersRaw: Bool

    @State private var didCopy = false

    private var text: String { result.text(preferringRaw: prefersRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(prefersRaw ? "Raw transcript" : "Transcript")
                    .font(.caption)
                Spacer()
                Text(result.profile.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 120)

            HStack {
                Button(didCopy ? "Copied" : "Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    didCopy = true
                }
                .disabled(didCopy)

                Spacer()

                if let factor = result.transcript.realTimeFactor {
                    Text(String(format: "%.2f\u{00d7} real time", factor))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: text) { didCopy = false }
    }
}
