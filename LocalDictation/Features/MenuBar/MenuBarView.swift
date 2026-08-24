import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @Environment(\.openSettings) private var openSettings

    private var presentation: StatusPresentation {
        StatusPresentation(
            state: coordinator.state,
            binding: coordinator.binding,
            modelState: coordinator.transcriptionModelState,
            attentionIsPending: coordinator.attentionIsPending
        )
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
                ResultView(
                    result: result,
                    prefersRaw: coordinator.prefersRawTranscript,
                    canInsert: coordinator.canInsert && coordinator.hasInsertableResult,
                    insertTitle: insertTitle,
                    insert: { coordinator.insertCurrentResult() }
                )

                // The second way into the review, and the one that still works
                // after the chip has faded. The menu is where a user goes when
                // they have already started doubting the text, so the offer has
                // to be here rather than only in something that disappears.
                if coordinator.canOpenReview {
                    Button {
                        coordinator.openReview()
                    } label: {
                        Label(reviewTitle(for: result), systemImage: "exclamationmark.triangle")
                    }
                }
            }

            if let outcome = coordinator.lastInsertion, let message = outcome.message {
                InsertionOutcomeView(message: message)
            }

            if presentation.showsLicenseAction {
                LicenseLockView(
                    presentation: LicensePresentation(state: coordinator.entitlement),
                    openLicenseSettings: {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                )
            }

            if coordinator.needsAccessibilityTrust {
                AccessibilityTrustView(
                    grant: { coordinator.requestAccessibilityTrust() },
                    openSettings: { coordinator.openAccessibilitySettings() },
                    recheck: { coordinator.refreshAccessibilityAuthorization() }
                )
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

    private var insertTitle: String {
        guard let target = coordinator.insertionTargetName else { return "Insert" }
        return "Insert into \(target)"
    }

    private func reviewTitle(for result: DictationResult) -> String {
        let count = result.flaggedSpans.count
        switch count {
        case 0: return "Check what was marked"
        case 1: return "Check 1 flagged fragment"
        default: return "Check \(count) flagged fragments"
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
/// make — just the text.
///
/// From Phase 4 the text is usually already in the application the user was
/// typing in by the time this is visible. It is still shown, because the menu
/// is where someone looks when the insertion did not go where they expected —
/// and it carries the explicit insert action for users who turned the automatic
/// one off.
private struct ResultView: View {
    let result: DictationResult
    /// Carried out of the review: a user who recovered the raw transcript keeps
    /// it afterwards, rather than having the cleaned text quietly return.
    let prefersRaw: Bool
    let canInsert: Bool
    let insertTitle: String
    let insert: () -> Void

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

                if canInsert {
                    Button(insertTitle, action: insert)
                }

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

/// Where the last result went, when it did not go where it was meant to.
///
/// Shown for a clipboard fallback and for a refusal, and never for a successful
/// insertion: the text appearing in the document is the message, and a banner
/// congratulating the app on it would be noise on the path this phase exists to
/// keep quiet.
private struct InsertionOutcomeView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The licensing wall, in the one place the user will look when the hotkey
/// stopped doing anything.
///
/// It does not try to sell from inside a menu — the offers and the key field
/// live in Settings, which has room for them. What this has to do is say why
/// nothing happened and point at the door, in two lines, without the user
/// having to guess that a dictation app can be out of trial.
private struct LicenseLockView: View {
    let presentation: LicensePresentation
    let openLicenseSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.headline)
                .font(.caption.weight(.semibold))
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(presentation.showsActivation ? "Activate…" : "Open License settings", action: openLicenseSettings)
                .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The Accessibility ask.
///
/// Never shown at launch and never blocking: everything the app did before this
/// phase still works without trust, and the text still arrives — on the
/// clipboard. This is an offer to do better, not a wall.
private struct AccessibilityTrustView: View {
    let grant: () -> Void
    let openSettings: () -> Void
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type text for you")
                .font(.caption.weight(.semibold))
            Text("LocalDictation needs Accessibility access to put text into other applications. Without it, results go to the clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Allow…", action: grant)
                Button("Open Settings", action: openSettings)
                Button("Re-check", action: recheck)
            }
            .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
