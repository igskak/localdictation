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

/// The only Notetaker surface visible to the existing application shell.
/// Later slices can put their coordinator behind this boundary without adding
/// meeting states or effects to `DictationCoordinator`.
@MainActor
protocol NotetakerFacade: AnyObject {
    var menuBarItem: NotetakerMenuItem? { get }
    func activate()
    func deactivate()
}

/// Disabled means no UI and no lifecycle work. In particular, this type owns
/// no permission, detection, persistence, audio, or model dependency.
@MainActor
final class UnavailableNotetakerFacade: NotetakerFacade {
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
