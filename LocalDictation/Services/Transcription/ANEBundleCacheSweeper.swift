import Foundation

/// Removes Neural Engine compilation leftovers abandoned by earlier runs.
///
/// Loading a Core ML model with `prewarm` makes the E5 runtime compile it into a
/// staging directory named `<hash>.tmp.<pid>_<inode>.bundle` under the app's
/// cache, then move that directory into place. A process that dies between
/// those two steps — Xcode's Stop button, a force quit, a crash during the
/// model load — leaves the staging directory behind, and nothing in macOS ever
/// collects it. Each one is about the size of the compiled model, so a day of
/// start-stop development leaves tens of gigabytes on disk.
///
/// The app cannot stop being killed, so it sweeps on the way up instead. A
/// staging directory means something only while the process that created it is
/// still compiling, which makes the owning process id the entire test: still
/// running means the compile is in flight and the directory is untouchable,
/// gone means nobody will ever finish it.
struct ANEBundleCacheSweeper: Sendable {
    /// What one sweep did, for the log line and for the tests.
    struct Outcome: Sendable, Equatable {
        var removed = 0
        var reclaimedBytes: Int64 = 0
        /// Staging directories left alone because their process is still alive.
        /// Normally this is the compile the current launch just started.
        var leftInFlight = 0
    }

    /// The `com.apple.e5rt.e5bundlecache` directory to sweep. Its interior
    /// layout — an OS build directory, then one per model — is the runtime's
    /// business, so the sweep walks whatever is there rather than assuming a
    /// depth.
    let root: URL

    /// Injected so the tests can decide what counts as running without spawning
    /// processes.
    private let isProcessAlive: @Sendable (pid_t) -> Bool

    init(
        root: URL,
        isProcessAlive: @escaping @Sendable (pid_t) -> Bool = ANEBundleCacheSweeper.processIsAlive
    ) {
        self.root = root
        self.isProcessAlive = isProcessAlive
    }

    /// The sweeper for this app's own cache, or `nil` if the cache directory
    /// cannot be located — a state with nothing to clean rather than an error.
    static func forCurrentApp() -> ANEBundleCacheSweeper? {
        guard
            let bundleIdentifier = Bundle.main.bundleIdentifier,
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }

        // A sandboxed build already resolves `.cachesDirectory` inside its
        // container, where the runtime writes without the identifier in the
        // path. Unsandboxed, the identifier is the app's own subdirectory.
        let base = caches.lastPathComponent == bundleIdentifier
            ? caches
            : caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        return ANEBundleCacheSweeper(
            root: base.appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        )
    }

    /// Blocking, and deliberately so: the caller decides what thread this
    /// belongs on, and deleting many gigabytes is not instant.
    func sweep() -> Outcome {
        var outcome = Outcome()
        let manager = FileManager.default
        guard let walk = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return outcome }

        for case let url as URL in walk {
            guard
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let owner = Self.owningProcess(ofStagingDirectoryNamed: url.lastPathComponent)
            else { continue }

            // Nothing below a staging directory is ever a staging directory.
            walk.skipDescendants()

            guard !isProcessAlive(owner) else {
                outcome.leftInFlight += 1
                continue
            }

            let size = Self.allocatedSize(of: url)
            do {
                try manager.removeItem(at: url)
                outcome.removed += 1
                outcome.reclaimedBytes += size
            } catch {
                // One unreadable directory is not a reason to abandon the rest.
                Log.transcription.error(
                    "Could not remove an abandoned model bundle: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return outcome
    }

    /// The process id out of `<hash>.tmp.<pid>_<inode>.bundle`, or `nil` for any
    /// name that is not a staging directory — including the finished bundles
    /// sitting next to them, which carry no `.tmp.` segment and must survive.
    static func owningProcess(ofStagingDirectoryNamed name: String) -> pid_t? {
        let suffix = ".bundle"
        guard
            name.hasSuffix(suffix),
            let marker = name.range(of: ".tmp.", options: .backwards)
        else { return nil }

        let identifiers = name[marker.upperBound...].dropLast(suffix.count)
        guard let separator = identifiers.firstIndex(of: "_") else { return nil }
        return pid_t(identifiers[..<separator])
    }

    /// Signal 0 asks the kernel about a process without disturbing it.
    /// `EPERM` is a live process owned by somebody else — still alive, still
    /// not ours to clean up after.
    static let processIsAlive: @Sendable (pid_t) -> Bool = { pid in
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Blocks on disk rather than bytes in files, so the number matches what
    /// the volume gets back.
    private static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walk = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walk {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
