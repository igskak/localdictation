import Foundation

/// Words carrying evidence of a language the profile does not name.
///
/// Profiles are explicit, so this signal has a definite question to answer
/// rather than having to detect language from scratch. It marks only what
/// `LanguageIdentifier` can prove — a script mismatch, or a letter that exists
/// in one language of a pair and not the other — and stays silent otherwise.
/// Half of DE+EN is therefore invisible to it, which is stated rather than
/// papered over with a guess.
struct LanguageSwitchRiskSignal: RiskSignal {
    let identifier = "language"

    func spans(in context: RiskContext) -> [RawRiskSpan] {
        context.words.compactMap { word in
            // Numbers and symbols are script-neutral and carry no evidence.
            guard word.text.contains(where: \.isLetter) else { return nil }

            if !LanguageIdentifier.scriptMatches(word.text, profile: context.profile) {
                // The script is wrong for every language in the profile. Report
                // the language the word looks like when that is knowable, and
                // otherwise attribute it to the script's default member so the
                // reason still names something the user can read.
                let identified = LanguageIdentifier.language(of: word.text)
                    ?? (LanguageIdentifier.script(of: word.text) == .cyrillic ? .russian : .english)
                return RawRiskSpan(reason: .languageSwitch(identified), range: word.range)
            }

            // The letter rules read `ä ö ü ß` as German, `і ї є ґ` as
            // Ukrainian, and `ы ъ э ё` as Russian, which is exact among the
            // four languages they were written for and wrong the moment a
            // fifth is selected: Swedish `för` is not a German word, and
            // Bulgarian is full of `ъ`. Where the profile names a language
            // this product has not measured, the script mismatch above is all
            // the evidence there is, and this signal says nothing rather than
            // something it cannot support.
            guard context.profile.languages.allSatisfy(\.isVerified) else { return nil }
            guard let identified = LanguageIdentifier.language(of: word.text) else { return nil }
            guard identified != context.language else { return nil }
            return RawRiskSpan(reason: .languageSwitch(identified), range: word.range)
        }
    }
}
