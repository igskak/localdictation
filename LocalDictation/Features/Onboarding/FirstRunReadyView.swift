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
                step(
                    symbol: "mic",
                    title: "The microphone, once",
                    detail: "macOS asks the first time you press the key. Audio is held in memory while you speak "
                        + "and never written to disk."
                )

                if coordinator.hasTranscriptionEngine {
                    modelStep
                }

                step(
                    symbol: "keyboard",
                    title: "Typing into other applications",
                    detail: "Witness asks for Accessibility the first time it has text to insert. Without it "
                        + "the text goes to the clipboard instead, and everything else still works."
                )

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
        .onAppear {
            Task { await coordinator.refreshTranscriptionModelState() }
        }
    }

    /// The one step with something to do on it. The download is user-initiated
    /// here for the same reason it is everywhere else: six hundred megabytes is
    /// not something an app helps itself to.
    @ViewBuilder
    private var modelStep: some View {
        step(
            symbol: coordinator.transcriptionModelState.isReady ? "checkmark.circle" : "arrow.down.circle",
            title: coordinator.transcriptionModelState.isReady ? "The speech model is ready" : "The speech model, once",
            detail: coordinator.transcriptionModelState.isReady
                ? "Recognition runs on this Mac, with no network and no account."
                : "About 600 MB, downloaded once, and then recognition runs on this Mac with no network. "
                    + "It is the longest wait in the product and it is better spent now than mid-sentence."
        ) {
            switch coordinator.transcriptionModelState {
            case .unavailable, .failed:
                Button("Prepare speech model…") {
                    Task { await coordinator.prepareTranscriptionModel() }
                }
                .controlSize(.small)
            case .preparing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(coordinator.transcriptionModelState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                EmptyView()
            }
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
