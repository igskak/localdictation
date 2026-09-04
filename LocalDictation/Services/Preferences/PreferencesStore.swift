import Foundation

enum PreferencesStoreError: Error, Equatable {
    case unreadable(String)
    case unwritable(String)

    var message: String {
        switch self {
        case let .unreadable(detail): "Settings could not be read: \(detail)"
        case let .unwritable(detail): "Settings could not be saved: \(detail)"
        }
    }
}

/// Persistence boundary for the app's own settings.
///
/// The same shape as `GlossaryStore` and for the same reason: the coordinator's
/// tests must never touch the real Application Support directory, and every
/// write this app makes should be reachable through an obvious seam rather than
/// scattered across call sites.
protocol PreferencesStore: Sendable {
    func load() throws -> Preferences
    func save(_ preferences: Preferences) throws
    var locationDescription: String { get }
}

/// Settings as JSON in Application Support, beside the dictionary and the
/// licensing record.
///
/// Readable in a text editor, like `license.json`, and for the same reason: a
/// file the app will not show its owner is a file the app is keeping from them.
/// There is nothing here worth hiding — a key code, a modifier mask, a mode, a
/// language pair, and one boolean.
///
/// A file that cannot be read is a first run rather than a failure. Settings
/// are a convenience, and refusing to dictate because one of them is corrupt
/// would be the app treating its own preferences as more important than the
/// thing it exists to do.
struct FilePreferencesStore: PreferencesStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        ApplicationSupportDirectory.file("preferences.json")
    }

    var locationDescription: String { url.path }

    func load() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return .default }
            return try JSONDecoder().decode(Preferences.self, from: data)
        } catch {
            throw PreferencesStoreError.unreadable(error.localizedDescription)
        }
    }

    func save(_ preferences: Preferences) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(preferences)
            try data.write(to: url, options: .atomic)
        } catch {
            throw PreferencesStoreError.unwritable(error.localizedDescription)
        }
    }
}

/// Settings that live only as long as the test that made them.
struct InMemoryPreferencesStore: PreferencesStore {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var preferences: Preferences
        var saveCount = 0
        init(_ preferences: Preferences) { self.preferences = preferences }
    }

    private let box: Box

    init(_ preferences: Preferences = .default) {
        box = Box(preferences)
    }

    var locationDescription: String { "memory" }
    var saveCount: Int { box.lock.withLock { box.saveCount } }
    var stored: Preferences { box.lock.withLock { box.preferences } }

    func load() throws -> Preferences {
        box.lock.withLock { box.preferences }
    }

    func save(_ preferences: Preferences) throws {
        box.lock.withLock {
            box.preferences = preferences
            box.saveCount += 1
        }
    }
}
