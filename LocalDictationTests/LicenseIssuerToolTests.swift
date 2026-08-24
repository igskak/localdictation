import XCTest
@testable import LocalDictation

/// The issuer and the verifier are two programs that have to agree, and the
/// only way to know they do is to run one against the other.
///
/// `Tools/licensekit.swift` writes the token's JSON by hand — it is the server
/// side, and it will one day *be* a server — so nothing but this test stands
/// between a renamed field and keys that no customer's app accepts. It runs the
/// real tool, with a private key in a throwaway home directory, and reads the
/// result back through the shipping verifier.
final class LicenseIssuerToolTests: XCTestCase {
    private var home: URL!

    private var toolURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LocalDictationTests
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("Tools/licensekit.swift")
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/usr/bin/swift"),
            "no Swift toolchain on this machine"
        )
        try XCTSkipUnless(FileManager.default.fileExists(atPath: toolURL.path), "licensekit.swift not found")
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("licensekit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [toolURL.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        return output
    }

    /// A keypair from the tool, a key from the tool, and the app accepting it.
    func testAKeyFromTheToolVerifiesInTheApp() throws {
        let initOutput = try run(["init"])
        let publicKey = try XCTUnwrap(
            initOutput
                .split(separator: "\n")
                .first { $0.contains("productionPublicKeyBase64") }?
                .split(separator: "\"")
                .dropFirst()
                .first
                .map(String.init),
            "init did not print a public key: \(initOutput)"
        )
        let authority = LicenseAuthority(publicKeyBase64: publicKey)
        XCTAssertTrue(authority.isConfigured)

        let token = try run([
            "issue", "--device", "abcdef0123456789", "--email", "owner@example.com", "--kind", "lifetime"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)

        let license = try LicenseKey.verify(token, authority: authority, deviceID: "abcdef0123456789")

        XCTAssertEqual(license.kind, .lifetime)
        XCTAssertEqual(license.email, "owner@example.com")
        XCTAssertNil(license.expiresAt)
    }

    func testADatedKeyFromTheToolCarriesItsTerm() throws {
        let initOutput = try run(["init"])
        let publicKey = try XCTUnwrap(
            initOutput.split(separator: "\"").dropFirst().first.map(String.init)
        )
        let authority = LicenseAuthority(publicKeyBase64: publicKey)

        let token = try run([
            "issue", "--device", "abcdef0123456789", "--email", "owner@example.com",
            "--kind", "trial", "--days", "14"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)

        let license = try LicenseKey.verify(token, authority: authority, deviceID: "abcdef0123456789")

        XCTAssertEqual(license.kind, .trial)
        let days = try XCTUnwrap(license.daysRemaining(at: Date()))
        XCTAssertEqual(days, 14)
    }

    /// The tool refuses to overwrite a signing key, because doing so would
    /// invalidate every license already sold.
    func testTheToolRefusesToReplaceASigningKey() throws {
        try run(["init"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [toolURL.path, "init"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 1)
    }
}
