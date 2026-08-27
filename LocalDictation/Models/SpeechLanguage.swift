import Foundation

/// The writing system a language uses, as a property of the language.
///
/// Three cases rather than a script code, because three is all any rule in this
/// app can act on: Latin and Cyrillic are the pair the language-evidence rules
/// separate, and everything else is a script those rules must stay silent
/// about. See `LanguageIdentifier`.
enum LanguageScript: String, Sendable, Equatable, Hashable, Codable {
    case latin
    case cyrillic
    /// Arabic, Han, Devanagari, Greek, and the rest. Carries no evidence any
    /// signal in this app knows how to read.
    case other
}

/// One language the speech engine can be asked for.
///
/// A struct over a code rather than an enum of four cases, since Phase 7: the
/// engine knows a hundred languages and the user chooses which of them they
/// speak. `LanguageCatalog` is the closed list behind it — `init?(rawValue:)`
/// refuses anything not in it, so a `SpeechLanguage` is always a language the
/// decoder can actually be pinned to, and `displayName` never has to invent a
/// name for a code nobody recognizes.
struct SpeechLanguage: RawRepresentable, Sendable, Hashable, Identifiable, Comparable {
    let rawValue: String

    /// Fails for a code the engine does not know.
    init?(rawValue: String) {
        guard LanguageCatalog.byCode[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    /// For the languages this file names itself, where the code is known good.
    private init(known code: String) {
        rawValue = code
    }

    var id: String { rawValue }

    private var entry: LanguageCatalog.Entry {
        // Unwrapped rather than defaulted: the only initializer that reaches
        // the outside world checks the catalog, so a missing entry here would
        // mean this type was constructed around the check.
        LanguageCatalog.byCode[rawValue]!
    }

    /// The name shown in an English interface.
    var displayName: String { entry.englishName }
    /// The name the language calls itself.
    var nativeName: String { entry.nativeName }
    var script: LanguageScript { entry.script }

    /// Whether recognition, cleanup, and every risk signal are measured for
    /// this language, as opposed to recognition alone. `docs/PHASE_7.md`.
    var isVerified: Bool { LanguageCatalog.verifiedCodes.contains(rawValue) }

    /// Whether the language capitalizes every noun, which is what makes a
    /// capital letter mid-sentence worthless as evidence of a name.
    var capitalizesNouns: Bool { LanguageCatalog.nounCapitalizingCodes.contains(rawValue) }

    /// Cyrillic-script languages need different text normalization in the
    /// benchmark scorer than Latin-script ones.
    var usesCyrillicScript: Bool { script == .cyrillic }

    /// BCP-47 tag for engines that want a locale rather than a bare language
    /// code. Only the verified four carry a region, because only for those does
    /// this product know which region it means; everything else is the bare
    /// code, which `Locale` accepts.
    var localeIdentifier: String {
        switch rawValue {
        case "de": "de-DE"
        case "en": "en-US"
        case "ru": "ru-RU"
        case "uk": "uk-UA"
        default: rawValue
        }
    }

    static func < (lhs: SpeechLanguage, rhs: SpeechLanguage) -> Bool {
        (lhs.displayName, lhs.rawValue) < (rhs.displayName, rhs.rawValue)
    }

    // MARK: - The verified four

    static let german = SpeechLanguage(known: "de")
    static let english = SpeechLanguage(known: "en")
    static let russian = SpeechLanguage(known: "ru")
    static let ukrainian = SpeechLanguage(known: "uk")

    /// The verified tier, in the order the picker shows it.
    static let verified: [SpeechLanguage] = LanguageCatalog.all
        .filter { LanguageCatalog.verifiedCodes.contains($0.code) }
        .map { SpeechLanguage(known: $0.code) }

    /// Every language the engine knows, sorted by English name.
    static let all: [SpeechLanguage] = LanguageCatalog.all.map { SpeechLanguage(known: $0.code) }
}

/// Encoded as the bare code — `"de"`, not `{"rawValue": "de"}`.
///
/// The glossary and the settings file have held plain codes since Phase 3, and
/// a struct that encoded itself as an object would silently orphan every term
/// a user has already saved.
extension SpeechLanguage: Codable {
    init(from decoder: any Decoder) throws {
        let code = try decoder.singleValueContainer().decode(String.self)
        guard let language = SpeechLanguage(rawValue: code) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "\(code) is not a language the speech engine knows"
                )
            )
        }
        self = language
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
