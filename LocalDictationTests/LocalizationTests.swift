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

    /// The German half of `LicensePresentationTests.testNoLicensingSentenceStillNamesTheOldTrial`.
    ///
    /// The suite renders sentences in the machine's language, so a German
    /// value is never read by that sweep — and "Die vierzehn Tage sind am %@
    /// abgelaufen" shipped in 0.5.0 behind an English key that had the same
    /// mistake. Withdrawal copy is exempt: fourteen days is the statutory
    /// Widerruf period and has nothing to do with the trial.
    func testNoCatalogEntryStillNamesTheOldTrialLength() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let stale = try NSRegularExpression(pattern: "fourteen|vierzehn|14[ -]?(day|tage)|five dictations|fünf diktat", options: [.caseInsensitive])

        for (key, rawEntry) in strings {
            let german = (((rawEntry as? [String: Any])?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = german?["value"] as? String ?? ""
            for text in [key, value] where !text.localizedCaseInsensitiveContains("withdraw") && !text.localizedCaseInsensitiveContains("widerruf") {
                let range = NSRange(text.startIndex..., in: text)
                XCTAssertNil(stale.firstMatch(in: text, range: range), "still names the old trial: \(text)")
            }
        }
    }

    /// Renaming a source string silently drops its translation — the key no
    /// longer matches and German falls back to English. The rewritten
    /// ended-trial sentence is checked to have arrived with its German.
    func testTheEndedTrialSentenceIsStillTranslated() throws {
        let path = try XCTUnwrap(L10n.bundle.path(forResource: "de", ofType: "lproj"))
        let germanBundle = try XCTUnwrap(Bundle(path: path))
        let key = "The trial ran out on %@. Your dictionary and settings are untouched and come straight back with a license."
        let german = germanBundle.localizedString(forKey: key, value: nil, table: nil)

        XCTAssertNotEqual(german, key, "the German translation did not survive the key change")
        XCTAssertTrue(german.hasPrefix("Der Test ist am %@ abgelaufen."), german)
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
