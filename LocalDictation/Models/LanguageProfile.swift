import Foundation

/// The MVP speech languages from `docs/PRODUCT_SCOPE.md`.
enum SpeechLanguage: String, CaseIterable, Sendable, Equatable, Codable {
    case german = "de"
    case english = "en"
    case russian = "ru"
    case ukrainian = "uk"

    var displayName: String {
        switch self {
        case .german: "German"
        case .english: "English"
        case .russian: "Russian"
        case .ukrainian: "Ukrainian"
        }
    }

    /// BCP-47 tag for engines that want a locale rather than a bare language code.
    var localeIdentifier: String {
        switch self {
        case .german: "de-DE"
        case .english: "en-US"
        case .russian: "ru-RU"
        case .ukrainian: "uk-UA"
        }
    }

    /// Cyrillic-script languages need different text normalization in the
    /// benchmark scorer than Latin-script ones.
    var usesCyrillicScript: Bool {
        self == .russian || self == .ukrainian
    }
}

/// An explicit, user-selected language profile.
///
/// The product deliberately does not promise arbitrary four-language detection
/// inside a single utterance. A profile names either one language or one of the
/// priority pairs, and that choice is passed to the engine explicitly.
struct LanguageProfile: Sendable, Equatable, Hashable, Identifiable, Codable {
    let primary: SpeechLanguage
    /// Second language of a priority mixed profile, if this is one.
    let secondary: SpeechLanguage?

    var id: String {
        guard let secondary else { return primary.rawValue }
        return "\(primary.rawValue)+\(secondary.rawValue)"
    }

    var isMixed: Bool { secondary != nil }

    var languages: [SpeechLanguage] {
        guard let secondary else { return [primary] }
        return [primary, secondary]
    }

    var displayName: String {
        guard let secondary else { return primary.displayName }
        return "\(primary.displayName) + \(secondary.displayName)"
    }

    /// Short label for compact UI, e.g. "DE+EN".
    var shortLabel: String {
        languages.map { $0.rawValue.uppercased() }.joined(separator: "+")
    }

    func contains(_ language: SpeechLanguage) -> Bool {
        languages.contains(language)
    }

    // MARK: - Single-language profiles

    static let german = LanguageProfile(primary: .german, secondary: nil)
    static let english = LanguageProfile(primary: .english, secondary: nil)
    static let russian = LanguageProfile(primary: .russian, secondary: nil)
    static let ukrainian = LanguageProfile(primary: .ukrainian, secondary: nil)

    // MARK: - Priority mixed profiles

    static let germanEnglish = LanguageProfile(primary: .german, secondary: .english)
    static let russianUkrainian = LanguageProfile(primary: .russian, secondary: .ukrainian)
    static let russianEnglish = LanguageProfile(primary: .russian, secondary: .english)
    static let ukrainianEnglish = LanguageProfile(primary: .ukrainian, secondary: .english)

    static let single: [LanguageProfile] = [.german, .english, .russian, .ukrainian]
    static let mixed: [LanguageProfile] = [.germanEnglish, .russianUkrainian, .russianEnglish, .ukrainianEnglish]
    static let all: [LanguageProfile] = single + mixed

    /// The initial market is Germany, and DE+EN is the first priority pair.
    static let `default` = LanguageProfile.germanEnglish

    static func profile(id: String) -> LanguageProfile? {
        all.first { $0.id == id }
    }
}
