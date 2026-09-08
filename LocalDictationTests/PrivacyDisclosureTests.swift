import XCTest
@testable import Witness

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

        for field in ActivationRequestBody.allowedFields
            + DeviceReleaseRequestBody.allowedFields
            + TelemetryEventBody.allowedFields {
            XCTAssertTrue(text.contains(field), "docs/PRIVACY.md does not mention the '\(field)' field")
        }
    }

    /// Three events are sent and seven are not, and the document has to name
    /// the three by the names that go on the wire.
    ///
    /// This replaces the assertion that nothing was transmitted at all.
    /// `docs/PHASE_8_DECISIONS.md` D7 decided that, `docs/REFINEMENTS.md`
    /// records reversing it, and the property worth holding now is not "none"
    /// but "these, and a reader can check which".
    func testTheDocumentNamesEveryEventThatIsTransmitted() throws {
        let text = try policy()

        XCTAssertEqual(TelemetryEvent.transmitted.count, 3)
        for name in TelemetryEvent.transmitted {
            XCTAssertTrue(text.contains(name), "docs/PRIVACY.md does not name the '\(name)' event")
        }

        // The other seven have to stay off the wire, and the document says so.
        let silent: [TelemetryEvent] = [
            .installed,
            .activationSucceeded,
            .activationFailed(.unreachable),
            .licenseAccepted(.annual),
            .licenseRejected(.badSignature),
            .checkoutOpened(.lifetime),
            .entitlementLapsed(.trial)
        ]
        for event in silent {
            XCTAssertFalse(event.isTransmitted, "\(event.name) is transmitted and was not meant to be")
        }
    }

    /// The event body in the document, parsed rather than eyeballed — the same
    /// arrangement the activation request has, and for the same reason.
    func testTheDocumentedEventIsTheEventTheAppSends() throws {
        let text = try policy()

        let fences = text.ranges(of: try Regex("```json[\\s\\S]*?```"))
        XCTAssertEqual(fences.count, 2, "docs/PRIVACY.md no longer shows both bodies")

        let json = text[fences[1]]
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
            "the documented event body is not the object the app sends"
        )

        // The example carries no qualifier — `trial_started` has none — so it is
        // the four required fields, and the fifth is described in prose beside it.
        XCTAssertEqual(fields.keys.sorted(), TelemetryEventBody.allowedFields.filter { $0 != "qualifier" })
        XCTAssertTrue(text.contains("qualifier"))
    }

    /// The two field lists cannot drift apart: the envelope is what the app
    /// builds, the body is what it encodes, and a field in one and not the
    /// other is a field that is either lost or undisclosed.
    func testTheWireBodyAndTheEnvelopeAgreeOnTheFieldList() {
        XCTAssertEqual(Set(TelemetryEventBody.allowedFields), Set(TelemetryEnvelope.allowedFields))
    }

    /// Events go to the same host as everything else, over `https`, and the
    /// document names it.
    func testTheDocumentedEventDestinationIsWhereTheAppSends() throws {
        let endpoint = try XCTUnwrap(TelemetryEndpoint.production)
        XCTAssertEqual(endpoint.scheme, "https")

        let host = try XCTUnwrap(endpoint.host)
        XCTAssertTrue(
            try policy().contains(host),
            "docs/PRIVACY.md does not name the host product events go to: \(host)"
        )
    }

    /// The service is live now, so what this asserts is the property the document
    /// actually claims: the request goes to one place, over `https`, and it is
    /// the place named in the policy.
    ///
    /// "Only when you press something" is not assertable from here — it is a
    /// property of the call sites, and `EntitlementServiceTests` covers it. What
    /// is assertable is that there is exactly one destination and the document
    /// knows its host.
    func testTheDocumentedActivationGoesWhereTheDocumentSays() throws {
        let endpoint = try XCTUnwrap(ActivationEndpoint.production)
        XCTAssertEqual(endpoint.scheme, "https")

        let host = try XCTUnwrap(endpoint.host)
        XCTAssertTrue(
            try policy().contains(host),
            "docs/PRIVACY.md does not name the host the app actually sends to: \(host)"
        )
    }
}
