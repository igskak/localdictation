import XCTest
@testable import LocalDictation

/// Covers the rule the sweep turns on — an abandoned staging directory goes, an
/// in-flight one stays — over a real directory tree, with process liveness
/// stubbed so no test ever has to spawn or kill anything.
final class ANEBundleCacheSweeperTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ane-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Name parsing

    func testReadsTheOwningProcessOutOfAStagingName() {
        let pid = ANEBundleCacheSweeper.owningProcess(
            ofStagingDirectoryNamed: "181D96AD.tmp.77864_35591440384.bundle"
        )
        XCTAssertEqual(pid, 77864)
    }

    func testFinishedBundlesAreNotStagingDirectories() {
        XCTAssertNil(ANEBundleCacheSweeper.owningProcess(ofStagingDirectoryNamed: "181D96AD.bundle"))
    }

    func testNamesWithoutAProcessIdAreNotStagingDirectories() {
        XCTAssertNil(ANEBundleCacheSweeper.owningProcess(ofStagingDirectoryNamed: "181D96AD.tmp.bundle"))
        XCTAssertNil(ANEBundleCacheSweeper.owningProcess(ofStagingDirectoryNamed: "181D96AD.tmp.abc_1.bundle"))
        XCTAssertNil(ANEBundleCacheSweeper.owningProcess(ofStagingDirectoryNamed: "notabundle.tmp.12_3.txt"))
    }

    // MARK: - Sweeping

    func testRemovesStagingDirectoriesWhoseProcessIsGone() throws {
        let abandoned = try makeStagingDirectory(pid: 4242, bytes: 2048)

        let outcome = sweeper(alive: []).sweep()

        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(outcome.leftInFlight, 0)
        XCTAssertGreaterThan(outcome.reclaimedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testKeepsStagingDirectoriesWhoseProcessIsStillRunning() throws {
        let inFlight = try makeStagingDirectory(pid: 4242, bytes: 512)

        let outcome = sweeper(alive: [4242]).sweep()

        XCTAssertEqual(outcome.removed, 0)
        XCTAssertEqual(outcome.leftInFlight, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path))
    }

    /// The compiled model the runtime actually uses lives beside the staging
    /// directories and carries no `.tmp.` segment. Deleting it would cost the
    /// user a recompile on the next launch.
    func testLeavesFinishedBundlesAlone() throws {
        let finished = root
            .appendingPathComponent("25C56/HASH/HASH.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: finished, withIntermediateDirectories: true)
        try Data(count: 128).write(to: finished.appendingPathComponent("model.bin"))

        let outcome = sweeper(alive: []).sweep()

        XCTAssertEqual(outcome.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
    }

    func testSweepsEveryModelDirectoryInOnePass() throws {
        let first = try makeStagingDirectory(pid: 11, bytes: 256, model: "MODEL-A")
        let second = try makeStagingDirectory(pid: 12, bytes: 256, model: "MODEL-B")
        let running = try makeStagingDirectory(pid: 13, bytes: 256, model: "MODEL-B")

        let outcome = sweeper(alive: [13]).sweep()

        XCTAssertEqual(outcome.removed, 2)
        XCTAssertEqual(outcome.leftInFlight, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: running.path))
    }

    /// First launch on a machine that has never compiled a model: the cache
    /// directory does not exist yet, and that is not a failure.
    func testMissingCacheDirectoryIsQuietlyNothingToDo() {
        let outcome = ANEBundleCacheSweeper(
            root: root.appendingPathComponent("never-created", isDirectory: true),
            isProcessAlive: { _ in false }
        ).sweep()

        XCTAssertEqual(outcome, ANEBundleCacheSweeper.Outcome())
    }

    // MARK: - Helpers

    private func sweeper(alive: Set<pid_t>) -> ANEBundleCacheSweeper {
        ANEBundleCacheSweeper(root: root, isProcessAlive: { alive.contains($0) })
    }

    /// Mirrors the real layout: an OS build directory, a model directory, then
    /// the staging directory itself.
    @discardableResult
    private func makeStagingDirectory(
        pid: pid_t,
        bytes: Int,
        model: String = "MODEL"
    ) throws -> URL {
        let directory = root
            .appendingPathComponent("25C56", isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
            .appendingPathComponent("\(model).tmp.\(pid)_99.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: directory.appendingPathComponent("weights.bin"))
        return directory
    }
}
