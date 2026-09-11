import Foundation
import XCTest
@testable import Witness

final class LocalizationTests: XCTestCase {
    func testGermanIsBundledAndUsesTheEnglishSourceAsItsKey() throws {
        XCTAssertTrue(L10n.bundle.localizations.contains("de"))

        let path = try XCTUnwrap(L10n.bundle.path(forResource: "de", ofType: "lproj"))
        let germanBundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(
            germanBundle.localizedString(forKey: "Ready", value: nil, table: nil),
            "Bereit"
        )
        XCTAssertEqual(
            germanBundle.localizedString(forKey: "Which languages do you speak?", value: nil, table: nil),
            "Welche Sprachen sprichst du?"
        )
    }

    func testGermanCatalogEntriesAreComplete() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            let german = try XCTUnwrap(localizations["de"] as? [String: Any], key)
            let unit = try XCTUnwrap(german["stringUnit"] as? [String: Any], key)
            XCTAssertEqual(unit["state"] as? String, "translated", key)
            XCTAssertFalse((unit["value"] as? String ?? "").isEmpty, key)
        }
    }

    func testPermissionPromptsHaveGermanCopy() throws {
        let catalog = try catalog(named: "InfoPlist")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let german = try XCTUnwrap(localizations["de"] as? [String: Any])
            let unit = try XCTUnwrap(german["stringUnit"] as? [String: Any])
            XCTAssertFalse((unit["value"] as? String ?? "").isEmpty)
        }
    }

    private func catalog(named name: String) throws -> [String: Any] {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDirectory
            .deletingLastPathComponent()
            .appending(path: "LocalDictation/Resources/\(name).xcstrings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
