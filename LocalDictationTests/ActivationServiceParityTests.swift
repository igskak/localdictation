import XCTest
@testable import Witness

/// The service and the app are two programs that have to agree about bytes.
///
/// `LicenseIssuerToolTests` proves it for `Tools/licensekit.swift`, the issuer
/// that runs by hand. This proves it for `Service/`, the issuer that will run
/// unattended and mail its output to strangers — and it is the one place where
/// a renamed field, a fractional timestamp, or a `null` where an omission
/// belongs fails here rather than in a customer's inbox.
///
/// Two layers, deliberately:
///
/// - `Service/fixtures/parity.json` is committed, and is read on every run
///   including one on a machine with no Node. Nothing about this test is
///   conditional, which is what `docs/PHASE_8.md`'s acceptance criterion —
///   "in a test that runs in CI, for all three kinds" — asks for.
/// - When Node *is* present the fixture is regenerated from the service's own
///   code and compared byte for byte, so a change to the issuer that nobody
///   re-ran the generator for is caught rather than papered over by a stale
///   file that still happens to verify.
final class ActivationServiceParityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Key: Decodable {
            let kind: LicenseKind
            let id: String
            let issued: TimeInterval
            let expires: TimeInterval?
            let token: String
            /// Overrides for a fixture taken from a live service, where each key
            /// names the Mac and the address it was actually issued to. The
            /// committed fixture issues all three for one pair and leaves these
            /// out.
            let device: String?
            let email: String?
        }

        let device: String
        let email: String
        let publicKeyBase64: String
        let keys: [Key]

        func device(for key: Key) -> String { key.device ?? device }
        func email(for key: Key) -> String { key.email ?? email }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LocalDictationTests
            .deletingLastPathComponent()      // repository root
    }

    /// The fixture that ships with the repository and is read on every run.
    private static var committedFixtureURL: URL {
        repositoryRoot.appendingPathComponent("Service/fixtures/parity.json")
    }

    /// A fixture taken from a **running** service, verified as well when it is
    /// there and ignored when it is not.
    ///
    /// This is the check `docs/PHASE_8.md` asks for before the service issues a
    /// key to anyone, and the only one that covers the runtime rather than the
    /// source: everything in `Service/` is tested under Node, production is
    /// workerd, and Ed25519, base64 and JSON are three places those could
    /// differ by a byte. `Service/README.md` has the two commands that produce
    /// it.
    ///
    /// A file rather than an environment variable, because `xcodebuild` does
    /// not pass the shell's environment to the test runner — an override nobody
    /// can drive is an override that silently tests the wrong thing, and this
    /// one did for two runs before it was noticed.
    private static var liveFixtureURL: URL {
        repositoryRoot.appendingPathComponent("Service/fixtures/live.json")
    }

    private func load(_ url: URL) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    /// The committed fixture, which is what most of these assertions are about.
    private func loadFixture() throws -> Fixture {
        try load(Self.committedFixtureURL)
    }

    /// Everything to be verified: the committed fixture, and a live one if a
    /// deployment has been asked for keys. Named so a failure says which.
    private func allFixtures() throws -> [(name: String, fixture: Fixture)] {
        var fixtures = [(name: "committed", fixture: try loadFixture())]
        if FileManager.default.fileExists(atPath: Self.liveFixtureURL.path) {
            fixtures.append((name: "live", fixture: try load(Self.liveFixtureURL)))
        }
        return fixtures
    }

    // MARK: - The keys themselves

    /// One key of each kind, through the verifier that ships.
    func testEveryKindTheServiceIssuesVerifiesInTheApp() throws {
        for (name, fixture) in try allFixtures() {
        let authority = LicenseAuthority(publicKeyBase64: fixture.publicKeyBase64)
        XCTAssertTrue(authority.isConfigured, "\(name) fixture")

        if name == "committed" {
            // The generated fixture covers all three because it is generated.
            XCTAssertEqual(
                Set(fixture.keys.map(\.kind)),
                Set(LicenseKind.allCases),
                "the committed fixture has to cover every kind the service can issue"
            )
        } else {
            // A live one covers whatever the addresses it was taken with
            // actually own, which against a fresh deployment is one trial.
            XCTAssertFalse(fixture.keys.isEmpty, "the \(name) fixture has no keys in it")
        }

        for key in fixture.keys {
            let license = try LicenseKey.verify(key.token, authority: authority, deviceID: fixture.device(for: key))

            XCTAssertEqual(license.kind, key.kind)
            XCTAssertEqual(license.id, key.id)
            XCTAssertEqual(license.email, fixture.email(for: key))
            XCTAssertEqual(license.deviceID, fixture.device(for: key))
            XCTAssertEqual(license.issuedAt.timeIntervalSince1970, key.issued)
            XCTAssertEqual(license.expiresAt?.timeIntervalSince1970, key.expires)
        }
        }
    }

    /// A lifetime key carries no date, and a dated one carries a real date. The
    /// service omits `expires` rather than writing `null`, because the app
    /// refuses a lifetime key that has one.
    func testALifetimeKeyFromTheServiceCarriesNoDate() throws {
        for (_, fixture) in try allFixtures() {
        let authority = LicenseAuthority(publicKeyBase64: fixture.publicKeyBase64)

        for key in fixture.keys {
            let license = try LicenseKey.verify(key.token, authority: authority, deviceID: fixture.device(for: key))
            switch key.kind {
            case .lifetime:
                XCTAssertNil(license.expiresAt)
                XCTAssertFalse(key.token.contains("expires"))
            case .trial, .annual:
                let expiresAt = try XCTUnwrap(license.expiresAt)
                XCTAssertGreaterThan(expiresAt, license.issuedAt)
            }
        }
        }
    }

    /// The timestamps are whole seconds. A fractional value encodes differently
    /// in Swift and in JavaScript, and the signature is over the bytes.
    func testTheTimestampsAreWholeSeconds() throws {
        for (_, fixture) in try allFixtures() {
        for key in fixture.keys {
            XCTAssertEqual(key.issued, key.issued.rounded(.down), "issued is fractional in the \(key.kind.rawValue) key")
            if let expires = key.expires {
                XCTAssertEqual(expires, expires.rounded(.down), "expires is fractional in the \(key.kind.rawValue) key")
            }
        }
        }
    }

    /// The payload the service signs is the frozen one: compact, keys in
    /// lexicographic order, nothing else in it.
    func testThePayloadIsTheFrozenShape() throws {
        for (_, fixture) in try allFixtures() {
        for key in fixture.keys {
            let encoded = key.token.split(separator: ".")[1]
            let data = try XCTUnwrap(Data(base64URLEncoded: String(encoded)))
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))

            XCTAssertFalse(json.contains(" "), "the payload is compact")
            XCTAssertFalse(json.contains("\n"))

            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let expected = key.kind == .lifetime
                ? ["device", "email", "id", "issued", "kind"]
                : ["device", "email", "expires", "id", "issued", "kind"]
            XCTAssertEqual(fields.keys.sorted(), expected)

            // Lexicographic order, read off the bytes rather than off a decoded
            // dictionary — the order is what the signature covers.
            let positions = expected.map { json.range(of: "\"\($0)\":")?.lowerBound }
            XCTAssertEqual(positions.compactMap { $0 }.count, expected.count)
            XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        }
        }
    }

    // MARK: - And what it refuses

    /// A key from the service names one Mac, like every other key.
    func testAServiceKeyIsRefusedOnAnotherMac() throws {
        let fixture = try loadFixture()
        let authority = LicenseAuthority(publicKeyBase64: fixture.publicKeyBase64)
        let key = try XCTUnwrap(fixture.keys.first)

        XCTAssertThrowsError(try LicenseKey.verify(key.token, authority: authority, deviceID: "ffffffffffffffffffffffffffffffff")) { error in
            guard case .wrongDevice = error as? LicenseKeyError else {
                return XCTFail("expected wrongDevice, got \(error)")
            }
        }
    }

    /// Editing the payload of a service key breaks it, the same as editing any
    /// other. Signed with a throwaway seed or with the production one, the check
    /// is the same check.
    func testAnEditedServiceKeyIsRefused() throws {
        let fixture = try loadFixture()
        let authority = LicenseAuthority(publicKeyBase64: fixture.publicKeyBase64)
        let key = try XCTUnwrap(fixture.keys.first { $0.kind == .trial })

        let parts = key.token.split(separator: ".").map(String.init)
        let payload = try XCTUnwrap(Data(base64URLEncoded: parts[1]))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        fields["kind"] = "lifetime"
        fields.removeValue(forKey: "expires")
        let forged = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])

        let token = "\(parts[0]).\(forged.base64URLEncodedString()).\(parts[2])"
        XCTAssertThrowsError(try LicenseKey.verify(token, authority: authority, deviceID: fixture.device(for: key))) { error in
            XCTAssertEqual(error as? LicenseKeyError, .badSignature)
        }
    }

    /// The *committed* fixture is signed by a throwaway seed, so it must not
    /// verify against the authority the shipped app carries — one that did would
    /// mean a private key had reached this repository. A live fixture is exempt
    /// by definition: keys from the real service are signed by the real key, and
    /// that they verify against `.production` is the whole point of taking one.
    func testTheFixtureIsNotSignedByTheProductionAuthority() throws {
        let fixture = try loadFixture()
        XCTAssertNotEqual(fixture.publicKeyBase64, LicenseAuthority.productionPublicKeyBase64)

        for key in fixture.keys {
            XCTAssertThrowsError(try LicenseKey.verify(key.token, authority: .production, deviceID: fixture.device(for: key)))
        }
    }

    // MARK: - Drift

    /// Regenerates the fixture from the service's own code and compares it byte
    /// for byte. Skipped where Node is not installed; the assertions above are
    /// not, which is why the fixture is committed.
    func testTheCommittedFixtureIsWhatTheServiceProducesToday() throws {
        guard let node = Self.nodeExecutable() else { throw XCTSkip("no Node on this machine") }

        let generator = Self.repositoryRoot.appendingPathComponent("Service/tools/parity-fixture.mjs")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: generator.path), "the generator is missing")

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = node
        process.arguments = [generator.path, "--out", output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let log = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, log)

        let regenerated = try Data(contentsOf: output)
        let committed = try Data(contentsOf: Self.committedFixtureURL)
        XCTAssertEqual(
            regenerated,
            committed,
            "Service/fixtures/parity.json is stale. Run `npm run fixture` in Service/ and commit the result."
        )
    }

    /// Node is not on a fixed path, and `xcodebuild`'s environment is not a
    /// login shell's, so `PATH` alone is not enough to find it.
    private static func nodeExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let search = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in search.split(separator: ":") {
            let candidate = "\(directory)/node"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
