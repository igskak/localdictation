import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The one window of the feature: a drop target while idle, a progress panel
/// while a file runs, an explanation when it could not.
struct FileTranscriptionView: View {
    @ObservedObject var coordinator: FileTranscriptionCoordinator
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            switch coordinator.phase {
            case .idle:
                chooser
            case let .running(name, progress):
                running(name: name, progress: progress)
            case let .failed(failure):
                failed(failure)
            }
        }
        .padding(28)
        .frame(width: 460, height: 330)
        .witnessWindow()
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard !coordinator.isRunning, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in coordinator.start(url: url) }
            }
            return true
        }
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isTargeted ? WitnessStyle.accent : WitnessStyle.muted)
                .accessibilityHidden(true)
            Text("Transcribe an audio or video file")
                .font(.title3.weight(.semibold))
            Text("Drop a file here, or choose one. Witness reads it where it is, recognises it on this Mac, and keeps only the transcript.")
                .font(.callout)
                .foregroundStyle(WitnessStyle.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose file…") { choose() }
                .buttonStyle(WitnessPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            Text("m4a, mp3, wav, aiff, caf, mp4, mov")
                .font(.caption)
                .foregroundStyle(WitnessStyle.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius)
                .strokeBorder(isTargeted ? WitnessStyle.accent : WitnessStyle.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(-10)
                .allowsHitTesting(false)
        }
    }

    private func running(name: String, progress: FileTranscriptionProgress?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(name, systemImage: "waveform")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if let progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Progress")
                    .accessibilityValue(progress.fraction.formatted(.percent.precision(.fractionLength(0))))
                HStack {
                    Text(Self.clock(progress.elapsed)).monospacedDigit()
                    Spacer()
                    Text(progress.remaining.map { L10n.format("About %@ left", Self.approximate($0)) } ?? L10n.string("Estimating time left…"))
                }
                .font(.callout)
                .foregroundStyle(WitnessStyle.muted)
            } else {
                ProgressView().progressViewStyle(.linear)
                Text("Preparing the speech model and reading the file…")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
            }
            Text("Dictation is paused until this is done. The file never leaves this Mac.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.faint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { coordinator.cancel() }
                    .buttonStyle(WitnessSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func failed(_ failure: FileTranscriptionFailure) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(WitnessStyle.warning)
                .accessibilityHidden(true)
            Text("The file was not transcribed")
                .font(.title3.weight(.semibold))
            Text(failure.message)
                .font(.callout)
                .foregroundStyle(WitnessStyle.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose another file") { coordinator.dismissFailure() }
                .buttonStyle(WitnessPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FileTranscriptionCoordinator.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = L10n.string("Choose an audio or video file to transcribe")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.start(url: url)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "5 min", "1 h 10 min": rounded, because the estimate is one.
    static func approximate(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        if minutes < 60 { return L10n.format("%lld min", Int64(minutes)) }
        return L10n.format("%lld h %lld min", Int64(minutes / 60), Int64(minutes % 60))
    }
}

@MainActor
final class FileTranscriptionWindowController: NSObject {
    private let coordinator: FileTranscriptionCoordinator
    private var window: NSWindow?

    init(coordinator: FileTranscriptionCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Transcribe audio file")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FileTranscriptionView(coordinator: coordinator))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }
}
