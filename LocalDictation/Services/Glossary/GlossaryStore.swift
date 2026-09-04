import Foundation

enum GlossaryStoreError: Error, Equatable {
    case unreadable(String)
    case unwritable(String)

    var message: String {
        switch self {
        case let .unreadable(detail): "The dictionary could not be read: \(detail)"
        case let .unwritable(detail): "The dictionary could not be saved: \(detail)"
        }
    }
}

/// Persistence boundary for the user's vocabulary.
///
/// A protocol rather than a direct file call so the coordinator's tests never
/// touch the real Application Support directory, and so the only persistence in
/// the app has an obvious, auditable seam.
protocol GlossaryStore: Sendable {
    func load() throws -> Glossary
    func save(_ glossary: Glossary) throws
    /// Where the file lives, so the user can be shown it rather than told it
    /// exists somewhere.
    var locationDescription: String { get }
}

/// The user's vocabulary as JSON in Application Support.
///
/// Storing terms and languages and nothing else is a property worth keeping
/// checkable: the encoded payload is the entire persisted state of the app, and
/// a test asserts a transcript cannot end up in it.
struct FileGlossaryStore: GlossaryStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        ApplicationSupportDirectory.file("glossary.json")
    }

    var locationDescription: String { url.path }

    func load() throws -> Glossary {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return .empty }
            return try JSONDecoder().decode(Glossary.self, from: data)
        } catch {
            throw GlossaryStoreError.unreadable(error.localizedDescription)
        }
    }

    func save(_ glossary: Glossary) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(glossary)
            try data.write(to: url, options: .atomic)
        } catch {
            throw GlossaryStoreError.unwritable(error.localizedDescription)
        }
    }
}
