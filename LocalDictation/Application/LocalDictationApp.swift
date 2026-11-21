import SwiftUI
import AppKit

/// The visual language shared by every Witness surface.
///
/// Adaptive surfaces keep all windows in the system appearance. Native controls
/// retain their keyboard, focus, accessibility, and increased-contrast behavior.
enum WitnessStyle {
    static let canvas = adaptive(light: 0xf6f8fc, dark: 0x19212d)
    static let sidebar = adaptive(light: 0xe8eef7, dark: 0x222e40)
    static let surface = adaptive(light: 0xffffff, dark: 0x252e3c)
    static let raisedSurface = adaptive(light: 0xe8edf5, dark: 0x111a27)
    static let ink = Color.primary
    static let muted = adaptive(light: 0x626e7e, dark: 0xafbacb)
    static let faint = muted
    static let line = Color(nsColor: .separatorColor).opacity(0.55)
    static let strongLine = Color(nsColor: .separatorColor)
    static let accent = adaptive(light: 0x075fc9, dark: 0x75b5ff)
    static let actionFill = Color(red: 7 / 255, green: 95 / 255, blue: 201 / 255)
    static let success = adaptive(light: 0x187c45, dark: 0x77d69b)
    static let warning = adaptive(light: 0x8a5700, dark: 0xf5c46b)
    static let highlight = adaptive(light: 0xffedb2, dark: 0x665319)

    static let cornerRadius: CGFloat = 18
    static let compactCornerRadius: CGFloat = 12

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

enum WitnessCardTone {
    case neutral
    case accent
    case success
    case warning

    fileprivate var fill: Color {
        WitnessStyle.surface
    }

    fileprivate var border: Color {
        switch self {
        case .neutral: WitnessStyle.line
        case .accent, .success, .warning: WitnessStyle.line
        }
    }
}

struct WitnessBrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: max(1.5, size * 0.07)) {
            ForEach(Array([0.32, 0.55, 0.78, 0.55, 0.32].enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(.white)
                    .frame(width: max(2, size * 0.075), height: size * height)
            }
        }
        .frame(width: size, height: size)
        .background(WitnessStyle.actionFill.gradient, in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct WitnessBrand: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            WitnessBrandMark(size: compact ? 25 : 29)
            Text("Witness")
                .font(compact ? .headline : .title3.weight(.semibold))
                .tracking(-0.35)
        }
        .accessibilityElement(children: .combine)
    }
}

struct WitnessIconTile: View {
    let systemImage: String
    var tint: Color = WitnessStyle.muted

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct WitnessSetupProgress: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index == step - 1 ? WitnessStyle.accent : WitnessStyle.muted.opacity(0.25))
                    .frame(width: index == step - 1 ? 16 : 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("Step %lld of %lld", Int64(step), Int64(total)))
    }
}

/// Native fields in shared, inset groups. A single container keeps settings,
/// vocabulary, diagnostics, and licensing visually consistent in both themes.
struct WitnessSettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .labeledContentStyle(WitnessSettingsLabelStyle())
    }
}

private struct WitnessSettingsLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

private struct WitnessSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label.accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle(configuration)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct WitnessSettingsSection<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(LocalizedStringKey(title))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(WitnessStyle.muted)
                    .padding(.horizontal, 3)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .witnessCard(padding: 16)
        }
    }
}

private struct WitnessCardModifier: ViewModifier {
    let tone: WitnessCardTone
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(tone.fill, in: RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WitnessStyle.cornerRadius, style: .continuous)
                    .stroke(tone.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct WitnessWindowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(WitnessStyle.ink)
            .tint(WitnessStyle.accent)
            .background(WitnessStyle.canvas)
            .toggleStyle(WitnessSwitchStyle())
    }
}

struct WitnessPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 38)
            .background(
                WitnessStyle.actionFill.gradient,
                in: Capsule()
            )
            .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.42)
    }
}

struct WitnessSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(WitnessStyle.ink)
            .padding(.horizontal, 13)
            .frame(minHeight: 32)
            .background(
                configuration.isPressed ? WitnessStyle.raisedSurface : WitnessStyle.surface,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WitnessStyle.line, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
    }
}

extension View {
    func witnessCard(_ tone: WitnessCardTone = .neutral, padding: CGFloat = 14) -> some View {
        modifier(WitnessCardModifier(tone: tone, padding: padding))
    }

    func witnessWindow() -> some View {
        modifier(WitnessWindowModifier())
    }

    func witnessSettingsForm() -> some View {
        self.background(WitnessStyle.canvas)
            .controlSize(.regular)
    }
}

@main
struct LocalDictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator: DictationCoordinator
    @StateObject private var notetakerStatus: NotetakerStatus
    private let notetaker: any NotetakerFacade
    private let fileTranscription: FileTranscriptionFeature

    init() {
        // Before `makeLive`, which is what constructs the stores: the folder has
        // to have been carried across from the product's old name before
        // anything looks inside it for a licence.
        ApplicationSupportDirectory.prepare()
        let composition = ApplicationComposition.makeLive()
        _coordinator = StateObject(wrappedValue: composition.dictationCoordinator)
        _notetakerStatus = StateObject(wrappedValue: composition.notetaker.status)
        notetaker = composition.notetaker
        fileTranscription = composition.fileTranscription
        // The delegate activates the coordinator once AppKit has finished
        // launching, so hotkey registration happens against a live event target.
        AppDelegate.coordinator = composition.dictationCoordinator
        AppDelegate.notetaker = composition.notetaker
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(notetaker: notetaker, fileTranscription: fileTranscription)
                .environmentObject(coordinator)
        } label: {
            // The indicator lives here because this is the one place that is on
            // screen whatever the user is doing. `MenuBarExtra` renders its
            // label as a template image, so the alert is the symbol itself
            // rather than a badge drawn over one.
            Label(
                coordinator.isFileTranscriptionRunning ? L10n.string("Transcribing a file") : notetakerStatus.accessibilityLabel,
                systemImage: coordinator.isFileTranscriptionRunning ? "waveform.badge.magnifyingglass" : notetakerStatus.systemImage ?? StatusPresentation(
                    state: coordinator.state,
                    binding: coordinator.binding,
                    // Carried into the label since the app fetches the model
                    // itself: the arrow in the menu bar is the only sign a
                    // first-run download is happening that reaches somebody who
                    // has not opened anything.
                    modelState: coordinator.transcriptionModelState,
                    attentionIsPending: coordinator.attentionIsPending,
                    silentResult: coordinator.silentResult,
                    captureInterruption: coordinator.captureInterruptionMessage
                ).systemImage
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(coordinator)
        }
    }
}

/// Live application composition. Dictation is constructed exactly as before;
/// the Notetaker gate is resolved beside it without letting a disabled feature
/// construct any of its future system-facing dependencies.
@MainActor
struct ApplicationComposition {
    let dictationCoordinator: DictationCoordinator
    let notetaker: any NotetakerFacade
    let fileTranscription: FileTranscriptionFeature

    static func make(
        notetakerAvailability: NotetakerAvailability,
        fileEngine: (any TranscriptionService)? = nil,
        makeDictationCoordinator: () -> DictationCoordinator,
        makeAvailableNotetaker: (DictationCoordinator) -> any NotetakerFacade
    ) -> ApplicationComposition {
        let coordinator = makeDictationCoordinator()
        let notetaker = NotetakerCompositionRoot.make(
            availability: notetakerAvailability,
            buildAvailableSubsystem: { makeAvailableNotetaker(coordinator) }
        )
        return ApplicationComposition(
            dictationCoordinator: coordinator,
            notetaker: notetaker,
            fileTranscription: FileTranscriptionFeature(
                host: coordinator, engine: fileEngine, meetingIsActive: { notetaker.status.isActive }
            )
        )
    }

    static func makeLive(
        notetakerAvailability: NotetakerAvailability = .liveDefault
    ) -> ApplicationComposition {
        // One selected model, loaded once for dictation and meeting windows.
        let speech = DictationEngineChoice.active.makeClients()
        return make(
            notetakerAvailability: notetakerAvailability,
            fileEngine: speech.file,
            makeDictationCoordinator: {
                DictationCoordinator.makeLive(transcriptionService: speech.dictation)
            },
            // The public demo uses the same account settings and local engine.
            // An injected disabled gate still constructs no meeting services.
            makeAvailableNotetaker: { coordinator in
                DogfoodNotetakerFacade(
                    languageProfileProvider: { [weak coordinator] in
                        coordinator?.languageProfile ?? .default
                    },
                    transcription: speech.meeting,
                    fileIsActive: { [weak coordinator] in coordinator?.isFileTranscriptionRunning ?? false },
                    // Read when each meeting starts, like the language profile.
                    cleanupProvider: { [weak coordinator] in
                        MeetingTextCleanup(
                            glossary: coordinator?.glossary ?? .empty,
                            level: coordinator?.cleanupLevel ?? .conservative
                        )
                    }
                )
            }
        )
    }
}
