namespace Witness.Core.Languages;

public enum LanguageScript
{
    Latin,
    Cyrillic,
    Other,
}

public readonly record struct SpeechLanguage(string Code)
{
    public static SpeechLanguage German { get; } = new("de");
    public static SpeechLanguage English { get; } = new("en");
    public static SpeechLanguage Russian { get; } = new("ru");
    public static SpeechLanguage Ukrainian { get; } = new("uk");

    public bool IsVerified => LanguageCatalog.VerifiedCodes.Contains(Code);
    public bool CapitalizesNouns => LanguageCatalog.NounCapitalizingCodes.Contains(Code);
    public LanguageScript Script => LanguageCatalog.ByCode.TryGetValue(Code, out var entry) ? entry.Script : LanguageScript.Other;

    public static bool TryCreate(string code, out SpeechLanguage language)
    {
        if (LanguageCatalog.ByCode.ContainsKey(code))
        {
            language = new SpeechLanguage(code);
            return true;
        }
        language = default;
        return false;
    }

    public override string ToString() => Code;
}

public sealed record LanguageEntry(string Code, string EnglishName, string NativeName, LanguageScript Script);

public static class LanguageCatalog
{
    public static IReadOnlySet<string> VerifiedCodes { get; } = new HashSet<string>(["de", "en", "ru", "uk"], StringComparer.Ordinal);
    public static IReadOnlySet<string> NounCapitalizingCodes { get; } = new HashSet<string>(["de", "lb"], StringComparer.Ordinal);

    public static IReadOnlyList<LanguageEntry> All { get; } =
    [
        new("af", "Afrikaans", "Afrikaans", LanguageScript.Latin),
        new("sq", "Albanian", "shqip", LanguageScript.Latin),
        new("am", "Amharic", "አማርኛ", LanguageScript.Other),
        new("ar", "Arabic", "العربية", LanguageScript.Other),
        new("hy", "Armenian", "հայերեն", LanguageScript.Other),
        new("as", "Assamese", "অসমীয়া", LanguageScript.Other),
        new("az", "Azerbaijani", "azərbaycan", LanguageScript.Latin),
        new("bn", "Bangla", "বাংলা", LanguageScript.Other),
        new("ba", "Bashkir", "башҡорт", LanguageScript.Cyrillic),
        new("eu", "Basque", "euskara", LanguageScript.Latin),
        new("be", "Belarusian", "беларуская", LanguageScript.Cyrillic),
        new("bs", "Bosnian", "bosanski", LanguageScript.Latin),
        new("br", "Breton", "brezhoneg", LanguageScript.Latin),
        new("bg", "Bulgarian", "български", LanguageScript.Cyrillic),
        new("my", "Burmese", "မြန်မာ", LanguageScript.Other),
        new("yue", "Cantonese", "廣東話", LanguageScript.Other),
        new("ca", "Catalan", "català", LanguageScript.Latin),
        new("zh", "Chinese", "中文", LanguageScript.Other),
        new("hr", "Croatian", "hrvatski", LanguageScript.Latin),
        new("cs", "Czech", "čeština", LanguageScript.Latin),
        new("da", "Danish", "dansk", LanguageScript.Latin),
        new("nl", "Dutch", "Nederlands", LanguageScript.Latin),
        new("en", "English", "English", LanguageScript.Latin),
        new("et", "Estonian", "eesti", LanguageScript.Latin),
        new("fo", "Faroese", "føroyskt", LanguageScript.Latin),
        new("fi", "Finnish", "suomi", LanguageScript.Latin),
        new("fr", "French", "français", LanguageScript.Latin),
        new("gl", "Galician", "galego", LanguageScript.Latin),
        new("ka", "Georgian", "ქართული", LanguageScript.Other),
        new("de", "German", "Deutsch", LanguageScript.Latin),
        new("el", "Greek", "Ελληνικά", LanguageScript.Other),
        new("gu", "Gujarati", "ગુજરાતી", LanguageScript.Other),
        new("ht", "Haitian Creole", "Kreyòl Ayisyen", LanguageScript.Latin),
        new("ha", "Hausa", "Hausa", LanguageScript.Latin),
        new("haw", "Hawaiian", "ʻŌlelo Hawaiʻi", LanguageScript.Latin),
        new("he", "Hebrew", "עברית", LanguageScript.Other),
        new("hi", "Hindi", "हिन्दी", LanguageScript.Other),
        new("hu", "Hungarian", "magyar", LanguageScript.Latin),
        new("is", "Icelandic", "íslenska", LanguageScript.Latin),
        new("id", "Indonesian", "Indonesia", LanguageScript.Latin),
        new("it", "Italian", "italiano", LanguageScript.Latin),
        new("ja", "Japanese", "日本語", LanguageScript.Other),
        new("jw", "Javanese", "Jawa", LanguageScript.Latin),
        new("kn", "Kannada", "ಕನ್ನಡ", LanguageScript.Other),
        new("kk", "Kazakh", "қазақ тілі", LanguageScript.Cyrillic),
        new("km", "Khmer", "ខ្មែរ", LanguageScript.Other),
        new("ko", "Korean", "한국어", LanguageScript.Other),
        new("lo", "Lao", "ລາວ", LanguageScript.Other),
        new("la", "Latin", "Latin", LanguageScript.Latin),
        new("lv", "Latvian", "latviešu", LanguageScript.Latin),
        new("ln", "Lingala", "lingála", LanguageScript.Latin),
        new("lt", "Lithuanian", "lietuvių", LanguageScript.Latin),
        new("lb", "Luxembourgish", "Lëtzebuergesch", LanguageScript.Latin),
        new("mk", "Macedonian", "македонски", LanguageScript.Cyrillic),
        new("mg", "Malagasy", "Malagasy", LanguageScript.Latin),
        new("ms", "Malay", "Bahasa Melayu", LanguageScript.Latin),
        new("ml", "Malayalam", "മലയാളം", LanguageScript.Other),
        new("mt", "Maltese", "Malti", LanguageScript.Latin),
        new("mr", "Marathi", "मराठी", LanguageScript.Other),
        new("mn", "Mongolian", "монгол", LanguageScript.Cyrillic),
        new("mi", "Māori", "Māori", LanguageScript.Latin),
        new("ne", "Nepali", "नेपाली", LanguageScript.Other),
        new("no", "Norwegian", "norsk", LanguageScript.Latin),
        new("nn", "Norwegian Nynorsk", "norsk nynorsk", LanguageScript.Latin),
        new("oc", "Occitan", "occitan", LanguageScript.Latin),
        new("ps", "Pashto", "پښتو", LanguageScript.Other),
        new("fa", "Persian", "فارسی", LanguageScript.Other),
        new("pl", "Polish", "polski", LanguageScript.Latin),
        new("pt", "Portuguese", "português", LanguageScript.Latin),
        new("pa", "Punjabi", "ਪੰਜਾਬੀ", LanguageScript.Other),
        new("ro", "Romanian", "română", LanguageScript.Latin),
        new("ru", "Russian", "русский", LanguageScript.Cyrillic),
        new("sa", "Sanskrit", "संस्कृत भाषा", LanguageScript.Other),
        new("sr", "Serbian", "српски", LanguageScript.Cyrillic),
        new("sn", "Shona", "chiShona", LanguageScript.Latin),
        new("sd", "Sindhi", "سنڌي", LanguageScript.Other),
        new("si", "Sinhala", "සිංහල", LanguageScript.Other),
        new("sk", "Slovak", "slovenčina", LanguageScript.Latin),
        new("sl", "Slovenian", "slovenščina", LanguageScript.Latin),
        new("so", "Somali", "Soomaali", LanguageScript.Latin),
        new("es", "Spanish", "español", LanguageScript.Latin),
        new("su", "Sundanese", "Basa Sunda", LanguageScript.Latin),
        new("sw", "Swahili", "Kiswahili", LanguageScript.Latin),
        new("sv", "Swedish", "svenska", LanguageScript.Latin),
        new("tl", "Tagalog", "Tagalog", LanguageScript.Latin),
        new("tg", "Tajik", "тоҷикӣ", LanguageScript.Cyrillic),
        new("ta", "Tamil", "தமிழ்", LanguageScript.Other),
        new("tt", "Tatar", "татар", LanguageScript.Cyrillic),
        new("te", "Telugu", "తెలుగు", LanguageScript.Other),
        new("th", "Thai", "ไทย", LanguageScript.Other),
        new("bo", "Tibetan", "བོད་སྐད་", LanguageScript.Other),
        new("tr", "Turkish", "Türkçe", LanguageScript.Latin),
        new("tk", "Turkmen", "türkmen dili", LanguageScript.Latin),
        new("uk", "Ukrainian", "українська", LanguageScript.Cyrillic),
        new("ur", "Urdu", "اردو", LanguageScript.Other),
        new("uz", "Uzbek", "o‘zbek", LanguageScript.Latin),
        new("vi", "Vietnamese", "Tiếng Việt", LanguageScript.Latin),
        new("cy", "Welsh", "Cymraeg", LanguageScript.Latin),
        new("yi", "Yiddish", "ייִדיש", LanguageScript.Other),
        new("yo", "Yoruba", "Èdè Yorùbá", LanguageScript.Latin),
    ];

    public static IReadOnlyDictionary<string, LanguageEntry> ByCode { get; } = All.ToDictionary(entry => entry.Code, StringComparer.Ordinal);
}
