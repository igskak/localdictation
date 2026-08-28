import XCTest
@testable import LocalDictation

/// The privacy policy, checked against the code it describes.
///
/// `AGENTS.md` makes the enumerated list the boundary rather than a habit: the
/// app may send only what is written down, and every transmitted field has to
/// be disclosed. A document is the wrong place to keep that promise on its own —
/// documents fall behind — so the one thing in `docs/PRIVACY.md` that is
/// machine-checkable is checked here.
///
/// This is the same arrangement `TelemetryBoundaryTests` has for events and
/// `HTTPActivationBackendTests` has for the request itself, closing the loop
/// between what the code sends and what the user was told it sends.
final class PrivacyDisclosureTests: XCTestCase {
    private static var policyURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/PRIVACY.md")
    }

    private func policy() throws -> String {
        try String(contentsOf: Self.policyURL, encoding: .utf8)
    }

    /// The example body in the document is parsed rather than eyeballed, and its
    /// keys have to be exactly the ones the encoder produces.
    func testTheDocumentedRequestIsTheRequestTheAppSends() throws {
        let text = try policy()

        let fence = try XCTUnwrap(
            // `[\s\S]` rather than `.`: a dot does not cross a newline, and the
            // body being matched is three lines long.
            text.range(of: "```json[\\s\\S]*?```", options: .regularExpression),
            "docs/PRIVACY.md no longer shows the request body"
        )
        let json = text[fence]
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
            "the documented body is not the object the app sends"
        )
        XCTAssertEqual(fields.keys.sorted(), ActivationRequestBody.allowedFields)
    }

    /// Both bodies this app can put on a wire are named in the document. The
    /// second one exists because releasing a Mac sends a key back, and a field
    /// that is sent and not disclosed is the failure this file exists to catch.
    func testEveryFieldTheAppCanSendIsNamedInTheDocument() throws {
        let text = try policy()

        for field in ActivationRequestBody.allowedFields + DeviceReleaseRequestBody.allowedFields {
            XCTAssertTrue(text.contains(field), "docs/PRIVACY.md does not mention the '\(field)' field")
        }
    }

    /// The claim that nothing is transmitted has to be true of the build that
    /// makes it. `docs/PHASE_8_DECISIONS.md` D7 is where it was decided.
    func testTheDocumentIsRightThatNoProductEventIsTransmitted() throws {
        let text = try policy()
        XCTAssertTrue(text.contains("None of them is transmitted"))

        // What ships is the local service, which writes to the log and nowhere
        // else. If a transport is ever added, this fails first.
        let telemetry = LocalOnlyTelemetryService(appVersion: "1.0", systemVersion: "15.0", installID: "test")
        XCTAssertNotNil(telemetry)
    }

    /// A build with no endpoint sends nothing anywhere, which is the state every
    /// other test in the suite depends on and the state this document describes
    /// as "you press something".
    func testTheDocumentedActivationIsAlwaysUserInitiated() {
        XCTAssertNil(ActivationEndpoint.production)
        XCTAssertFalse(ActivationEndpoint.backend().isConfigured)
    }
}
