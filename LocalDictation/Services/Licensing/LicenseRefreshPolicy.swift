import Foundation

/// When the app quietly asks the activation service for a fresh key.
///
/// An annual licence is a subscription, and the key it puts on a Mac lives
/// thirty days: a refund or a cancellation stops the *next* key, and the one
/// already here runs out within a month, which is as fast as an offline check
/// can be recalled. The price of that is this policy — in the last week of its
/// life the app asks for a replacement, by itself, with the address the key was
/// issued to and this Mac's identifier, the two fields the activation request
/// has always had.
///
/// **These numbers and `KEY_SECONDS` / `REFRESH_WINDOW_SECONDS` in
/// `Service/src/subscription.js` are one decision in two languages**, the way
/// `EntitlementPolicy.trialDuration` is: the service puts the date in the key,
/// and this side decides when to ask again. Asking earlier than the service's
/// window is harmless — it returns the same key, byte for byte — so the app's
/// window is allowed to be wider than the service's, never narrower.
///
/// Pure, so every rule is a test with two dates.
enum LicenseRefreshPolicy {
    /// How far ahead of the key's end the app starts asking.
    static let window: TimeInterval = 7 * 86_400

    /// How often it asks while the key is still good. Once an hour is far more
    /// than the week needs and far less than a loop.
    static let retryInterval: TimeInterval = 3_600

    /// How often it asks once the key has already run out. Somebody who has just
    /// fixed a declined card is waiting for dictation to come back, so this is
    /// short — and still bounded, because the service rate-limits by address.
    static let expiredRetryInterval: TimeInterval = 300

    /// Whether a refresh should be attempted now.
    ///
    /// Only annual keys are refreshed. A trial key is not a subscription, and a
    /// lifetime key never ends. `lastAttempt` is in memory only: after a
    /// relaunch the first check goes through at once, which is what a Mac that
    /// slept through the whole window needs.
    static func isDue(license: License?, now: Date, lastAttempt: Date?) -> Bool {
        guard let license, license.kind == .annual, let expiresAt = license.expiresAt else { return false }
        guard expiresAt.timeIntervalSince(now) <= window else { return false }

        let interval = now >= expiresAt ? expiredRetryInterval : retryInterval
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return false }
        return true
    }

    /// Whether `fresh` is worth keeping over `current`. A key that is not later
    /// than the one already held is the service answering "nothing has changed",
    /// and storing it would only rewrite the file.
    static func isImprovement(_ fresh: License, over current: License) -> Bool {
        guard fresh.kind == current.kind, fresh.deviceID == current.deviceID else { return true }
        switch (fresh.expiresAt, current.expiresAt) {
        case let (new?, old?): return new > old
        case (nil, _?): return true
        default: return false
        }
    }
}
