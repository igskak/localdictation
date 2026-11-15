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
            "Use Witness for three days without an email address. Then add your email to continue.",
            "Your first three days are over. Enter your email to continue. No payment is needed at this step. Your dictation stays on this Mac.",
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

    func testOnlyCounselGatedCopyRemainsUntranslatedInExpansionLocales() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let legalKey = "Send my license key as soon as I have paid. I understand that I give up my right of withdrawal once delivery begins."
        var missing: Set<String> = []

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in expansionLocales {
                guard let localization = localizations[locale] as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any],
                      unit["state"] as? String == "translated",
                      !(unit["value"] as? String ?? "").isEmpty
                else {
                    missing.insert("\(locale):\(key)")
                    continue
                }
            }
        }

        XCTAssertEqual(
            missing,
            Set(expansionLocales.map { "\($0):\(legalKey)" })
        )
    }

    func testFirstRunHasSpanishItalianAndFrenchCopy() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let essentialKeys = [
            "Which languages do you speak?",
            "Every utterance is recognized as one of the languages you pick here, and never as one you did not. Pick as many as you actually use — there is nothing to switch between afterwards.",
            "Recognition and review",
            "German, English, Russian and Ukrainian support tested recognition, cleanup and review. Spanish, Italian and French also have calibrated review marks; advanced cleanup remains limited. Other languages support recognition without language-specific review rules.",
            "Let’s get Witness ready",
            "Three days free, no email needed",
            "Your dictation stays on this Mac. Witness can share nine types of setup and trial events, with the app version, macOS version and a random installation ID. These include installation, model download progress and failures, attempts before the model is ready, microphone denial, trial start, the email prompt and offers shown. You can turn sharing off in Settings → Privacy.",
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
            "Unusual spelling",
            "Uncertain",
            "Nothing was heard",
            "Nothing was recognized",
            "Copied to the clipboard. Grant Accessibility access to have it typed for you.",
            "Nothing was inserted: the focus is in a password field. The text is here and was not copied.",
            "Downloading the speech model",
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
            "Insert text automatically",
            "Accessibility access",
            "Your languages",
            "Add a term or correction",
            "When Witness writes “%@”, replace it with “%@”.",
            "Remove this term",
            "Your dictionary is saved on this Mac. Recordings and transcripts stay in memory.",
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

    func testBoundaryAndDiagnosticsHaveSpanishItalianAndFrenchCopy() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let essentialKeys = [
            "Voice activity thresholds",
            "Speech threshold (RMS)",
            "Silence threshold (RMS)",
            "Maximum utterance",
            "Buffer capacity",
            "Current buffer",
            "Dropped frames",
            "Voice activity",
            "Last utterance",
            "End reason",
            "Last result",
            "Attention",
            "Last insertion",
            "Audio lifetime",
            "Debug export",
            "Export last utterance as WAV…",
            "%1$@ · %2$lld Hz · %3$lld ch",
            "%1$lld Hz · mono · Float32",
            "%lld frames",
            "Hotkey released",
            "Maximum duration reached",
            "Interrupted",
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
        XCTAssertGreaterThanOrEqual(completeCount, 374)
    }

    func testReviewHasSpanishItalianAndFrenchCopy() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let essentialKeys = [
            "Raw transcript, exactly as recognized",
            "Play this fragment from memory",
            "Show cleaned text",
            "Show raw transcript",
            "Copy raw",
            "Close",
            "Nothing flagged",
            "1 fragment worth checking",
            "%lld fragments worth checking",
            "1 more marked for context",
            "%lld more marked for context",
            "Number",
            "Amount",
            "Date",
            "Name",
            "Close to “%@”",
            "Unusual spelling",
            "%@ word",
            "Uncertain",
            "Filler removed",
            "Dictionary correction",
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
        XCTAssertGreaterThanOrEqual(completeCount, 413)
    }

    func testExpansionCopyUsesReviewedProductLanguage() throws {
        let catalog = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let reviewed: [String: [String: String]] = [
            "Mark similar spellings": [
                "es": "Señalar palabras parecidas",
                "it": "Segnala grafie simili",
                "fr": "Signaler les graphies proches",
            ],
            "Extended": ["es": "Avanzada", "it": "Avanzata", "fr": "Avancé"],
            "Nothing flagged": [
                "es": "Nada que revisar",
                "it": "Niente da controllare",
                "fr": "Rien à vérifier",
            ],
            "Surface normalization": [
                "es": "Formato tipográfico ajustado",
                "it": "Grafia uniformata",
                "fr": "Typographie harmonisée",
            ],
        ]

        for (key, expected) in reviewed {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in expansionLocales {
                XCTAssertEqual(
                    try translation(in: localizations, locale: locale, key: key),
                    expected[locale],
                    "\(locale): \(key)"
                )
            }
        }

        let phaseKey = "Phase 6 adds the trial, activation, and licensing. Dictation itself is unchanged: the words still go straight into the application you were typing in, and everything about them still stays on this Mac."
        let phaseEntry = try XCTUnwrap(strings[phaseKey] as? [String: Any])
        let phaseLocalizations = try XCTUnwrap(phaseEntry["localizations"] as? [String: Any])
        for locale in expansionLocales {
            let value = try translation(in: phaseLocalizations, locale: locale, key: phaseKey).lowercased()
            XCTAssertFalse(value.contains("phase 6"), locale)
            XCTAssertFalse(value.contains("fase 6"), locale)
        }

        let telemetryKey = "Shared events cover installation; model download start, completion or failure; attempts before the model is ready; microphone denial; trial start; the email prompt; and offers shown. Each includes the app version, macOS version and a random installation ID. The six setup events are sent once per installation. Turning this off stops all nine event types."
        let telemetryEntry = try XCTUnwrap(strings[telemetryKey] as? [String: Any])
        let telemetryLocalizations = try XCTUnwrap(telemetryEntry["localizations"] as? [String: Any])
        let italian = try translation(in: telemetryLocalizations, locale: "it", key: telemetryKey)
        let french = try translation(in: telemetryLocalizations, locale: "fr", key: telemetryKey)
        XCTAssertFalse(italian.contains("Se attiva"))
        XCTAssertFalse(italian.contains("ancora in arrivo"))
        XCTAssertFalse(french.contains("une pression le trouve"))

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
        // The withdrawal declaration intentionally keeps its reviewed English
        // and German copy. Every ordinary product string has all UI locales.
        XCTAssertEqual(completeCount, strings.count - 1)
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
            for locale in ["de"] + expansionLocales {
                let value = try translation(in: localizations, locale: locale, key: key)
                XCTAssertEqual(formatArguments(in: value), sourceArguments, "\(locale): \(key)")
            }
        }
    }

    func testEverySettingsDestinationHasTranslatedNavigation() throws {
        let strings = try XCTUnwrap(try catalog(named: "Localizable")["strings"] as? [String: Any])
        for section in SettingsSection.allCases {
            let entry = try XCTUnwrap(strings[section.title] as? [String: Any], section.title)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for locale in ["de"] + expansionLocales {
                XCTAssertFalse(try translation(in: localizations, locale: locale, key: section.title).isEmpty)
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
        let key = "Your trial ended on %@. Choose a license to continue. Your dictionary and settings are still here."
        let german = germanBundle.localizedString(forKey: key, value: nil, table: nil)

        XCTAssertNotEqual(german, key, "the German translation did not survive the key change")
        XCTAssertTrue(german.hasPrefix("Deine Testphase ist am %@ abgelaufen."), german)
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
