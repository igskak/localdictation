import Foundation

/// The sentence the menu shows *before* the app stops working.
///
/// Every other piece of licensing copy in this product is written for someone
/// who has already been refused. This is the one written for someone who has
/// not: the ungated window is five dictations wide, and a person who learns
/// about it by pressing the hotkey and getting nothing has been surprised by
/// their own software. Settings → License has carried the countdown since
/// Phase 6, but nobody opens Settings to find out that something is about to
/// break.
///
/// It is `nil` far more often than not, and that is the point — a countdown
/// that is always on screen is a countdown nobody reads on the day it matters.
struct EntitlementNotice: Sendable, Equatable {
    /// A trial has days in it; the ungated window has five presses in it. The
    /// two thresholds are different because the units are.
    static let trialWarningDays = 3
    static let annualWarningDays = 14

    let headline: String
    let detail: String
    /// What the button under it says. The same two doors as everywhere else:
    /// an address, or a license.
    let actionTitle: String
    let symbol: String
    /// Whether this is the last warning rather than a heads-up. Drives emphasis
    /// only — nothing is refused here.
    let isPressing: Bool

    init?(state: EntitlementState, now: Date = Date()) {
        switch state {
        case let .ungated(standing):
            // Nothing has been spent yet, so there is nothing to count down.
            // The app has asked for nothing and says nothing.
            guard let expiresAt = standing.expiresAt else { return nil }
            let remaining = standing.dictationsRemaining
            headline = remaining == 1
                ? "One dictation left before activation"
                : "\(remaining) dictations left before activation"
            detail = """
            Or until \(Self.moment.string(from: expiresAt)) — whichever comes first. \
            An email address turns this into the full fourteen days, and nothing else changes.
            """
            actionTitle = "Activate…"
            symbol = "envelope"
            isPressing = remaining <= 1

        case let .licensed(license):
            switch license.kind {
            case .trial:
                guard
                    let days = license.daysRemaining(at: now),
                    days <= Self.trialWarningDays,
                    let expiresAt = license.expiresAt
                else { return nil }
                headline = days <= 1 ? "The trial ends today" : "The trial ends in \(days) days"
                detail = """
                It runs out on \(Self.moment.string(from: expiresAt)). A license keeps this Mac \
                dictating; your dictionary and settings stay exactly as they are either way.
                """
                actionTitle = "Open License settings"
                symbol = "clock.badge.exclamationmark"
                isPressing = days <= 1

            case .annual:
                guard
                    let days = license.daysRemaining(at: now),
                    days <= Self.annualWarningDays,
                    let expiresAt = license.expiresAt
                else { return nil }
                headline = days <= 1 ? "Your license ends today" : "Your license ends in \(days) days"
                detail = """
                It runs out on \(Self.moment.string(from: expiresAt)). Renewing before then means \
                dictation never stops; nothing local is touched either way.
                """
                actionTitle = "Open License settings"
                symbol = "clock.badge.exclamationmark"
                isPressing = days <= Self.trialWarningDays

            // Nothing is ever going to happen to a lifetime license, so there
            // is nothing to warn about. Putting a notice here would be an
            // advertisement in a menu belonging to someone who already paid.
            case .lifetime:
                return nil
            }

        // Already refused. `LicensePresentation` and the lock view own this
        // state, and two boxes saying the same thing is worse than one.
        case .locked:
            return nil
        }
    }

    private static let moment: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
