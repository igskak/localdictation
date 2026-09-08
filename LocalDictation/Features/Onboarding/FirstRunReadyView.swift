import SwiftUI

/// The half of the first run that was missing.
///
/// The language question was the only thing this app ever asked, and when it
/// closed, a person who had just installed a menu bar utility with no Dock icon
/// and no window was left to work out on their own that there is a hotkey, that
/// macOS will ask for a microphone, that six hundred megabytes have to arrive
/// before anything is recognized, and that the fifth dictation is followed by a
/// wall.
///
/// All four of those are findable — the menu says every one of them. But they
/// are findable *after* the confusion, and the fourth one in particular is the
/// difference between "this asked me for an email, fair enough" and "this
/// stopped working". A person told about a limit before they reach it has been
/// sold something; a person who discovers it has been surprised by it.
///
/// Since the first stranger installed it, this screen does the three things as
/// well as describing them. It asks macOS for the microphone and for
/// Accessibility as it appears — every other app on the Mac asks at launch, and
/// leaving the two asks in a menu bar window meant a product that looked broken
/// until they were found — and the speech model is already downloading behind
/// it. What is left for the reader is the one thing no app can do for them:
/// granting Accessibility in System Settings.
///
/// It is one screen, it is skippable by closing the window, and it appears
/// exactly once — right after the question it follows, while the app is still
/// the thing the user is looking at.
struct FirstRunReadyView: View {
    @ObservedObject var coordinator: DictationCoordinator
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hold \(coordinator.binding.displayString) and speak")
                    .font(.title2)
                Text(
                    "Let go and the text arrives where your cursor is. That is the whole of it — "
                        + "there is no window to switch to and nothing to click."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                microphoneStep

                if coordinator.hasTranscriptionEngine {
                    modelStep
                }

                if coordinator.canInsert {
                    accessibilityStep
                }

                if coordinator.hasEntitlementService {
                    step(
                        symbol: "envelope",
                        title: "The first \(EntitlementPolicy.ungatedDictations) dictations ask for nothing",
                        detail: "After that — or 24 hours after the first one — an email address keeps it running "
                            + "for fourteen more days, free. Nothing you dictate ever leaves this Mac, and that "
                            + "does not change when you activate."
                    )
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text("Everything here is in Settings, and the menu bar icon is where the app lives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Start dictating", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 620, alignment: .topLeading)
        .task {
            await coordinator.refreshTranscriptionModelState()
            // The two system dialogs, in order, while this window is behind
            // them saying what each one is for. The coordinator asks once per
            // launch, so a view rebuilt for any reason cannot ask twice.
            await coordinator.requestFirstRunPermissions()
        }
    }

    /// The microphone. macOS answers this one from inside its own dialog, so on
    /// the ordinary path the row is already ticked by the time it is read.
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
                title: "The microphone, once",
                detail: "macOS is asking now. Audio is held in memory while you speak and never written to disk."
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
                title: "Typing into other applications",
                detail: "macOS is asking now. Open System Settings from its prompt and switch Witness on under "
                    + "Accessibility — this window notices on its own. Without it the text goes to the "
                    + "clipboard instead, and everything else still works."
            ) {
                HStack {
                    Button("Ask again") { coordinator.requestAccessibilityTrust() }
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
                HStack(spacing: 6) {
                    if let progress = preparation.progress {
                        ProgressView(value: progress)
                            .controlSize(.small)
                            .frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(coordinator.transcriptionModelState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                EmptyView()
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
        case .ready: "The speech model is ready"
        case .failed: "The speech model did not arrive"
        case .preparing, .unavailable: "The speech model is downloading"
        }
    }

    private var modelDetail: String {
        switch coordinator.transcriptionModelState {
        case .ready:
            "Recognition runs on this Mac, with no network and no account."
        case let .failed(detail):
            "\(detail) It is about 600 MB and needs a connection once; everything after that is offline."
        case .preparing, .unavailable:
            "About 600 MB, fetched once, usually within five minutes. It started on its own when the app "
                + "launched — you can close this window and it keeps going. Afterwards recognition runs on "
                + "this Mac with no network at all."
        }
    }

    private func step(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
}
