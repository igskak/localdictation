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
        .frame(width: 340)
        .onAppear { coordinator.refreshAuthorization() }
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
