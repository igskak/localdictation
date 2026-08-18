import SwiftUI
#if DEBUG
import AppKit
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

            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 420)
        .navigationTitle("LocalDictation Settings")
    }

    private var generalTab: some View {
        Form {
            Section("Dictation") {
                LabeledContent("Push-to-talk", value: coordinator.binding.displayString)
                LabeledContent("Hotkey", value: coordinator.registeredHotkey == nil ? "Not registered" : "Registered")
                LabeledContent("Status", value: StatusPresentation(state: coordinator.state, binding: coordinator.binding).title)
            }

            Section("Privacy") {
                Text("Audio stays in memory on this Mac. Nothing is written to disk during normal capture and nothing is sent to a network service.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("MVP languages", value: "DE, EN, RU, UK")
            }

            Section("Phase") {
                Text("Phase 1 covers permission, global hotkey, bounded in-memory capture, and the voice-activity boundary. Speech recognition arrives in Phase 2.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
