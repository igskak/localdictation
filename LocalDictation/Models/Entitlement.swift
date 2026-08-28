import Foundation

/// What a license lets its owner do, and for how long.
///
/// The trial is a license kind rather than a local flag, because a flag on disk
/// is a flag the app has to trust. Every kind below arrives as the same signed
/// token and is checked the same way; the only difference between a trial and a
/// lifetime purchase is what the issuer wrote in the payload.
enum LicenseKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Issued when the user gives an email. Full function, dated.
    case trial
    /// EUR 49 a year. Dated.
    case annual
    /// EUR 99 once. Never expires.
    case lifetime

    var displayName: String {
        switch self {
        case .trial: "Trial"
        case .annual: "Annual"
        case .lifetime: "Lifetime"
        }
    }

    /// Whether an expiry date is expected in the payload. A lifetime key that
    /// carries one, or a dated key that does not, is malformed rather than
    /// generously interpreted.
    var isDated: Bool { self != .lifetime }
}

/// A verified license. Constructing one means a signature has already been
/// checked against the embedded authority key — there is no other way in.
struct License: Sendable, Equatable {
    let id: String
    /// The address the key was issued to. Shown so the user can see which of
    /// their addresses this Mac is licensed under; never sent anywhere by the
    /// app that stores it.
    let email: String
    let kind: LicenseKind
    /// The Mac this key was issued for. The two-device limit is counted by the
    /// issuer; this field is what makes the count mean anything on this side.
    let deviceID: String
    let issuedAt: Date
    /// `nil` only for `.lifetime`.
    let expiresAt: Date?

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    func daysRemaining(at now: Date) -> Int? {
        guard let expiresAt else { return nil }
        let seconds = expiresAt.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return Int((seconds / 86_400).rounded(.up))
    }
}

/// Why dictation is refused. Every case is recoverable by an action the user
/// can take, and every case names it.
enum EntitlementLock: Sendable, Equatable {
    /// The ungated window closed and no key has been entered.
    case activationRequired
    /// A dated license reached its date.
    case expired(LicenseKind, at: Date)
    /// A lifetime license, on a major version it did not buy.
    ///
    /// `docs/PHASE_8_DECISIONS.md` D6 sold "lifetime" as the purchased major
    /// version and every minor update to it, so this is the one refusal in the
    /// product that is not about time. It carries both numbers because the
    /// sentence the user needs names both: what they own, and what they are
    /// running.
    case updateRequired(coveredMajor: Int, runningMajor: Int)
}

/// How much of the ungated window is left.
///
/// Two numbers rather than one because the window closes on whichever runs out
/// first, and a countdown that shows only the slower of the two is a countdown
/// that surprises people.
struct GraceStanding: Sendable, Equatable {
    let dictationsRemaining: Int
    /// `nil` until the first successful dictation starts the clock.
    let expiresAt: Date?

    static let untouched = GraceStanding(dictationsRemaining: EntitlementPolicy.ungatedDictations, expiresAt: nil)
}

/// The single answer to "may this Mac dictate, and what should it be told".
enum EntitlementState: Sendable, Equatable {
    /// Before any key: the app is fully usable and has asked for nothing.
    case ungated(GraceStanding)
    case licensed(License)
    case locked(EntitlementLock)

    var allowsDictation: Bool {
        switch self {
        case .ungated, .licensed: true
        case .locked: false
        }
    }

    var lock: EntitlementLock? {
        if case let .locked(lock) = self { return lock }
        return nil
    }

    var license: License? {
        if case let .licensed(license) = self { return license }
        return nil
    }

    /// Whether the user is being asked to pay rather than to activate. Drives
    /// which offer the paywall leads with.
    var wantsPurchase: Bool {
        switch self {
        case let .locked(.expired(kind, _)): kind != .lifetime
        case .locked(.updateRequired): true
        case .locked(.activationRequired): false
        case let .licensed(license): license.kind == .trial
        case .ungated: false
        }
    }
}
