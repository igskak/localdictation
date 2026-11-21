import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The one window of the feature: a drop target while idle, a progress panel
/// while a file runs, an explanation when it could not.
struct FileTranscriptionView: View {
    @ObservedObject var coordinator: FileTranscriptionCoordinator
    @State private var isTargeted = false
    @State private var showOneFileHint = false

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
        .frame(width: 460, height: 360)
        .witnessWindow()
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard !coordinator.isRunning else { return false }
            guard providers.count == 1, let provider = providers.first else {
                showOneFileHint = true
                return true
            }
            showOneFileHint = false
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in coordinator.start(url: url) }
            }
            return true
        }
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            WitnessIconTile(systemImage: "waveform", tint: WitnessStyle.accent)
            Text("Turn a recording into text")
                .font(.title2.weight(.semibold))
            Text("Drop an audio or video file here, or choose one below.")
                .font(.callout)
                .foregroundStyle(WitnessStyle.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose file…") { choose() }
                .buttonStyle(WitnessPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            Text(verbatim: "M4A, MP3, WAV, AIFF, CAF, MP4, MOV")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
            if showOneFileHint {
                Text("Choose one file at a time.")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.warning)
            }
            Label("Your file stays on this Mac.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(WitnessStyle.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? WitnessStyle.accent.opacity(0.07) : WitnessStyle.surface, in: RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius)
                .strokeBorder(isTargeted ? WitnessStyle.accent : WitnessStyle.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .allowsHitTesting(false)
        }
    }

    private func running(name: String, progress: FileTranscriptionProgress?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                WitnessIconTile(systemImage: "waveform", tint: WitnessStyle.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcribing a file").font(.headline)
                    Text(verbatim: name)
                        .font(.callout)
                        .foregroundStyle(WitnessStyle.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(name)
                }
            }
            if coordinator.isCancelling {
                ProgressView()
                Text("Stopping…").font(.callout).foregroundStyle(WitnessStyle.muted)
            } else if let progress {
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
            } else if let wait = coordinator.modelWait {
                if let fraction = wait.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text("Preparing the speech model").font(.callout.weight(.medium))
                    Spacer()
                    TimelineView(.periodic(from: wait.since, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(wait.since))).monospacedDigit()
                    }
                }
                Text(wait.message)
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().progressViewStyle(.linear)
                Text("Getting the first part of your transcript ready…")
                    .font(.callout)
                    .foregroundStyle(WitnessStyle.muted)
            }
            Text("You can dictate again when your file is ready.")
                .font(.caption)
                .foregroundStyle(WitnessStyle.faint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { coordinator.cancel() }
                    .buttonStyle(WitnessSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(coordinator.isCancelling)
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
            Text("This file needs another try")
                .font(.title3.weight(.semibold))
            Text(failure.message)
                .font(.callout)
                .foregroundStyle(WitnessStyle.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose a file…") { choose() }
                .buttonStyle(WitnessPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose() {
        showOneFileHint = false
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("Transcribe a file")
        window.titlebarAppearsTransparent = true
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FileTranscriptionView(coordinator: coordinator))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }
}
