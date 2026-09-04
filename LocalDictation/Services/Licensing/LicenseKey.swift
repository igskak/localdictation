import CryptoKit
import Foundation

/// Why a key was not accepted. Each case is something the user can act on, and
/// none of them is "contact support".
enum LicenseKeyError: Error, Sendable, Equatable {
    case malformed
    case unsupportedVersion(String)
    case noAuthority
    case badSignature
    case wrongDevice(issuedFor: String)
    case inconsistentDates

    var message: String {
        switch self {
        case .malformed:
            "That does not look like a license key. Copy the whole line from the activation email, including the LD1 at the front."
        case let .unsupportedVersion(version):
            "This key is version \(version), which this build does not know how to read. Update Witness."
        case .noAuthority:
            "This build carries no license authority key, so it cannot check any license. It is a development build."
        case .badSignature:
            "This key did not verify. It may have been edited in transit — paste it again straight from the email."
        case .wrongDevice:
            "This key was issued for a different Mac. Each Mac gets its own key, and a license covers two."
        case .inconsistentDates:
            "This key's dates do not make sense, which means it was not issued by us."
        }
    }
}

/// The wire form of a license.
///
/// `LD1.<base64url payload>.<base64url signature>` — one line, pasteable, and
/// self-describing enough that a user looking at it can tell it is ours.
///
/// The signature covers the payload bytes *as they appear in the token*, not a
/// re-encoding of the decoded fields. Re-serializing before verifying is how
/// signature checks get quietly defeated by a JSON library that orders keys
/// differently than the issuer did.
enum LicenseKey {
    static let prefix = "LD1"

    private struct Payload: Codable {
        let id: String
        let email: String
        let kind: LicenseKind
        let device: String
        let issued: TimeInterval
        let expires: TimeInterval?
    }

    /// Verifies a pasted key against the authority and this Mac.
    ///
    /// Order matters: the signature is checked before anything in the payload
    /// is believed, including the device it names.
    static func verify(
        _ token: String,
        authority: LicenseAuthority,
        deviceID: String
    ) throws -> License {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[1].isEmpty, !parts[2].isEmpty else { throw LicenseKeyError.malformed }
        guard parts[0] == prefix else { throw LicenseKeyError.unsupportedVersion(String(parts[0])) }

        guard
            let payloadData = Data(base64URLEncoded: String(parts[1])),
            let signature = Data(base64URLEncoded: String(parts[2]))
        else { throw LicenseKeyError.malformed }

        guard let publicKey = authority.publicKey else { throw LicenseKeyError.noAuthority }
        guard publicKey.isValidSignature(signature, for: payloadData) else { throw LicenseKeyError.badSignature }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            throw LicenseKeyError.malformed
        }

        let issuedAt = Date(timeIntervalSince1970: payload.issued)
        let expiresAt = payload.expires.map(Date.init(timeIntervalSince1970:))
        guard payload.kind.isDated == (expiresAt != nil) else { throw LicenseKeyError.inconsistentDates }
        if let expiresAt, expiresAt <= issuedAt { throw LicenseKeyError.inconsistentDates }

        guard payload.device == deviceID else { throw LicenseKeyError.wrongDevice(issuedFor: payload.device) }

        return License(
            id: payload.id,
            email: payload.email,
            kind: payload.kind,
            deviceID: payload.device,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    /// Issues a key. Present in the app target because the tests that prove
    /// verification works have to be able to produce a valid key, and a test
    /// that reimplements the format proves the reimplementation instead.
    ///
    /// The private key exists only where keys are issued. Nothing in the
    /// shipped app ever holds one — see `Tools/licensekit.swift`.
    static func issue(
        id: String,
        email: String,
        kind: LicenseKind,
        deviceID: String,
        issuedAt: Date,
        expiresAt: Date?,
        signingKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        // Whole seconds. `docs/PHASE_8.md` freezes the payload that way because
        // the signature is over the bytes and a fractional value encodes
        // differently in Swift and in JavaScript. The *reader* above stays
        // liberal — a key issued before this rule existed still verifies — but
        // nothing in this repository signs one any more.
        let payload = Payload(
            id: id,
            email: email,
            kind: kind,
            device: deviceID,
            issued: issuedAt.timeIntervalSince1970.rounded(.down),
            expires: expiresAt?.timeIntervalSince1970.rounded(.down)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let signature = try signingKey.signature(for: data)
        return "\(prefix).\(data.base64URLEncodedString()).\(signature.base64URLEncodedString())"
    }
}

/// The public half of the issuing key, compiled into the app.
///
/// A license is checked here and nowhere else — there is no call home, so a
/// paid app keeps working on a plane, at a customer site, and after this
/// project's servers are gone. The cost is stated rather than hidden: a key
/// that has been refunded or leaked cannot be revoked remotely. For a
/// one-machine-at-a-time desktop utility sold to individuals that is the right
/// side of the trade, and it is the side that keeps the local-first promise.
struct LicenseAuthority: Sendable {
    /// Base64 (standard, not URL) of the 32-byte Ed25519 public key.
    ///
    /// Public by definition — it can only check signatures, never make them —
    /// so it belongs in the repository. Its private half was generated by
    /// `swift Tools/licensekit.swift init` and lives outside this repository,
    /// in `~/.localdictation/license-signing-key`.
    ///
    /// Replacing this value invalidates every key ever issued against the old
    /// one, so it changes exactly once more, if ever: when the signing key
    /// moves to whatever ends up issuing licenses for customers.
    static let productionPublicKeyBase64 = "enDKT/48nxi+u3x4Qv1qJCDXx5YFe7WVlW5r77IIsJM="

    let publicKey: Curve25519.Signing.PublicKey?

    init(publicKeyBase64: String) {
        guard
            let raw = Data(base64Encoded: publicKeyBase64),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else {
            self.publicKey = nil
            return
        }
        self.publicKey = key
    }

    init(publicKey: Curve25519.Signing.PublicKey?) {
        self.publicKey = publicKey
    }

    static let production = LicenseAuthority(publicKeyBase64: productionPublicKeyBase64)

    var isConfigured: Bool { publicKey != nil }
}

extension Data {
    /// Base64url without padding — the form that survives being pasted into an
    /// email, a chat message, and a URL without acquiring a line break.
    init?(base64URLEncoded string: String) {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        guard let data = Data(base64Encoded: value) else { return nil }
        self = data
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
