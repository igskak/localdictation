import CryptoKit
import XCTest
@testable import LocalDictation

/// A license is a signature, and this file is where that claim is checked.
///
/// Every test issues a real key with a real private key and reads it back
/// through the shipping verifier, so a change to the format that breaks
/// yesterday's keys fails here rather than in a customer's inbox.
final class LicenseKeyTests: XCTestCase {
    private let device = "test-device-0001"
    private let issued = Date(timeIntervalSince1970: 1_700_000_000)

    func testAKeyRoundTrips() throws {
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let token = try TestLicenseIssuer.issue(kind: .lifetime, expiresAt: nil, signingKey: signingKey)

        let license = try LicenseKey.verify(token, authority: authority, deviceID: device)

        XCTAssertEqual(license.kind, .lifetime)
        XCTAssertEqual(license.email, "owner@example.com")
        XCTAssertEqual(license.deviceID, device)
        XCTAssertNil(license.expiresAt)
    }

    func testADatedKeyCarriesItsDate() throws {
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let expiry = issued.addingTimeInterval(365 * 86_400)
        let token = try TestLicenseIssuer.issue(
            kind: .annual,
            issuedAt: issued,
            expiresAt: expiry,
            signingKey: signingKey
        )

        let license = try LicenseKey.verify(token, authority: authority, deviceID: device)

        XCTAssertEqual(license.expiresAt?.timeIntervalSince1970 ?? 0, expiry.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(license.daysRemaining(at: expiry.addingTimeInterval(-86_400)), 1)
    }

    /// The point of the whole design: a payload someone edited does not verify,
    /// whatever they edited it to say.
    func testAnEditedPayloadIsRefused() throws {
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let token = try TestLicenseIssuer.issue(kind: .trial, expiresAt: issued.addingTimeInterval(86_400), signingKey: signingKey)

        var parts = token.split(separator: ".").map(String.init)
        var payload = try XCTUnwrap(Data(base64URLEncoded: parts[1]))
        var json = try XCTUnwrap(String(data: payload, encoding: .utf8))
        json = json.replacingOccurrences(of: "\"trial\"", with: "\"lifetime\"")
        payload = Data(json.utf8)
        parts[1] = payload.base64URLEncodedString()

        XCTAssertThrowsError(try LicenseKey.verify(parts.joined(separator: "."), authority: authority, deviceID: device)) {
            XCTAssertEqual($0 as? LicenseKeyError, .badSignature)
        }
    }

    func testAKeyFromAnotherAuthorityIsRefused() throws {
        let (_, foreignKey) = TestLicenseIssuer.makeAuthority()
        let (authority, _) = TestLicenseIssuer.makeAuthority()
        let token = try TestLicenseIssuer.issue(kind: .lifetime, expiresAt: nil, signingKey: foreignKey)

        XCTAssertThrowsError(try LicenseKey.verify(token, authority: authority, deviceID: device)) {
            XCTAssertEqual($0 as? LicenseKeyError, .badSignature)
        }
    }

    /// The two-Mac limit means something only because a key names its Mac.
    func testAKeyForAnotherMacIsRefusedAndSaysSo() throws {
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let token = try TestLicenseIssuer.issue(
            kind: .lifetime,
            deviceID: "some-other-mac",
            expiresAt: nil,
            signingKey: signingKey
        )

        XCTAssertThrowsError(try LicenseKey.verify(token, authority: authority, deviceID: device)) {
            XCTAssertEqual($0 as? LicenseKeyError, .wrongDevice(issuedFor: "some-other-mac"))
        }
    }

    /// A build with no authority key cannot accept a license — including one
    /// that is perfectly valid. This is why a development build is honest about
    /// being one instead of quietly licensing itself.
    func testABuildWithoutAnAuthorityAcceptsNothing() throws {
        let (_, signingKey) = TestLicenseIssuer.makeAuthority()
        let token = try TestLicenseIssuer.issue(kind: .lifetime, expiresAt: nil, signingKey: signingKey)

        XCTAssertThrowsError(
            try LicenseKey.verify(token, authority: LicenseAuthority(publicKeyBase64: ""), deviceID: device)
        ) {
            XCTAssertEqual($0 as? LicenseKeyError, .noAuthority)
        }
    }

    func testGarbageIsRefusedBeforeAnythingElseHappens() {
        let (authority, _) = TestLicenseIssuer.makeAuthority()

        for junk in ["", "hello", "LD1.", "LD1.only-two", "LD1..", "....."] {
            XCTAssertThrowsError(try LicenseKey.verify(junk, authority: authority, deviceID: device), junk)
        }
    }

    func testAKeyFromALaterVersionSaysToUpdate() {
        let (authority, _) = TestLicenseIssuer.makeAuthority()

        XCTAssertThrowsError(try LicenseKey.verify("LD9.aaaa.bbbb", authority: authority, deviceID: device)) {
            XCTAssertEqual($0 as? LicenseKeyError, .unsupportedVersion("LD9"))
        }
    }

    /// A lifetime key with an expiry, or a dated key without one, was not
    /// issued by anything of ours — so it is refused rather than interpreted
    /// generously in the user's favour or ours.
    func testInconsistentDatesAreRefused() throws {
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let dated = try TestLicenseIssuer.issue(
            kind: .lifetime,
            expiresAt: issued.addingTimeInterval(86_400),
            signingKey: signingKey
        )
        let undated = try TestLicenseIssuer.issue(kind: .annual, expiresAt: nil, signingKey: signingKey)

        for token in [dated, undated] {
            XCTAssertThrowsError(try LicenseKey.verify(token, authority: authority, deviceID: device)) {
                XCTAssertEqual($0 as? LicenseKeyError, .inconsistentDates)
            }
        }
    }

    /// Keys travel through email and chat windows, which add whitespace.
    func testSurroundingWhitespaceIsNotTheUsersProblem() throws {
        let (authority, signingKey) = TestLicenseIssuer.makeAuthority()
        let token = try TestLicenseIssuer.issue(kind: .lifetime, expiresAt: nil, signingKey: signingKey)

        XCTAssertNoThrow(try LicenseKey.verify("  \n\(token)\n ", authority: authority, deviceID: device))
    }

    /// The device hash is stable, opaque, and not the hardware UUID.
    func testTheDeviceIdentifierHidesTheHardwareUUID() {
        let uuid = "6B5F8C21-6F2E-4C63-9E2B-6C1C0A2D77AA"
        let first = HardwareDeviceIdentity(platformUUID: uuid).deviceID
        let second = HardwareDeviceIdentity(platformUUID: uuid).deviceID

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertFalse(first.uppercased().contains(uuid))
        XCTAssertNotEqual(first, HardwareDeviceIdentity(platformUUID: uuid + "!").deviceID)
    }
}
