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

    func testTheRecordHoldsFiveFieldsAndNothingElse() throws {
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
            ["installedAt", "installID", "firstDictationAt", "furthestSeenAt", "licenseToken"]
        )
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
