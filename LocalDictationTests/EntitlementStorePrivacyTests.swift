import XCTest
@testable import Witness

/// The second and last file the app writes, asserted the way the dictionary is
/// in `GlossaryTests`: the encoded form is the entire persisted state, so it is
/// worth knowing exactly what is in it.
final class EntitlementStorePrivacyTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localdictation-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("license.json")
    }

    func testTheRecordHoldsSixFieldsAndNothingElse() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileEntitlementStore(url: url)
        var record = UsageRecord.new(at: Date(timeIntervalSince1970: 1_700_000_000))
        record.firstDictationAt = Date(timeIntervalSince1970: 1_700_000_100)
        record.licenseToken = "LD1.aaa.bbb"

        try store.save(record)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(json.keys),
            // The dictation counter is gone with the window it used to gate.
            // `reportedMilestones` is the sixth: the list of once-per-install
            // facts already sent, which is here rather than in a fourth file.
            ["installedAt", "installID", "firstDictationAt", "furthestSeenAt", "licenseToken", "reportedMilestones"]
        )
        XCTAssertEqual(json["reportedMilestones"] as? [String], [])
    }

    /// Every record already on a Mac was written before this field existed, and
    /// a record that fails to decode is a trial that starts over.
    func testARecordWrittenBeforeMilestonesExistedStillLoads() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let old = #"{"installedAt":"2023-11-14T22:13:20Z","installID":"D6E1","furthestSeenAt":"2023-11-14T22:15:00Z"}"#
        try Data(old.utf8).write(to: url)

        let record = try XCTUnwrap(FileEntitlementStore(url: url).load())

        XCTAssertEqual(record.installID, "D6E1")
        XCTAssertEqual(record.reportedMilestones, [])
    }

    /// The list is what stops a milestone being sent twice, so it has to
    /// survive the round trip and say which time this was.
    func testAMilestoneIsRememberedOnceAndSortedOnDisk() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileEntitlementStore(url: url)
        var record = UsageRecord.new(at: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(record.markReported(.modelReady))
        XCTAssertTrue(record.markReported(.microphoneDenied))
        XCTAssertFalse(record.markReported(.modelReady))
        XCTAssertEqual(record.reportedMilestones, ["microphoneDenied", "modelReady"])

        try store.save(record)
        XCTAssertEqual(try store.load(), record)
    }

    func testARecordSurvivesBeingWrittenAndReadBack() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileEntitlementStore(url: url)
        var record = UsageRecord.new(at: Date(timeIntervalSince1970: 1_700_000_000))
        record.firstDictationAt = Date(timeIntervalSince1970: 1_700_000_500)

        try store.save(record)

        XCTAssertEqual(try store.load(), record)
    }

    func testAMissingRecordIsAFirstRunAndNotAFailure() throws {
        let store = FileEntitlementStore(url: temporaryURL())

        XCTAssertNil(try store.load())
    }
}
