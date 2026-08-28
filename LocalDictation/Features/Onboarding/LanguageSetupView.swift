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
        case languages
        case ready
    }

    @Published var selection: LanguageProfile
    @Published var step: Step = .languages

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Which languages do you speak?")
                    .font(.title2)
                Text("Every utterance is recognized as one of the languages you pick here, and never as one you did not. Pick as many as you actually use — there is nothing to switch between afterwards.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LanguageSelectionEditor(selection: $model.selection)

            HStack {
                Text(model.selection.shortLabel)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Continue", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }

            Text("You can change this at any time in Settings \u{2192} Languages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520, height: 620)
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

    var body: some View {
        switch model.step {
        case .languages:
            LanguageSetupView(model: model, confirm: confirm)
        case .ready:
            FirstRunReadyView(coordinator: coordinator, finish: finish)
        }
    }
}
