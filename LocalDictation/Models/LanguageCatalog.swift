import Foundation

/// Every language the speech engine knows, as data rather than as cases.
///
/// The list is Whisper's own — `WhisperKit.Constants.languages`, deduplicated
/// by code, since that table carries aliases ("castilian" and "mandarin" name
/// languages already in it). Codes are the engine's, not BCP-47's: Whisper
/// spells Javanese `jw` and Cantonese `yue`, and a code this app invented would
/// be a code the decoder refuses.
///
/// English and native names come from `Locale` on macOS, and scripts from
/// `Locale.Language.script`, read once when this table was written rather than
/// at runtime. A generated-then-committed table is a table a test can assert
/// against and a reviewer can read; asking Foundation on every launch would
/// make the app's language list depend on the OS version it runs on.
///
/// Two flags are the product's own and are not derivable from any of that:
/// which languages this product has measured end to end, and which capitalize
/// their nouns.
enum LanguageCatalog {
    struct Entry: Sendable, Equatable, Hashable {
        let code: String
        /// The name shown in an English interface.
        let englishName: String
        /// The name the language calls itself, for a picker someone scans for
        /// their own language rather than for its English spelling.
        let nativeName: String
        let script: LanguageScript

        init(_ code: String, _ englishName: String, _ nativeName: String, _ script: LanguageScript) {
            self.code = code
            self.englishName = englishName
            self.nativeName = nativeName
            self.script = script
        }
    }

    /// The languages this product has a benchmark, cleanup rules, and measured
    /// risk signals for. See `docs/PHASE_7.md` for what the other tier gets.
    static let verifiedCodes: Set<String> = ["de", "en", "ru", "uk"]

    /// Languages that capitalize every noun, not only names.
    ///
    /// The name heuristic in `EntityRiskSignal` reads a capital letter in the
    /// middle of a sentence as evidence of a name, which is worth nothing in a
    /// language where every noun has one.
    static let nounCapitalizingCodes: Set<String> = ["de", "lb"]

    /// Sorted by English name, which is the order the picker shows.
    static let all: [Entry] = [
        Entry("af", "Afrikaans", "Afrikaans", .latin),
        Entry("sq", "Albanian", "shqip", .latin),
        Entry("am", "Amharic", "አማርኛ", .other),
        Entry("ar", "Arabic", "العربية", .other),
        Entry("hy", "Armenian", "հայերեն", .other),
        Entry("as", "Assamese", "অসমীয়া", .other),
        Entry("az", "Azerbaijani", "azərbaycan", .latin),
        Entry("bn", "Bangla", "বাংলা", .other),
        Entry("ba", "Bashkir", "башҡорт", .cyrillic),
        Entry("eu", "Basque", "euskara", .latin),
        Entry("be", "Belarusian", "беларуская", .cyrillic),
        Entry("bs", "Bosnian", "bosanski", .latin),
        Entry("br", "Breton", "brezhoneg", .latin),
        Entry("bg", "Bulgarian", "български", .cyrillic),
        Entry("my", "Burmese", "မြန်မာ", .other),
        Entry("yue", "Cantonese", "廣東話", .other),
        Entry("ca", "Catalan", "català", .latin),
        Entry("zh", "Chinese", "中文", .other),
        Entry("hr", "Croatian", "hrvatski", .latin),
        Entry("cs", "Czech", "čeština", .latin),
        Entry("da", "Danish", "dansk", .latin),
        Entry("nl", "Dutch", "Nederlands", .latin),
        Entry("en", "English", "English", .latin),
        Entry("et", "Estonian", "eesti", .latin),
        Entry("fo", "Faroese", "føroyskt", .latin),
        Entry("fi", "Finnish", "suomi", .latin),
        Entry("fr", "French", "français", .latin),
        Entry("gl", "Galician", "galego", .latin),
        Entry("ka", "Georgian", "ქართული", .other),
        Entry("de", "German", "Deutsch", .latin),
        Entry("el", "Greek", "Ελληνικά", .other),
        Entry("gu", "Gujarati", "ગુજરાતી", .other),
        Entry("ht", "Haitian Creole", "Kreyòl Ayisyen", .latin),
        Entry("ha", "Hausa", "Hausa", .latin),
        Entry("haw", "Hawaiian", "ʻŌlelo Hawaiʻi", .latin),
        Entry("he", "Hebrew", "עברית", .other),
        Entry("hi", "Hindi", "हिन्दी", .other),
        Entry("hu", "Hungarian", "magyar", .latin),
        Entry("is", "Icelandic", "íslenska", .latin),
        Entry("id", "Indonesian", "Indonesia", .latin),
        Entry("it", "Italian", "italiano", .latin),
        Entry("ja", "Japanese", "日本語", .other),
        Entry("jw", "Javanese", "Jawa", .latin),
        Entry("kn", "Kannada", "ಕನ್ನಡ", .other),
        Entry("kk", "Kazakh", "қазақ тілі", .cyrillic),
        Entry("km", "Khmer", "ខ្មែរ", .other),
        Entry("ko", "Korean", "한국어", .other),
        Entry("lo", "Lao", "ລາວ", .other),
        Entry("la", "Latin", "Latin", .latin),
        Entry("lv", "Latvian", "latviešu", .latin),
        Entry("ln", "Lingala", "lingála", .latin),
        Entry("lt", "Lithuanian", "lietuvių", .latin),
        Entry("lb", "Luxembourgish", "Lëtzebuergesch", .latin),
        Entry("mk", "Macedonian", "македонски", .cyrillic),
        Entry("mg", "Malagasy", "Malagasy", .latin),
        Entry("ms", "Malay", "Bahasa Melayu", .latin),
        Entry("ml", "Malayalam", "മലയാളം", .other),
        Entry("mt", "Maltese", "Malti", .latin),
        Entry("mr", "Marathi", "मराठी", .other),
        Entry("mn", "Mongolian", "монгол", .cyrillic),
        Entry("mi", "Māori", "Māori", .latin),
        Entry("ne", "Nepali", "नेपाली", .other),
        Entry("no", "Norwegian", "norsk", .latin),
        Entry("nn", "Norwegian Nynorsk", "norsk nynorsk", .latin),
        Entry("oc", "Occitan", "occitan", .latin),
        Entry("ps", "Pashto", "پښتو", .other),
        Entry("fa", "Persian", "فارسی", .other),
        Entry("pl", "Polish", "polski", .latin),
        Entry("pt", "Portuguese", "português", .latin),
        Entry("pa", "Punjabi", "ਪੰਜਾਬੀ", .other),
        Entry("ro", "Romanian", "română", .latin),
        Entry("ru", "Russian", "русский", .cyrillic),
        Entry("sa", "Sanskrit", "संस्कृत भाषा", .other),
        Entry("sr", "Serbian", "српски", .cyrillic),
        Entry("sn", "Shona", "chiShona", .latin),
        Entry("sd", "Sindhi", "سنڌي", .other),
        Entry("si", "Sinhala", "සිංහල", .other),
        Entry("sk", "Slovak", "slovenčina", .latin),
        Entry("sl", "Slovenian", "slovenščina", .latin),
        Entry("so", "Somali", "Soomaali", .latin),
        Entry("es", "Spanish", "español", .latin),
        Entry("su", "Sundanese", "Basa Sunda", .latin),
        Entry("sw", "Swahili", "Kiswahili", .latin),
        Entry("sv", "Swedish", "svenska", .latin),
        Entry("tl", "Tagalog", "Tagalog", .latin),
        Entry("tg", "Tajik", "тоҷикӣ", .cyrillic),
        Entry("ta", "Tamil", "தமிழ்", .other),
        Entry("tt", "Tatar", "татар", .cyrillic),
        Entry("te", "Telugu", "తెలుగు", .other),
        Entry("th", "Thai", "ไทย", .other),
        Entry("bo", "Tibetan", "བོད་སྐད་", .other),
        Entry("tr", "Turkish", "Türkçe", .latin),
        Entry("tk", "Turkmen", "türkmen dili", .latin),
        Entry("uk", "Ukrainian", "українська", .cyrillic),
        Entry("ur", "Urdu", "اردو", .other),
        Entry("uz", "Uzbek", "o‘zbek", .latin),
        Entry("vi", "Vietnamese", "Tiếng Việt", .latin),
        Entry("cy", "Welsh", "Cymraeg", .latin),
        Entry("yi", "Yiddish", "ייִדיש", .other),
        Entry("yo", "Yoruba", "Èdè Yorùbá", .latin),
    ]

    static let byCode: [String: Entry] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
}
