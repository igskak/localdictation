import Foundation

/// The languages the user speaks, in the order that matters to them.
///
/// Through Phase 6 this was a primary language and an optional second one,
/// chosen from eight combinations the product had decided in advance. Since
/// Phase 7 it is an ordered, deduplicated, non-empty set drawn from every
/// language the engine knows: a user who speaks three says three, and a user
/// who speaks one says one.
///
/// Order is not cosmetic. The first language is **preferred** — the fallback
/// when the engine has no opinion about an utterance, and the tie-break when it
/// has two. Everything else about the set is unordered in meaning.
///
/// The type still answers `primary`, `isMixed`, `contains`, `displayName`, and
/// `shortLabel` the way it always did, because the risk engine, the glossary,
/// the transcript, and the benchmark ask it those questions and none of them
/// needed to learn a new vocabulary for this change.
struct LanguageProfile: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// Never empty, never duplicated, ordered with the preferred language first.
    private(set) var languages: [SpeechLanguage]

    /// The only initializer that cannot produce an empty profile, which is why
    /// it is the one everything else funnels through.
    init(_ first: SpeechLanguage, _ rest: SpeechLanguage...) {
        languages = Self.normalized([first] + rest)
    }

    /// Nil for an empty list. A profile naming no language is not a profile the
    /// engine could be asked for, and defaulting silently to something would
    /// pick a language on the user's behalf.
    init?(languages: [SpeechLanguage]) {
        let normalized = Self.normalized(languages)
        guard !normalized.isEmpty else { return nil }
        self.languages = normalized
    }

    /// The Phase 6 shape, kept because a corpus manifest and a good many tests
    /// are written in it.
    init(primary: SpeechLanguage, secondary: SpeechLanguage? = nil) {
        languages = Self.normalized([primary] + (secondary.map { [$0] } ?? []))
    }

    /// Removes duplicates while keeping first appearance, which is what makes
    /// "preferred" survive a user selecting the same language twice.
    private static func normalized(_ languages: [SpeechLanguage]) -> [SpeechLanguage] {
        var seen: Set<SpeechLanguage> = []
        return languages.filter { seen.insert($0).inserted }
    }

    /// The preferred language: the fallback and the tie-break.
    var primary: SpeechLanguage { languages[0] }

    /// Whether the engine has to decide which language an utterance is in.
    var isMixed: Bool { languages.count > 1 }

    /// Codes joined with `+`, which is the shape Phase 2 corpora already use to
    /// name a profile: `de+en`, `ru+en+uk`.
    var id: String { languages.map(\.rawValue).joined(separator: "+") }

    var displayName: String {
        languages.map(\.displayName).joined(separator: " + ")
    }

    /// Short label for compact UI, e.g. "DE+EN".
    var shortLabel: String {
        languages.map { $0.rawValue.uppercased() }.joined(separator: "+")
    }

    func contains(_ language: SpeechLanguage) -> Bool {
        languages.contains(language)
    }

    // MARK: - Editing

    /// The profile with this language added, preferred language unchanged.
    func including(_ language: SpeechLanguage) -> LanguageProfile {
        guard !contains(language) else { return self }
        return LanguageProfile(languages: languages + [language]) ?? self
    }

    /// The profile without this language, or nil when it was the last one.
    ///
    /// Returning nil rather than an empty profile is what lets the picker
    /// refuse the deselection instead of discovering afterwards that the user
    /// has no language at all.
    func excluding(_ language: SpeechLanguage) -> LanguageProfile? {
        LanguageProfile(languages: languages.filter { $0 != language })
    }

    /// The profile with this language first, adding it if it was not selected.
    func preferring(_ language: SpeechLanguage) -> LanguageProfile {
        LanguageProfile(languages: [language] + languages) ?? self
    }

    // MARK: - Single-language profiles

    static let german = LanguageProfile(.german)
    static let english = LanguageProfile(.english)
    static let russian = LanguageProfile(.russian)
    static let ukrainian = LanguageProfile(.ukrainian)

    // MARK: - The combinations Phase 6 shipped

    static let germanEnglish = LanguageProfile(.german, .english)
    static let russianUkrainian = LanguageProfile(.russian, .ukrainian)
    static let russianEnglish = LanguageProfile(.russian, .english)
    static let ukrainianEnglish = LanguageProfile(.ukrainian, .english)

    static let single: [LanguageProfile] = [.german, .english, .russian, .ukrainian]
    static let mixed: [LanguageProfile] = [.germanEnglish, .russianUkrainian, .russianEnglish, .ukrainianEnglish]
    /// The eight the product used to offer. Still what the benchmark corpora
    /// name, and no longer the whole of what a user may choose.
    static let all: [LanguageProfile] = single + mixed

    /// What a first run gets before the user has said anything. The initial
    /// market is Germany; `docs/PHASE_7.md` is what replaces this with an
    /// answer from the person using it.
    static let `default` = LanguageProfile.germanEnglish

    /// Parses an identifier of the `ru+en+uk` shape. Nil when any code is one
    /// the engine does not know, so a hand-edited corpus manifest fails loudly.
    static func profile(id: String) -> LanguageProfile? {
        let codes = id.split(separator: "+").map(String.init)
        guard !codes.isEmpty else { return nil }
        let languages = codes.compactMap(SpeechLanguage.init(rawValue:))
        guard languages.count == codes.count else { return nil }
        return LanguageProfile(languages: languages)
    }
}

/// Encoded as `{"languages": ["ru", "en"]}`, and decoded from either that or
/// the Phase 6 `{"primary": "ru", "secondary": "en"}`.
///
/// Reading the older shape is not politeness. `preferences.json` holds the
/// languages a user chose, and a decoder that did not recognize the file it
/// wrote last week would take that choice away silently — the user would find
/// out by dictating a sentence and getting it back in the wrong language.
extension LanguageProfile {
    private enum CodingKeys: String, CodingKey {
        case languages
        case primary
        case secondary
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let languages = try container.decodeIfPresent([SpeechLanguage].self, forKey: .languages) {
            guard let profile = LanguageProfile(languages: languages) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "A language profile has to name at least one language"
                    )
                )
            }
            self = profile
            return
        }

        let primary = try container.decode(SpeechLanguage.self, forKey: .primary)
        let secondary = try container.decodeIfPresent(SpeechLanguage.self, forKey: .secondary)
        self.init(primary: primary, secondary: secondary)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(languages, forKey: .languages)
    }
}
