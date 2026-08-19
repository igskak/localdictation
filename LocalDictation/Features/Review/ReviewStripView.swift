import AppKit
import SwiftUI

/// The single place verification lives.
///
/// It appears only when the risk policy says the interruption is earned, and
/// it holds the three things a user needs to settle a doubt: the marked text,
/// the raw transcript the app started from, and the audio of a marked fragment.
struct ReviewStripView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator

    let result: DictationResult

    @State private var didCopy = false

    private var presentation: ReviewPresentation {
        ReviewPresentation(text: result.cleanedText, flagged: result.flaggedSpans)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if coordinator.prefersRawTranscript {
                rawTranscript
            } else {
                markedText
            }

            if !presentation.explanations.isEmpty {
                explanations
            }

            actions
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .onChange(of: result) {
            didCopy = false
            coordinator.stopReplay()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.orange)
            Text(presentation.summary)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(result.profile.shortLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var markedText: some View {
        TranscriptText {
            // One attributed string rather than a row of separate views, so a
            // marked fragment stays inside the sentence the user is reading
            // instead of being lifted out of it.
            Text(markedAttributedText)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private var markedAttributedText: AttributedString {
        var output = AttributedString()
        for segment in presentation.segments {
            var piece = AttributedString(segment.text)
            if segment.isMarked {
                piece.backgroundColor = Color.orange.opacity(0.3)
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            output.append(piece)
        }
        return output
    }

    private var rawTranscript: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Raw transcript, exactly as recognized")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TranscriptText {
                Text(result.rawText)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private var explanations: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(presentation.explanations) { explanation in
                HStack(spacing: 6) {
                    Text(explanation.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: Capsule())

                    Text(explanation.fragment)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if explanation.isPlayable, coordinator.canReplayFragments {
                        Button {
                            coordinator.replay(explanation.span)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Play this fragment from memory")
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(coordinator.prefersRawTranscript ? "Show cleaned text" : "Show raw transcript") {
                coordinator.prefersRawTranscript.toggle()
                didCopy = false
            }
            .font(.caption)

            Spacer()

            Button(didCopy ? "Copied" : "Copy") {
                let text = result.text(preferringRaw: coordinator.prefersRawTranscript)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                didCopy = true
            }
            .disabled(didCopy)

            Button("Done") {
                coordinator.acceptReview()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Shows an utterance at its natural height, and scrolls only when one genuinely
/// does not fit.
///
/// The first version wrapped the text in a `ScrollView` capped at 110 points.
/// A dictated sentence is almost always one or two lines, far short of that cap,
/// yet the top of the first line came back clipped: a marked fragment carries a
/// highlight background and bold emphasis, which draw outside the line box
/// `Text` reports, and the scroll view cut at its own bounds.
///
/// So the common case gets no scroll view at all. `ViewThatFits` falls back to a
/// bounded scrolling copy only for an utterance long enough to need one, which
/// also keeps the panel from growing without limit after a two-minute recording.
private struct TranscriptText<Content: View>: View {
    private let maximumHeight: CGFloat = 110

    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            laidOut
            ScrollView { laidOut }.frame(height: maximumHeight)
        }
        .frame(maxHeight: maximumHeight)
    }

    private var laidOut: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // Room for the highlight and the emphasized run to draw fully.
            .padding(.vertical, 2)
    }
}
