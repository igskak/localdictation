import SwiftUI

/// Permissions and model preparation after the language selection.
struct FirstRunReadyView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @Binding var opensAtLogin: Bool
    let notificationMessage: String
    let notifyWhenReady: () -> Void
    let finish: () -> Void

    /// `opensAtLogin` defaults to a constant so a view that has no window
    /// around it, like the layout tests, does not have to invent one.
    init(
        coordinator: DictationCoordinator,
        opensAtLogin: Binding<Bool> = .constant(true),
        notificationMessage: String = "Get a macOS notification when the model is ready.",
        notifyWhenReady: @escaping () -> Void = {},
        finish: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        _opensAtLogin = opensAtLogin
        self.notificationMessage = notificationMessage
        self.notifyWhenReady = notifyWhenReady
        self.finish = finish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                WitnessBrand()
                Spacer()
                Text("SETUP · 2 OF 2")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(WitnessStyle.faint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Let’s get Witness ready")
                    .font(.largeTitle.weight(.medium))
                    .tracking(-1.2)
                Text(verbatim: L10n.string("Allow access below, then we’ll prepare your private speech model."))
                .font(.callout)
                .foregroundStyle(WitnessStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    microphoneStep

                    if coordinator.canInsert {
                        accessibilityStep
                    }

                    if coordinator.hasTranscriptionEngine {
                        modelStep
                    }

                    if coordinator.hasEntitlementService {
                        step(
                            symbol: "envelope",
                            title: "The first three days ask for nothing",
                            detail: "They start at your first dictation, not now. After them an email address keeps "
                                + "it running for ten more days, free. Nothing you dictate ever leaves this Mac, and "
                                + "that does not change when you activate."
                        )
                    }
                }
                .witnessCard(.neutral)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shield.checkered")
                        .foregroundStyle(WitnessStyle.success)
                        .accessibilityHidden(true)
                    Text(verbatim: L10n.string("Nothing you dictate ever leaves this Mac. Nine events about setting it up and about the trial do — the install, the speech model arriving or failing to, a press that finds it still arriving, a refused microphone, the trial starting, the email ask, and the offers — with no more than an app version, a macOS version, and a random number made at install. Settings → Privacy turns them off."))
                        .font(.caption)
                        .foregroundStyle(WitnessStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
            }

            // Above the footer and on by default. The hotkey belongs to a running
            // app, and Witness has no Dock icon to bring it back: after the
            // first restart a person who did not switch this on has a shortcut
            // that does nothing and no reminder that an app was ever there.
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $opensAtLogin) {
                    Text(verbatim: L10n.string("Open Witness when I log in"))
                        .font(.callout.weight(.medium))
                }
                Text(verbatim: L10n.string("The hotkey only works while Witness is running, and it has no Dock icon. Without this, a restart leaves the hotkey silent until you open the app again."))
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Everything here is in Settings, and the menu bar icon is where the app lives.")
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(coordinator.transcriptionModelState.isReady ? "Start dictating" : "Continue in background", action: finish)
                    .buttonStyle(WitnessPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 620, alignment: .topLeading)
        .witnessWindow()
        .task {
            await coordinator.refreshTranscriptionModelState()
        }
    }

    /// The microphone is requested only when the user selects the action.
    @ViewBuilder
    private var microphoneStep: some View {
        switch coordinator.microphoneAuthorization {
        case .authorized:
            step(
                symbol: "checkmark.circle",
                title: "The microphone is allowed",
                detail: "Audio is held in memory while you speak and never written to disk."
            )
        case .notDetermined:
            step(
                symbol: "mic",
                title: "Allow microphone access",
                detail: "Witness needs the microphone to hear you. Audio stays in memory and is never saved to disk."
            ) {
                Button("Allow microphone…") {
                    Task { await coordinator.requestMicrophoneAccess() }
                }
                .controlSize(.small)
            }
        case .denied, .restricted:
            step(
                symbol: "exclamationmark.triangle",
                title: "The microphone is blocked",
                detail: "Witness cannot record without it. Turn it on under Privacy & Security → Microphone."
            ) {
                HStack {
                    Button("Open Privacy Settings") { coordinator.openSystemSettings() }
                    Button("Re-check") { coordinator.refreshAuthorization() }
                }
                .controlSize(.small)
            }
        }
    }

    /// Accessibility, which is the one macOS will not grant from a dialog: the
    /// prompt only offers to open System Settings, and the switch is flipped
    /// there. The app watches for it, so this row ticks itself without anyone
    /// coming back to press anything.
    @ViewBuilder
    private var accessibilityStep: some View {
        if coordinator.needsAccessibilityTrust {
            step(
                symbol: "keyboard",
                title: "Allow typing into other apps",
                detail: "Enable Witness in Privacy & Security → Accessibility to insert text where your cursor is. Without it, text goes to the clipboard."
            ) {
                HStack {
                    Button("Allow access…") { coordinator.requestAccessibilityTrust() }
                    Button("Open Settings") { coordinator.openAccessibilitySettings() }
                }
                .controlSize(.small)
            }
        } else {
            step(
                symbol: "checkmark.circle",
                title: "Witness can type for you",
                detail: "Text goes straight into whatever you were writing in."
            )
        }
    }

    /// The download, which the app now starts by itself at launch. The button
    /// stays for the one case that needs it: a fetch that failed, on a Mac that
    /// was offline or out of disk.
    @ViewBuilder
    private var modelStep: some View {
        step(
            symbol: modelSymbol,
            title: modelTitle,
            detail: modelDetail
        ) {
            switch coordinator.transcriptionModelState {
            case .unavailable, .failed:
                Button("Try again") {
                    Task { await coordinator.prepareTranscriptionModel() }
                }
                .controlSize(.small)
            case let .preparing(preparation):
                // Stacked rather than side by side since the label grew into a
                // size and a time: beside a bar it had to be short, and short is
                // what left the first run with a percentage and no idea how long
                // the wait was.
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = preparation.progress {
                        ProgressView(value: progress)
                            .controlSize(.small)
                            .frame(maxWidth: 280)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(coordinator.transcriptionModelState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .ready:
                Text(verbatim: L10n.format("Hold %@ and say a few words to try dictation.", coordinator.binding.displayString))
                    .font(.caption)
                    .foregroundStyle(WitnessStyle.muted)
            }
            if !coordinator.transcriptionModelState.isReady {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: L10n.string(notificationMessage))
                        .font(.caption)
                        .foregroundStyle(WitnessStyle.muted)
                    Button("Notify me when ready", action: notifyWhenReady)
                        .controlSize(.small)
                }
            }
        }
    }

    private var modelSymbol: String {
        switch coordinator.transcriptionModelState {
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .preparing, .unavailable: "arrow.down.circle"
        }
    }

    private var modelTitle: String {
        switch coordinator.transcriptionModelState {
        case .ready: L10n.string("The speech model is ready")
        case .failed: L10n.string("The speech model did not arrive")
        case let .preparing(preparation):
            preparation.phase == .downloading ? L10n.string("The speech model is downloading") : L10n.string("The speech model is preparing")
        case .unavailable: L10n.string("The speech model is not ready")
        }
    }

    private var modelDetail: String {
        switch coordinator.transcriptionModelState {
        case .ready:
            L10n.string("Recognition runs on this Mac, with no network and no account.")
        case let .failed(detail):
            L10n.format(
                "%@ It is about %@ and needs a connection once; everything after that is offline.",
                detail,
                SpeechModelDownloadSize.pinnedVariantSizeText
            )
        case let .preparing(preparation) where preparation.phase != .downloading:
            L10n.string("The model is being prepared on this Mac. Keep Witness running until it is ready.")
        case .preparing, .unavailable:
            L10n.format(
                "About %@, downloaded once. This can take 5–15 minutes depending on your connection and Mac. Keep Witness running; recognition then happens locally.",
                SpeechModelDownloadSize.pinnedVariantSizeText
            )
        }
    }

    private func step(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            WitnessIconTile(systemImage: symbol, tint: stepTint(for: symbol))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.string(title))
                    .font(.callout.weight(.medium))
                Text(verbatim: L10n.string(detail))
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                action()
                    .buttonStyle(WitnessSecondaryButtonStyle())
            }
        }
    }

    private func stepTint(for symbol: String) -> Color {
        if symbol.contains("checkmark") { return WitnessStyle.success }
        if symbol.contains("exclamationmark") { return WitnessStyle.warning }
        return WitnessStyle.muted
    }
}
