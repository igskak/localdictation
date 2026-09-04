import Foundation

/// The one folder this app keeps anything in, and the rename that moved it.
///
/// Preferences, the dictionary, the licensing record and the downloaded model
/// weights all live in a single directory in Application Support. It was called
/// `LocalDictation` for as long as the product was, and the product is Witness
/// now — so this is the one place that knows both names, and the one place that
/// has to carry a Mac across from one to the other.
///
/// The name is deliberately **not** derived from the bundle identifier. A folder
/// named after the identifier moves again the next time the identifier does, and
/// what is in this one is a licence somebody paid for.
enum ApplicationSupportDirectory {
    static let folderName = "Witness"

    /// What the folder was called before the product was renamed. Kept because
    /// a Mac that ran an earlier build still has one, with a licence, a
    /// dictionary and several gigabytes of model weights in it.
    static let previousFolderName = "LocalDictation"

    /// Resolved once per process, which is what makes the migration run exactly
    /// once however many stores ask for the directory and whichever asks first.
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let destination = base.appendingPathComponent(folderName, isDirectory: true)
        migrate(
            from: base.appendingPathComponent(previousFolderName, isDirectory: true),
            to: destination
        )
        return destination
    }()

    static func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    static func subdirectory(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: true)
    }

    /// Renames the old folder to the new one, and does nothing in every case
    /// where doing that would not plainly be right.
    ///
    /// The rules are timid on purpose, because this folder holds a licence
    /// somebody paid for and a rename is not worth losing one over:
    ///
    /// - **A destination that already exists wins.** Two folders means a build
    ///   of each has run, the new one is the one in use, and an older copy must
    ///   not be written over it. The old folder is left alone rather than
    ///   merged: merging would have to decide which `license.json` is real, and
    ///   there is no answer to that which is right every time.
    /// - **Only a directory is moved.** Something else wearing that name is not
    ///   this app's data and is not this app's to move.
    /// - **Failure is not fatal and is not announced.** The worst a failed move
    ///   costs is one re-activation — a key is a signature, and the address that
    ///   bought it can ask for another — and that is cheaper than a launch that
    ///   dies on a file system error.
    ///
    /// Returns whether anything moved, which is what the tests read.
    @discardableResult
    static func migrate(from old: URL, to new: URL, fileManager: FileManager = .default) -> Bool {
        var oldIsDirectory: ObjCBool = false
        let oldExists = fileManager.fileExists(atPath: old.path, isDirectory: &oldIsDirectory)
        guard oldExists, oldIsDirectory.boolValue else { return false }
        guard !fileManager.fileExists(atPath: new.path) else { return false }

        do {
            try fileManager.createDirectory(
                at: new.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }
}
