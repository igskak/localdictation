import Foundation

/// The application a dictation was spoken into.
///
/// Captured when recording starts rather than read when inserting, per
/// `docs/PHASE_4.md`: between the hotkey going down and the text being ready
/// lie transcription and possibly a review the user takes seconds over, and the
/// frontmost application at the end of that is not reliably the one they spoke
/// into.
///
/// Non-content by construction. It carries the identity of an application and
/// nothing about what is inside it — no window title, no field contents, no
/// document name. That is what makes it safe to log and to show in diagnostics.
struct InsertionTarget: Sendable, Equatable, Identifiable {
    let id: UUID
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String?

    init(
        id: UUID = UUID(),
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String?
    ) {
        self.id = id
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }

    /// What the user is told the text went into. The bundle identifier is the
    /// fallback because it is the only thing guaranteed to be there.
    var displayName: String {
        applicationName ?? bundleIdentifier ?? "the previous application"
    }

    /// Identity for logs and diagnostics: never the display name, which is
    /// localized and user-facing, and never anything read out of the app.
    var logIdentity: String { bundleIdentifier ?? "pid:\(processIdentifier)" }
}
