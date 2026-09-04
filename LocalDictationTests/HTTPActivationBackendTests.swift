import XCTest
@testable import LocalDictation

/// The one request this app makes on its own behalf.
///
/// Two things are being pinned here. The first is that every answer a service
/// can give turns into a sentence the user can act on rather than a status
/// code. The second is the request itself: two fields, no version in the user
/// agent, and a test that fails if a third field is ever added — the same
/// arrangement `TelemetryBoundaryTests` has for events.
final class HTTPActivationBackendTests: XCTestCase {
    private let endpoint = URL(string: "https://activation.example.com/v1/activate")!
    private let device = "0123456789abcdef0123456789abcdef"
    private let email = "someone@example.com"

    override func tearDown() {
        StubActivationProtocol.reset()
        super.tearDown()
    }

    private func makeBackend() -> HTTPActivationBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubActivationProtocol.self]
        return HTTPActivationBackend(endpoint: endpoint, session: URLSession(configuration: configuration))
    }

    private func requestKey() async -> Result<String, ActivationError> {
        do {
            return .success(try await makeBackend().requestKey(email: email, deviceID: device))
        } catch let error as ActivationError {
            return .failure(error)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    private func failure() async -> ActivationError? {
        if case let .failure(error) = await requestKey() { return error }
        return nil
    }

    // MARK: - The request

    /// The privacy boundary, as an assertion. A third field here is a change to
    /// the privacy policy, and this test is where someone finds that out.
    func testTheRequestCarriesTheEmailTheDeviceAndNothingElse() throws {
        let body = try HTTPActivationBackend.body(email: email, deviceID: device)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])

        XCTAssertEqual(fields.keys.sorted(), ActivationRequestBody.allowedFields)
        XCTAssertEqual(fields["email"], email)
        XCTAssertEqual(fields["device"], device)
    }

    func testTheUserAgentCarriesNoVersion() async throws {
        StubActivationProtocol.respond(status: 200, json: ["key": validKey])
        _ = await requestKey()

        let request = try XCTUnwrap(StubActivationProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LocalDictation")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testTheBodyOnTheWireIsTheBodyTheEncoderBuilt() async throws {
        StubActivationProtocol.respond(status: 200, json: ["key": validKey])
        _ = await requestKey()

        let sent = try XCTUnwrap(StubActivationProtocol.lastBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: String])
        XCTAssertEqual(fields.keys.sorted(), ActivationRequestBody.allowedFields)
    }

    // MARK: - Answers

    func testAKeyComesBack() async {
        StubActivationProtocol.respond(status: 200, json: ["key": validKey])
        guard case let .success(key) = await requestKey() else { return XCTFail("expected a key") }
        XCTAssertEqual(key, validKey)
    }

    func testSurroundingWhitespaceOnTheKeyIsTrimmed() async {
        StubActivationProtocol.respond(status: 200, json: ["key": "\n \(validKey) \n"])
        guard case let .success(key) = await requestKey() else { return XCTFail("expected a key") }
        XCTAssertEqual(key, validKey)
    }

    /// A captive portal, a proxy error page, or a service that answered 200 by
    /// accident. None of them may be stored as a license.
    func testASuccessWithoutAKeyIsRefused() async {
        StubActivationProtocol.respond(status: 200, body: Data("<html>hello</html>".utf8))
        guard case let .rejected(message)? = await failure() else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("without a key"))
    }

    func testSomethingThatIsNotOneOfOurKeysIsRefused() async {
        StubActivationProtocol.respond(status: 200, json: ["key": "not-a-license"])
        guard case .rejected? = await failure() else { return XCTFail("expected a refusal") }
    }

    func testTheDeviceLimitIsItsOwnAnswer() async {
        StubActivationProtocol.respond(status: 409, json: ["error": "device_limit"])
        let error = await failure()
        XCTAssertEqual(error, .deviceLimitReached)
    }

    func testARefusedAddressIsItsOwnAnswer() async {
        StubActivationProtocol.respond(status: 400, json: ["error": "invalid_email"])
        let error = await failure()
        XCTAssertEqual(error, .invalidEmail)
    }

    /// A service that says something useful gets to say it — bounded.
    func testTheServiceMayExplainItself() async {
        StubActivationProtocol.respond(status: 422, json: [
            "error": "already_issued",
            "message": "A key for this Mac was mailed to you an hour ago."
        ])
        let error = await failure()
        XCTAssertEqual(error, .rejected("A key for this Mac was mailed to you an hour ago."))
    }

    func testAnUnexplainedRefusalStillNamesTheOtherWayIn() async {
        StubActivationProtocol.respond(status: 403, json: ["error": "nope"])
        guard case let .rejected(message)? = await failure() else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("Paste a key"))
    }

    /// Both of these leave the user exactly where they were, so both are told
    /// to come back rather than told they were refused.
    func testAServerErrorReadsAsTemporary() async {
        StubActivationProtocol.respond(status: 503, json: ["error": "down"])
        guard case .unreachable? = await failure() else { return XCTFail("expected unreachable") }
    }

    func testARateLimitReadsAsTemporary() async {
        StubActivationProtocol.respond(status: 429, body: Data())
        guard case .unreachable? = await failure() else { return XCTFail("expected unreachable") }
    }

    func testATransportFailureNamesTheProblemAndNotTheUser() async {
        StubActivationProtocol.fail(with: URLError(.notConnectedToInternet))
        guard case let .unreachable(detail)? = await failure() else { return XCTFail("expected unreachable") }
        XCTAssertFalse(detail.isEmpty)
    }

    func testAnEnormousReplyIsNotReadAsALicense() async {
        let padding = String(repeating: "a", count: HTTPActivationBackend.maximumResponseBytes + 1)
        StubActivationProtocol.respond(status: 200, json: ["key": validKey, "note": padding])
        guard case let .rejected(message)? = await failure() else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("too large"))
    }

    // MARK: - Giving a Mac back

    /// One service, one constant. The release endpoint is a sibling of the
    /// activation one so the two cannot end up pointing at different
    /// deployments.
    func testTheReleaseEndpointIsASiblingOfTheActivationOne() {
        XCTAssertEqual(
            HTTPActivationBackend.siblingRelease(of: endpoint).absoluteString,
            "https://activation.example.com/v1/devices/release"
        )
    }

    /// Two fields again, and the key is one this service issued going back to
    /// the service that issued it.
    func testTheReleaseRequestCarriesTheKeyTheDeviceAndNothingElse() async throws {
        StubActivationProtocol.respond(status: 200, json: ["released": "true"])
        try await makeBackend().releaseDevice(key: validKey, deviceID: device)

        let request = try XCTUnwrap(StubActivationProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/devices/release")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LocalDictation")

        let sent = try XCTUnwrap(StubActivationProtocol.lastBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: String])
        XCTAssertEqual(fields.keys.sorted(), DeviceReleaseRequestBody.allowedFields)
        XCTAssertEqual(fields["key"], validKey)
        XCTAssertEqual(fields["device"], device)
    }

    func testAReleaseThatWasRefusedSaysWhy() async {
        StubActivationProtocol.respond(status: 403, json: [
            "error": "device_mismatch",
            "message": "That key was issued for a different Mac, so nothing was released."
        ])
        do {
            try await makeBackend().releaseDevice(key: validKey, deviceID: device)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? ActivationError, .rejected("That key was issued for a different Mac, so nothing was released."))
        }
    }

    func testAReleaseAgainstAServiceHavingABadDayIsTemporary() async {
        StubActivationProtocol.respond(status: 503, body: Data())
        do {
            try await makeBackend().releaseDevice(key: validKey, deviceID: device)
            XCTFail("expected a refusal")
        } catch {
            guard case .unreachable? = error as? ActivationError else { return XCTFail("expected unreachable") }
        }
    }

    // MARK: - Configuration

    /// An email address and a device identifier over cleartext is the thing
    /// this product promises not to do. A misconfigured build looks unfinished
    /// rather than working.
    func testAPlainHTTPEndpointIsNotConfigured() async {
        let backend = HTTPActivationBackend(endpoint: URL(string: "http://activation.example.com/v1")!)
        XCTAssertFalse(backend.isConfigured)

        do {
            _ = try await backend.requestKey(email: email, deviceID: device)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? ActivationError, .notConfigured)
        }

        do {
            try await backend.releaseDevice(key: validKey, deviceID: device)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? ActivationError, .notConfigured)
        }
    }

    /// The service is deployed, so this now asserts the opposite of what it did:
    /// the shipping build points at something, over `https`, and the release
    /// endpoint it derives is a sibling of it.
    ///
    /// The scheme is the assertion that matters. `HTTPActivationBackend` reports
    /// itself unconfigured for plain HTTP rather than sending an address in
    /// cleartext, so a URL edited to `http` here would not leak anything — it
    /// would silently turn activation off for everyone. Both failures are worth
    /// catching and only one of them is obvious.
    func testTheShippingBuildPointsAtTheService() throws {
        let endpoint = try XCTUnwrap(ActivationEndpoint.production)
        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.path, "/v1/activate")
        XCTAssertTrue(ActivationEndpoint.backend().isConfigured)

        XCTAssertEqual(
            HTTPActivationBackend.siblingRelease(of: endpoint).path,
            "/v1/devices/release"
        )
    }

    // MARK: - Server text

    func testAServiceMessageIsOneLineAndBounded() {
        XCTAssertEqual(ServerMessage.sanitized("  hello  "), "hello")
        XCTAssertEqual(ServerMessage.sanitized("first\nsecond"), "first")
        XCTAssertNil(ServerMessage.sanitized("   "))
        XCTAssertNil(ServerMessage.sanitized(nil))

        let long = String(repeating: "x", count: ServerMessage.maximumLength + 50)
        let bounded = ServerMessage.sanitized(long)
        XCTAssertEqual(bounded?.count, ServerMessage.maximumLength + 1)
        XCTAssertTrue(bounded?.hasSuffix("…") == true)
    }

    private let validKey = "LD1.eyJpZCI6InRlc3QifQ.c2lnbmF0dXJl"
}

/// A server, for the length of one test.
private final class StubActivationProtocol: URLProtocol {
    private struct Answer {
        var status: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answer: Answer?
    nonisolated(unsafe) private static var transportError: Error?
    nonisolated(unsafe) private static var request: URLRequest?
    nonisolated(unsafe) private static var body: Data?

    static func respond(status: Int, body: Data) {
        lock.withLock {
            answer = Answer(status: status, body: body)
            transportError = nil
        }
    }

    static func respond(status: Int, json: [String: String]) {
        respond(status: status, body: try! JSONSerialization.data(withJSONObject: json))
    }

    static func fail(with error: Error) {
        lock.withLock {
            answer = nil
            transportError = error
        }
    }

    static func reset() {
        lock.withLock {
            answer = nil
            transportError = nil
            request = nil
            body = nil
        }
    }

    static var lastRequest: URLRequest? { lock.withLock { request } }
    static var lastBody: Data? { lock.withLock { body } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URLProtocol` hands the body over as a stream, not as `httpBody`, so
        // a test that reads the wrong one silently asserts nothing.
        let sent = request.httpBody ?? Self.read(request.httpBodyStream)
        Self.lock.withLock {
            Self.request = request
            Self.body = sent
        }

        let (answer, transportError) = Self.lock.withLock { (Self.answer, Self.transportError) }
        if let transportError {
            client?.urlProtocol(self, didFailWithError: transportError)
            return
        }
        guard let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: answer.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}
