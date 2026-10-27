import Foundation
import XCTest
@testable import Witness

final class LocalizationTests: XCTestCase {
    private let expansionLocales = ["es", "it", "fr"]

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

    func testPaidSurfacesHaveSpanishItalianAndFrenchCopy() throws {
        XCTAssertTrue(Set(expansionLocales).isSubset(of: Set(L10n.bundle.localizations)))

        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let essentialKeys = [
            "License",
            "Email address",
            "Continue with your email",
            "Send me a key",
            "Already bought a license?",
            "Manage subscription",
            "Lifetime",
            "Annual",
            "Buy",
            "The first three days need no email and no key. After that, Witness asks for your email address, to carry on.",
            "The first three days are over. Enter your email address to carry on. No payment is needed at this step, and nothing you have dictated has left this Mac.",
        ]

        for key in essentialKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in expansionLocales {
                let translation = try translation(in: localizations, locale: locale, key: key)
                XCTAssertNotEqual(translation, key, "\(locale): \(key)")
            }
        }

        let completeCount = strings.values.reduce(into: 0) { count, rawEntry in
            guard let entry = rawEntry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any]
            else { return }
            if expansionLocales.allSatisfy({ locale in
                guard let localization = localizations[locale] as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any],
                      unit["state"] as? String == "translated",
                      let value = unit["value"] as? String
                else { return false }
                return !value.isEmpty
            }) {
                count += 1
            }
        }
        XCTAssertGreaterThanOrEqual(completeCount, 79)
    }

    func testLegallySignificantCheckoutDeclarationWaitsForReviewedTranslations() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let key = "Send my license key as soon as I have paid. I understand that I give up my right of withdrawal once delivery begins."
        let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)

        for locale in expansionLocales {
            XCTAssertNil(
                localizations[locale],
                "\(locale) legal copy must come from counsel review, not ordinary product translation"
            )
        }

        for key in ["Terms", "Right of withdrawal"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in expansionLocales {
                XCTAssertTrue(
                    try translation(in: localizations, locale: locale, key: key).hasSuffix("(EN)"),
                    "\(locale): English-only legal destination must be disclosed"
                )
            }
        }
    }

    func testFirstRunHasSpanishItalianAndFrenchCopy() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let essentialKeys = [
            "Which languages do you speak?",
            "Every utterance is recognized as one of the languages you pick here, and never as one you did not. Pick as many as you actually use — there is nothing to switch between afterwards.",
            "Recognition + calibrated verification",
            "German, English, Russian, and Ukrainian are measured end to end. Spanish, Italian, and French also get calibrated review marks for values, dates, names, dictionary terms, and malformed words; advanced cleanup stays conservative until recorded-speech measurement is complete. Other languages are recognized without language-specific guesses.",
            "Let’s get Witness ready",
            "The first three days ask for nothing",
            "Nothing you dictate ever leaves this Mac. Nine events about setting it up and about the trial do — the install, the speech model arriving or failing to, a press that finds it still arriving, a refused microphone, the trial starting, the email ask, and the offers — with no more than an app version, a macOS version, and a random number made at install. Settings → Privacy turns them off.",
            "Open Witness when I log in",
            "Allow microphone access",
            "Allow typing into other apps",
            "The speech model is downloading",
            "Recognition runs on this Mac, with no network and no account.",
        ]

        for key in essentialKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in expansionLocales {
                XCTAssertNotEqual(try translation(in: localizations, locale: locale, key: key), key)
            }
        }

        let completeCount = strings.values.filter { rawEntry in
            guard let entry = rawEntry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any]
            else { return false }
            return expansionLocales.allSatisfy { locale in
                guard let localization = localizations[locale] as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any]
                else { return false }
                return unit["state"] as? String == "translated"
                    && !(unit["value"] as? String ?? "").isEmpty
            }
        }.count
        XCTAssertGreaterThanOrEqual(completeCount, 142)
    }

    func testMenuBarAndRuntimeNoticesHaveSpanishItalianAndFrenchCopy() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let essentialKeys = [
            "Ready",
            "Recording",
            "Recognizing speech on this Mac. %@",
            "Inserting",
            "Worth a look",
            "Check %lld flagged fragments",
            "Number",
            "Amount",
            "Date",
            "Name",
            "Not a word",
            "Uncertain",
            "Nothing was heard",
            "Nothing was recognized",
            "Copied to the clipboard. Grant Accessibility access to have it typed for you.",
            "Nothing was inserted: the focus is in a password field. The text is here and was not copied.",
            "The speech model is still arriving",
            "Recent dictations",
            "%.2f s · %d frames · peak %.2f",
            "%.2f× real time",
        ]

        for key in essentialKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in expansionLocales {
                XCTAssertFalse(try translation(in: localizations, locale: locale, key: key).isEmpty)
            }
        }

        let completeCount = strings.values.filter { rawEntry in
            guard let entry = rawEntry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any]
            else { return false }
            return expansionLocales.allSatisfy { locale in
                guard let localization = localizations[locale] as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any]
                else { return false }
                return unit["state"] as? String == "translated"
                    && !(unit["value"] as? String ?? "").isEmpty
            }
        }.count
        XCTAssertGreaterThanOrEqual(completeCount, 235)
    }

    func testGeneralSettingsHaveSpanishItalianAndFrenchCopy() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let essentialKeys = [
            "General",
            "Languages",
            "Dictionary",
            "Shortcut",
            "Open at login",
            "Cleanup",
            "Check for updates automatically",
            "Input source",
            "Audio stays in memory on this Mac. Nothing is written to disk during normal capture, and nothing you dictate is ever sent anywhere. A recording is discarded as soon as the app decides no review is needed, and otherwise when the review ends.",
            "Send nine events about setup and the trial",
            "Insert automatically when nothing needs review",
            "Accessibility access",
            "Your languages",
            "Add a term or correction",
            "When Witness writes “%@”, replace it with “%@”.",
            "Remove this term",
            "This file is the only thing the app persists. Transcripts and recordings stay in memory.",
        ]

        for key in essentialKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in expansionLocales {
                XCTAssertFalse(try translation(in: localizations, locale: locale, key: key).isEmpty)
            }
        }

        let completeCount = strings.values.filter { rawEntry in
            guard let entry = rawEntry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any]
            else { return false }
            return expansionLocales.allSatisfy { locale in
                guard let localization = localizations[locale] as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any]
                else { return false }
                return unit["state"] as? String == "translated"
                    && !(unit["value"] as? String ?? "").isEmpty
            }
        }.count
        XCTAssertGreaterThanOrEqual(completeCount, 316)
    }

    func testNewMarketTranslationsPreserveFormatArguments() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for (key, rawEntry) in strings {
            guard let entry = rawEntry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  expansionLocales.contains(where: { localizations[$0] != nil })
            else { continue }

            let sourceArguments = formatArguments(in: key)
            for locale in expansionLocales {
                let value = try translation(in: localizations, locale: locale, key: key)
                XCTAssertEqual(formatArguments(in: value), sourceArguments, "\(locale): \(key)")
            }
        }
    }

    func testPermissionPromptsHaveNewMarketCopy() throws {
        let catalog = try catalog(named: "InfoPlist")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in expansionLocales {
                XCTAssertFalse(try translation(in: localizations, locale: locale, key: key).isEmpty)
            }
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

    private func translation(
        in localizations: [String: Any],
        locale: String,
        key: String
    ) throws -> String {
        let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "\(locale): \(key)")
        let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "\(locale): \(key)")
        XCTAssertEqual(unit["state"] as? String, "translated", "\(locale): \(key)")
        return try XCTUnwrap(unit["value"] as? String, "\(locale): \(key)")
    }

    private func formatArguments(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:\.\d+)?(?:@|lld|d|f)"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return expression?.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }.sorted() ?? []
    }
}
