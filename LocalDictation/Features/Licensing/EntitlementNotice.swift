import Foundation

/// The sentence the menu shows *before* the app stops working.
///
/// Every other piece of licensing copy in this product is written for someone
/// who has already been refused. This is the one written for someone who has
/// not: the ungated window closes on its own, and a person who learns about it
/// by pressing the hotkey and getting nothing has been surprised by their own
/// software. Settings → License has carried the countdown since Phase 6, but
/// nobody opens Settings to find out that something is about to break.
///
/// It is `nil` far more often than not, and that is the point — a countdown
/// that is always on screen is a countdown nobody reads on the day it matters.
struct EntitlementNotice: Sendable, Equatable {
    /// Three thresholds, because three windows of very different lengths.
    static let trialWarningDays = 3
    static let annualWarningDays = 14
    /// The ungated window is only three days long, so the trial's own
    /// three-day threshold would put this notice on screen from the first
    /// minute — and this file's whole argument is that a countdown which is
    /// always visible is one nobody reads on the day it matters. The last day
    /// is the only day worth spending it on.
    static let ungatedWarningDays = 1

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
            let seconds = expiresAt.timeIntervalSince(now)
            guard seconds > 0 else { return nil }
            let days = Int((seconds / 86_400).rounded(.up))
            guard days <= Self.ungatedWarningDays else { return nil }

            headline = L10n.string("Your last day before activation")
            detail = L10n.format("The first three days ask for nothing; they end %@. An email address adds ten more days, free, and nothing else changes.", Self.moment.string(from: expiresAt))
            actionTitle = L10n.string("Activate…")
            symbol = "envelope"
            // There is no gentler step before this one — the notice appears on
            // the last day or not at all — so it arrives already pressing.
            isPressing = true

        case let .licensed(license):
            switch license.kind {
            case .trial:
                guard
                    let days = license.daysRemaining(at: now),
                    days <= Self.trialWarningDays,
                    let expiresAt = license.expiresAt
                else { return nil }
                headline = days <= 1
                    ? L10n.string("The trial ends today")
                    : L10n.format("The trial ends in %lld days", Int64(days))
                detail = L10n.format("It runs out on %@. A license keeps this Mac dictating; your dictionary and settings stay exactly as they are either way.", Self.moment.string(from: expiresAt))
                actionTitle = L10n.string("Open License settings")
                symbol = "clock.badge.exclamationmark"
                isPressing = days <= 1

            case .annual:
                guard
                    let days = license.daysRemaining(at: now),
                    days <= Self.annualWarningDays,
                    let expiresAt = license.expiresAt
                else { return nil }
                headline = days <= 1
                    ? L10n.string("Your license ends today")
                    : L10n.format("Your license ends in %lld days", Int64(days))
                detail = L10n.format("It runs out on %@. Renewing before then means dictation never stops; nothing local is touched either way.", Self.moment.string(from: expiresAt))
                actionTitle = L10n.string("Open License settings")
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
