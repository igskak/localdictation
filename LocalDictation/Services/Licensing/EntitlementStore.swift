import Foundation

enum EntitlementStoreError: Error, Equatable {
    case unreadable(String)
    case unwritable(String)

    var message: String {
        switch self {
        case let .unreadable(detail): "The license record could not be read: \(detail)"
        case let .unwritable(detail): "The license record could not be saved: \(detail)"
        }
    }
}

/// Persistence boundary for the usage record — the second and last thing the
/// app writes to disk.
protocol EntitlementStore: Sendable {
    func load() throws -> UsageRecord?
    func save(_ record: UsageRecord) throws
    var locationDescription: String { get }
}

/// The usage record as JSON in Application Support, beside the dictionary.
///
/// It is not obfuscated and it is not hidden, and that is a decision rather
/// than an oversight. Anything this app could do to a local file, a determined
/// user can undo in an afternoon; what obfuscation actually buys is a product
/// that lies to its owner about what it stores. The honest defence is that the
/// paid states are decided by a signature nobody outside can forge — editing
/// the record can hand someone another few days of trial, and can never hand
/// them a license.
struct FileEntitlementStore: EntitlementStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        ApplicationSupportDirectory.file("license.json")
    }

    var locationDescription: String { url.path }

    func load() throws -> UsageRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(UsageRecord.self, from: data)
        } catch {
            throw EntitlementStoreError.unreadable(error.localizedDescription)
        }
    }

    func save(_ record: UsageRecord) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            throw EntitlementStoreError.unwritable(error.localizedDescription)
        }
    }
}
