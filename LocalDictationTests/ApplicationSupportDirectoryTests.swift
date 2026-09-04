import XCTest

@testable import Witness

/// The rename moved a folder that holds a paid licence, so what is asserted
/// here is mostly what the migration *declines* to do.
final class ApplicationSupportDirectoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("witness-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var old: URL { root.appendingPathComponent("LocalDictation", isDirectory: true) }
    private var new: URL { root.appendingPathComponent("Witness", isDirectory: true) }

    private func write(_ contents: String, to directory: URL, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func testTheLicenceMovesWithTheFolder() throws {
        try write("the paid one", to: old, named: "license.json")

        XCTAssertTrue(ApplicationSupportDirectory.migrate(from: old, to: new))

        XCTAssertEqual(read(new.appendingPathComponent("license.json")), "the paid one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "the old folder is gone, not copied")
    }

    /// Several gigabytes of weights are in there. A migration that moved the
    /// licence and left the models would be a migration that costs a download.
    func testEverythingInTheFolderMovesAndNotJustTheFilesAtTheTop() throws {
        try write("weights", to: old.appendingPathComponent("Models", isDirectory: true), named: "model.bin")
        try write("a word", to: old, named: "glossary.json")

        XCTAssertTrue(ApplicationSupportDirectory.migrate(from: old, to: new))

        XCTAssertEqual(read(new.appendingPathComponent("Models/model.bin")), "weights")
        XCTAssertEqual(read(new.appendingPathComponent("glossary.json")), "a word")
    }

    /// Two folders means a build of each has run. The new one is the one in use,
    /// and an older copy of a licence must not be written over it.
    func testAnExistingDestinationIsNeverWrittenOver() throws {
        try write("the one in use", to: new, named: "license.json")
        try write("an older copy", to: old, named: "license.json")

        XCTAssertFalse(ApplicationSupportDirectory.migrate(from: old, to: new))

        XCTAssertEqual(read(new.appendingPathComponent("license.json")), "the one in use")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "and the old one is left to be looked at")
    }

    func testNothingHappensWhenThereIsNothingToMove() {
        XCTAssertFalse(ApplicationSupportDirectory.migrate(from: old, to: new))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }

    /// Something else wearing that name is not this app's data.
    func testAFileWithTheOldNameIsLeftAlone() throws {
        try "not a folder".write(to: old, atomically: true, encoding: .utf8)

        XCTAssertFalse(ApplicationSupportDirectory.migrate(from: old, to: new))

        XCTAssertEqual(read(old), "not a folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }

    func testMigratingTwiceIsHarmless() throws {
        try write("the paid one", to: old, named: "license.json")

        XCTAssertTrue(ApplicationSupportDirectory.migrate(from: old, to: new))
        XCTAssertFalse(ApplicationSupportDirectory.migrate(from: old, to: new))

        XCTAssertEqual(read(new.appendingPathComponent("license.json")), "the paid one")
    }

    /// The name the product ships under, and the name it has to remember.
    func testTheTwoNamesAreTheProductsOldAndNew() {
        XCTAssertEqual(ApplicationSupportDirectory.folderName, "Witness")
        XCTAssertEqual(ApplicationSupportDirectory.previousFolderName, "LocalDictation")
    }

    /// Every store shares one directory, so a second rename is one edit.
    func testEveryStoreAsksTheSameDirectoryForItsFile() {
        let directory = ApplicationSupportDirectory.url
        XCTAssertEqual(FilePreferencesStore.defaultURL().deletingLastPathComponent(), directory)
        XCTAssertEqual(FileGlossaryStore.defaultURL().deletingLastPathComponent(), directory)
        XCTAssertEqual(FileEntitlementStore.defaultURL().deletingLastPathComponent(), directory)
        XCTAssertEqual(directory.lastPathComponent, "Witness")
    }
}
