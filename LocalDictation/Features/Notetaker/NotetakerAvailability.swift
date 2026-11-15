import Combine
import Foundation

/// The single product gate for the Notetaker subsystem.
///
/// The shipping default stays disabled until the release gate changes it. The
/// composition root is the only place that switches on this value: callers get
/// a facade either way and never scatter availability checks through the app.
enum NotetakerAvailability: Sendable, Equatable {
    case disabled
    case enabled

    #if NOTETAKER_DOGFOOD
    static let liveDefault: NotetakerAvailability = .enabled
    #else
    static let liveDefault: NotetakerAvailability = .disabled
    #endif
}

/// A menu action supplied by an available Notetaker implementation.
///
/// Slice 0 has no available implementation, so the unavailable facade always
/// returns `nil` and the existing menu remains byte-for-byte in behavior.
@MainActor
struct NotetakerMenuItem {
    let title: String
    let systemImage: String
    let action: () -> Void
}

@MainActor
struct NotetakerSuggestion {
    let platform: MeetingPlatform
    let start: () -> Void
    let dismiss: () -> Void

    var title: String {
        switch platform {
        case .zoom: "Zoom call detected"
        case .googleMeet: "Possible Google Meet call"
        case .safari: "Possible Safari call"
        case .manual: "Meeting detected"
        }
    }

    var detail: String {
        switch platform {
        case .zoom: "Create a local note from your microphone and Zoom audio?"
        case .googleMeet: "Chrome is playing audio. If this is a Meet call, Witness can create a local note."
        case .safari: "Safari is playing audio. If this is a call, Witness can create a local note."
        case .manual: "Create a local meeting note?"
        }
    }
}

enum NotetakerActivityState: Sendable, Equatable {
    case idle
    case suggestion
    case preparing
    case recording
    case paused
    case finishing
    case attention
}

/// Observable presentation shared by the Notetaker implementation and the
/// app's existing menu-bar item. Keeping the state here avoids creating a
/// second `NSStatusItem`, whose scene lifetime can race AppKit while the
/// MenuBarExtra that launched the meeting window is closing.
@MainActor
final class NotetakerStatus: ObservableObject {
    @Published private(set) var state: NotetakerActivityState = .idle

    var isActive: Bool {
        switch state {
        case .preparing, .recording, .paused, .finishing: true
        case .idle, .suggestion, .attention: false
        }
    }

    var systemImage: String? {
        switch state {
        case .idle: nil
        case .suggestion: "note.text.badge.plus"
        case .preparing, .finishing: "hourglass"
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch state {
        case .idle: "Witness"
        case .suggestion: "Witness found a possible meeting"
        case .preparing: "Witness is preparing a meeting note"
        case .recording: "Witness is recording a meeting note"
        case .paused: "Witness meeting recording is paused"
        case .finishing: "Witness is finishing a meeting note"
        case .attention: "Witness meeting note needs attention"
        }
    }

    func update(_ state: NotetakerActivityState) {
        self.state = state
    }
}

/// The only Notetaker surfaces visible to the existing application shell.
/// The recording and history actions stay behind this boundary without adding
/// meeting states or effects to `DictationCoordinator`.
@MainActor
protocol NotetakerFacade: AnyObject {
    var status: NotetakerStatus { get }
    var suggestion: NotetakerSuggestion? { get }
    var menuBarItem: NotetakerMenuItem? { get }
    var historyMenuItem: NotetakerMenuItem? { get }
    var stopMenuItem: NotetakerMenuItem? { get }
    func activate()
    func deactivate()
}

extension NotetakerFacade {
    var suggestion: NotetakerSuggestion? { nil }
    var historyMenuItem: NotetakerMenuItem? { nil }
    var stopMenuItem: NotetakerMenuItem? { nil }
}

/// Disabled means no UI and no lifecycle work. In particular, this type owns
/// no permission, detection, persistence, audio, or model dependency.
@MainActor
final class UnavailableNotetakerFacade: NotetakerFacade {
    let status = NotetakerStatus()
    var menuBarItem: NotetakerMenuItem? { nil }

    func activate() {}
    func deactivate() {}
}

/// One decision point for constructing the feature. The builder is not touched
/// while disabled, so constructors with side effects cannot run accidentally.
@MainActor
enum NotetakerCompositionRoot {
    static func make(
        availability: NotetakerAvailability,
        buildAvailableSubsystem: () -> any NotetakerFacade
    ) -> any NotetakerFacade {
        switch availability {
        case .disabled:
            UnavailableNotetakerFacade()
        case .enabled:
            buildAvailableSubsystem()
        }
    }
}
