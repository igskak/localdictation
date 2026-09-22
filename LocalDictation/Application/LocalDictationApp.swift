import SwiftUI

/// The visual language shared by every Witness surface.
///
/// These values deliberately mirror the landing page. Keeping them here makes
/// the menu, onboarding, settings, paywall, and review panel feel like one
/// product, while every screen continues to use native SwiftUI controls.
enum WitnessStyle {
    static let canvas = Color(red: 17 / 255, green: 18 / 255, blue: 16 / 255)
    static let surface = Color(red: 27 / 255, green: 28 / 255, blue: 25 / 255)
    static let raisedSurface = Color(red: 34 / 255, green: 35 / 255, blue: 31 / 255)
    static let ink = Color(red: 244 / 255, green: 244 / 255, blue: 239 / 255)
    static let muted = Color(red: 178 / 255, green: 177 / 255, blue: 170 / 255)
    static let faint = Color(red: 139 / 255, green: 138 / 255, blue: 131 / 255)
    static let line = Color.white.opacity(0.11)
    static let strongLine = Color.white.opacity(0.17)
    static let accent = Color(red: 1, green: 104 / 255, blue: 70 / 255)
    static let success = Color(red: 143 / 255, green: 196 / 255, blue: 134 / 255)
    static let warning = Color(red: 245 / 255, green: 174 / 255, blue: 92 / 255)

    static let cornerRadius: CGFloat = 14
    static let compactCornerRadius: CGFloat = 10
}

enum WitnessCardTone {
    case neutral
    case accent
    case success
    case warning

    fileprivate var fill: Color {
        switch self {
        case .neutral: WitnessStyle.surface
        case .accent: WitnessStyle.accent.opacity(0.10)
        case .success: WitnessStyle.success.opacity(0.10)
        case .warning: WitnessStyle.warning.opacity(0.10)
        }
    }

    fileprivate var border: Color {
        switch self {
        case .neutral: WitnessStyle.line
        case .accent: WitnessStyle.accent.opacity(0.34)
        case .success: WitnessStyle.success.opacity(0.32)
        case .warning: WitnessStyle.warning.opacity(0.34)
        }
    }
}

struct WitnessBrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: max(1.5, size * 0.07)) {
            ForEach(Array([0.32, 0.55, 0.78, 0.55, 0.32].enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(WitnessStyle.canvas)
                    .frame(width: max(2, size * 0.075), height: size * height)
            }
        }
        .frame(width: size, height: size)
        .background(WitnessStyle.ink, in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
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
            .preferredColorScheme(.dark)
    }
}

struct WitnessPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color(red: 36 / 255, green: 18 / 255, blue: 13 / 255))
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(
                configuration.isPressed ? WitnessStyle.accent.opacity(0.82) : WitnessStyle.accent,
                in: Capsule()
            )
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
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(WitnessStyle.strongLine, lineWidth: 1)
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
}

@main
struct LocalDictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator: DictationCoordinator

    init() {
        // Before `makeLive`, which is what constructs the stores: the folder has
        // to have been carried across from the product's old name before
        // anything looks inside it for a licence.
        ApplicationSupportDirectory.prepare()
        let coordinator = DictationCoordinator.makeLive()
        _coordinator = StateObject(wrappedValue: coordinator)
        // The delegate activates the coordinator once AppKit has finished
        // launching, so hotkey registration happens against a live event target.
        AppDelegate.coordinator = coordinator
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
        } label: {
            // The indicator lives here because this is the one place that is on
            // screen whatever the user is doing. `MenuBarExtra` renders its
            // label as a template image, so the alert is the symbol itself
            // rather than a badge drawn over one.
            Label(
                "Witness",
                systemImage: StatusPresentation(
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
