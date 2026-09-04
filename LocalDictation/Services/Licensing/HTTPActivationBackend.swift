import Foundation

/// The address of the activation service, and the one switch that turns the
/// email path on.
///
/// It is live: the service in `Service/` is deployed, `/v1/health` reports that
/// the key it signs with is the one `LicenseAuthority` accepts, and a key it
/// issued has been read back through `LicenseKey.verify`.
///
/// **This URL is compiled into every build that ships, and a shipped build
/// cannot be told a new one.** A workers.dev hostname is therefore a temporary
/// answer: it is the account's subdomain plus the worker's name, and either
/// changing strands every copy already installed. Before the first public
/// build this has to become a custom domain on the product's own domain, which
/// can then be pointed anywhere — see `docs/PHASE_6_RELEASE.md`.
///
/// The cost of getting that wrong is bounded rather than fatal, and that is by
/// design: nothing in the checking path calls this. A licence is a signature,
/// verified on the Mac, so a build whose endpoint has gone stale can still
/// accept a pasted key and still works forever on a plane. What it loses is the
/// ability to start a trial by typing an address.
enum ActivationEndpoint {
    static let production = URL(string: "https://localdictation-activation.localdictation-activation.workers.dev/v1/activate")

    /// What the live app gets. A build with no endpoint gates nothing extra: it
    /// simply cannot mail anyone a key.
    static func backend() -> any ActivationBackend {
        guard let production else { return UnconfiguredActivationBackend() }
        return HTTPActivationBackend(endpoint: production)
    }
}

/// The only network call this app makes on its own behalf, and the only place
/// a request body is built.
///
/// The body has two fields, `email` and `device`, and a test asserts that the
/// encoded form has exactly those two — the same enforcement `TelemetryEnvelope`
/// gets, for the same reason: the privacy boundary of this product is a list
/// someone can check, not a habit.
///
/// The session is ephemeral and refuses cookies. There is nothing here worth
/// keeping between calls, and a cookie jar is a way for a service to recognize
/// a Mac across activations that nobody asked it to have.
struct HTTPActivationBackend: ActivationBackend {
    /// A response larger than this is not a license key, and reading it into
    /// memory to find that out is the service's decision to make about this
    /// app's memory rather than this app's.
    static let maximumResponseBytes = 8 * 1024

    private let endpoint: URL
    private let releaseEndpoint: URL
    private let session: URLSession

    /// `isConfigured` is false for a plain-HTTP endpoint rather than silently
    /// upgrading it. An email address and a device identifier over a cleartext
    /// connection is exactly the thing this product promises not to do, and a
    /// misconfiguration should look like an unfinished build, not like a
    /// working one.
    init(endpoint: URL, releaseEndpoint: URL? = nil, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.releaseEndpoint = releaseEndpoint ?? Self.siblingRelease(of: endpoint)
        self.session = session ?? Self.makeSession()
    }

    /// `.../v1/activate` and `.../v1/devices/release` are one service, so there
    /// is one constant to fill in rather than two that could disagree about
    /// which deployment they point at.
    static func siblingRelease(of endpoint: URL) -> URL {
        endpoint
            .deletingLastPathComponent()
            .appendingPathComponent("devices")
            .appendingPathComponent("release")
    }

    var isConfigured: Bool { endpoint.scheme?.lowercased() == "https" }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Long enough for a mail-sending service on a slow connection, short
        // enough that a user who pressed a button gets an answer rather than a
        // spinner they have to guess about.
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    func requestKey(email: String, deviceID: String) async throws -> String {
        guard isConfigured else { throw ActivationError.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Deliberately carries no version. The two fields below are the whole
        // of what this product sends here, and a default user agent would add
        // an app build and an OS build to that list without them appearing in
        // the privacy policy.
        request.setValue("LocalDictation", forHTTPHeaderField: "User-Agent")
        request.httpBody = try Self.body(email: email, deviceID: deviceID)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ActivationError.unreachable(error.localizedDescription)
        } catch {
            throw ActivationError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ActivationError.unreachable("the reply was not an HTTP response")
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw ActivationError.rejected("The activation service replied with something too large to be a license key.")
        }

        let reply = ActivationReply(data)

        switch http.statusCode {
        case 200...299:
            guard let key = reply.key else {
                throw ActivationError.rejected("The activation service replied without a key. Nothing was activated; try again, or paste a key from your email.")
            }
            return key

        // Everything the service says "no, and here is why" with. The code
        // decides the sentence; the free-text message is only ever used where
        // the code has nothing better, and it is bounded before it is shown.
        case 400, 401, 403, 404, 409, 410, 422:
            throw reply.error(status: http.statusCode)

        // Temporary by definition — a rate limit or a service having a bad
        // day. Both leave the user exactly where they were, which is why they
        // are told to come back rather than told they were refused.
        case 429:
            throw ActivationError.unreachable("it is asking us to wait a moment. Try again shortly.")
        case 500...599:
            throw ActivationError.unreachable("it answered with an error (\(http.statusCode)). Your dictation is unaffected; try again shortly.")

        default:
            throw reply.error(status: http.statusCode)
        }
    }

    /// Hands one of the two Macs back.
    ///
    /// The answer is deliberately thin: released or not. There is nothing for
    /// the app to read out of a success, and the local half has already been
    /// decided by the time this is called.
    func releaseDevice(key: String, deviceID: String) async throws {
        guard isConfigured else { throw ActivationError.notConfigured }

        var request = URLRequest(url: releaseEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LocalDictation", forHTTPHeaderField: "User-Agent")
        request.httpBody = try Self.releaseBody(key: key, deviceID: deviceID)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ActivationError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ActivationError.unreachable("the reply was not an HTTP response")
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw ActivationError.rejected("The activation service replied with something unreadable.")
        }

        switch http.statusCode {
        case 200...299:
            return
        case 429:
            throw ActivationError.unreachable("it is asking us to wait a moment. Try again shortly.")
        case 500...599:
            throw ActivationError.unreachable("it answered with an error (\(http.statusCode)).")
        default:
            throw ActivationReply(data).error(status: http.statusCode)
        }
    }

    /// The request body, alone, so a test can assert its shape without a server.
    static func body(email: String, deviceID: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ActivationRequestBody(device: deviceID, email: email))
    }

    static func releaseBody(key: String, deviceID: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(DeviceReleaseRequestBody(device: deviceID, key: key))
    }
}

/// The wire request. Two fields, and that is the contract in `docs/PHASE_8.md`.
struct ActivationRequestBody: Codable, Sendable, Equatable {
    let device: String
    let email: String

    static let allowedFields = ["device", "email"]
}

/// The other two-field body. The key is one this service issued, going back to
/// the service that issued it, so it tells it nothing it did not already write.
struct DeviceReleaseRequestBody: Codable, Sendable, Equatable {
    let device: String
    let key: String

    static let allowedFields = ["device", "key"]
}

/// What came back, read defensively.
///
/// A service that is having a bad day answers with an HTML error page, and a
/// license reader that trusts a body because the status line looked right is
/// how a proxy's captive portal becomes a "license key".
private struct ActivationReply {
    private struct Payload: Decodable {
        let key: String?
        let error: String?
        let message: String?
    }

    private let payload: Payload?

    init(_ data: Data) {
        payload = try? JSONDecoder().decode(Payload.self, from: data)
    }

    /// Only a key that at least claims to be ours. The signature is checked
    /// afterwards by `LicenseKey.verify`, which is the actual gate — this only
    /// keeps a proxy's error page from being stored as a token.
    var key: String? {
        guard let raw = payload?.key?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard raw.hasPrefix(LicenseKey.prefix + "."), raw.count <= 4096 else { return nil }
        return raw
    }

    func error(status: Int) -> ActivationError {
        switch payload?.error {
        case "invalid_email": return .invalidEmail
        case "device_limit": return .deviceLimitReached
        default: break
        }
        if let message = ServerMessage.sanitized(payload?.message) {
            return .rejected(message)
        }
        return .rejected("The activation service refused this request (\(status)). Paste a key from your email instead, or write to support.")
    }
}

/// Text that came from a server and is about to be shown to a person.
///
/// Bounded rather than trusted: one line, two hundred characters, no control
/// characters. A sentence from the service is useful — "this address already
/// has a key, check your mail" is better than anything this app could guess —
/// but it is the one string in the product that this repository does not write,
/// and it does not get to lay out the window it appears in.
enum ServerMessage {
    static let maximumLength = 200

    static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let printable = firstLine.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var text = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.count > maximumLength {
            text = String(text.prefix(maximumLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }
}
