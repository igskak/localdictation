import Foundation

/// The text categories the product promises to protect.
///
/// Promoted out of `Benchmark/` in Phase 3: the same definition now selects
/// what the benchmark scores *and* what the risk engine marks. Two definitions
/// would let the engine mark one thing while the measurement graded another.
///
/// Every rule here is a fact about the characters, not a probability. "This
/// contains a digit" cannot be wrong the way a confidence score can, which is
/// why `docs/PHASE_3.md` puts these signals first and model confidence last.
enum CriticalTokens {
    enum Category: String, Sendable, Equatable, CaseIterable {
        case number
        case currency
        case date
    }

    private static let currencySymbols: Set<Character> = ["€", "$", "£", "₴", "₽", "¥"]

    static func containsDigit(_ word: String) -> Bool {
        word.contains { $0.isNumber }
    }

    static func isCurrency(_ word: String) -> Bool {
        isCurrency(word, language: nil)
    }

    static func isCurrency(_ word: String, language: SpeechLanguage) -> Bool {
        isCurrency(word, language: Optional(language))
    }

    /// Digits, currency, and the spelled-out number words calibrated for the
    /// selected language — fragments that turn a good transcript into a silent error.
    static func isNumeric(_ word: String) -> Bool {
        isNumeric(word, language: nil)
    }

    static func isNumeric(_ word: String, language: SpeechLanguage) -> Bool {
        isNumeric(word, language: Optional(language))
    }

    /// Month names, weekday names, and the ordinals used to speak a day of the
    /// month. A wrong date reads as fluently as a right one.
    ///
    /// An ordinal needs its neighbours to mean a date. "den zweiten Absatz" and
    /// "the second paragraph" are ordinary writing, and marking them as dates
    /// was found on ordinary prose in Phase 4 — a mark with a reason the user
    /// reads as nonsense is worse than no mark, because it is the thing that
    /// teaches people to dismiss the review.
    ///
    /// So a bare ordinal is a date only when something says it is: a month
    /// beside it, or a preposition that introduces one. Months and weekdays
    /// need nothing — they are dates on their own.
    static func isDate(_ word: String, precededBy previous: [String] = [], followedBy next: [String] = []) -> Bool {
        isDate(word, language: nil, precededBy: previous, followedBy: next)
    }

    static func isDate(
        _ word: String,
        language: SpeechLanguage,
        precededBy previous: [String] = [],
        followedBy next: [String] = []
    ) -> Bool {
        isDate(word, language: Optional(language), precededBy: previous, followedBy: next)
    }

    private static func isDate(
        _ word: String,
        language: SpeechLanguage?,
        precededBy previous: [String],
        followedBy next: [String]
    ) -> Bool {
        let lowercased = word.lowercased()
        if contains(lowercased, in: monthWords, language: language)
            || contains(lowercased, in: weekdayWords, language: language) { return true }
        guard contains(lowercased, in: ordinalWords, language: language) else { return false }
        if (previous + next).contains(where: { contains($0.lowercased(), in: monthWords, language: language) }) { return true }
        return previous.contains { contains($0.lowercased(), in: dateMarkerWords, language: language) }
    }

    static func isCritical(_ word: String, precededBy previous: [String] = [], followedBy next: [String] = []) -> Bool {
        isNumeric(word) || isDate(word, precededBy: previous, followedBy: next)
    }

    static func isCritical(
        _ word: String,
        language: SpeechLanguage,
        precededBy previous: [String] = [],
        followedBy next: [String] = []
    ) -> Bool {
        isNumeric(word, language: language)
            || isDate(word, language: language, precededBy: previous, followedBy: next)
    }

    /// The most specific category that applies, or `nil` for ordinary words.
    /// Currency wins over bare number, and a month name is a date even though
    /// "March third" also contains an ordinal.
    static func category(
        of word: String,
        precededBy previous: [String] = [],
        followedBy next: [String] = []
    ) -> Category? {
        category(of: word, language: nil, precededBy: previous, followedBy: next)
    }

    static func category(
        of word: String,
        language: SpeechLanguage,
        precededBy previous: [String] = [],
        followedBy next: [String] = []
    ) -> Category? {
        category(of: word, language: Optional(language), precededBy: previous, followedBy: next)
    }

    private static func category(
        of word: String,
        language: SpeechLanguage?,
        precededBy previous: [String],
        followedBy next: [String]
    ) -> Category? {
        if isCurrency(word, language: language) { return .currency }
        if isDate(word, language: language, precededBy: previous, followedBy: next) { return .date }
        if isNumeric(word, language: language) { return .number }
        return nil
    }

    private static func isCurrency(_ word: String, language: SpeechLanguage?) -> Bool {
        // Currency words are intentionally universal: amounts often keep the
        // buyer's currency name when the surrounding sentence changes
        // language (for example Russian text containing Ukrainian “гривень”).
        // The per-language boundary is needed for ordinary-looking number and
        // date words, not for this narrow financial vocabulary.
        _ = language
        return word.contains { currencySymbols.contains($0) }
            || contains(word.lowercased(), in: currencyWords, language: nil)
    }

    private static func isNumeric(_ word: String, language: SpeechLanguage?) -> Bool {
        containsDigit(word)
            || isCurrency(word, language: language)
            || contains(word.lowercased(), in: numberWords, language: language)
    }

    private static func contains(
        _ word: String,
        in vocabulary: [SpeechLanguage: Set<String>],
        language: SpeechLanguage?
    ) -> Bool {
        if let language { return vocabulary[language, default: []].contains(word) }
        return vocabulary.values.contains { $0.contains(word) }
    }

    /// How many words on each side decide whether an ordinal is a day.
    static let dateContextWindow = 2

    /// The words that introduce a spoken date, which is how a day of the month
    /// is said without naming the month: "am fünfzehnten", "до пятнадцатого".
    static let dateMarkerWords: [SpeechLanguage: Set<String>] = [
        .german: ["am", "vom", "zum", "bis", "ab", "seit", "nach"],
        .english: ["on", "by", "until", "till", "after", "before", "since"],
        .russian: ["до", "с", "по", "к", "после", "числа"],
        .ukrainian: ["з", "після", "числа"],
        .spanish: ["hasta", "antes", "después", "desde"],
        .italian: ["entro", "prima", "dopo", "dal"],
        .french: ["avant", "après", "depuis", "jusqu'au", "jusqu’au"],
    ]

    static let currencyWords: [SpeechLanguage: Set<String>] = [
        .german: ["euro", "eur", "cent", "cents", "dollar", "dollars", "usd", "pfund", "pound"],
        .english: ["euro", "eur", "cent", "cents", "dollar", "dollars", "usd", "pound"],
        .russian: ["евро", "рублей", "рубль", "рубля", "центов", "долларов"],
        .ukrainian: ["євро", "гривень", "гривня", "гривні", "доларів"],
        .spanish: ["euro", "euros", "eur", "dólar", "dólares"],
        .italian: ["euro", "eur", "dollaro", "dollari"],
        .french: ["euro", "euros", "eur", "dollar", "dollars"],
    ]

    static let numberWords: [SpeechLanguage: Set<String>] = [
        .german: [
            "null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
            "elf", "zwölf", "zwanzig", "dreißig", "vierzig", "fünfzig", "hundert", "tausend", "million",
            "zweitausend", "zweitausendfünfhundert", "fünfhundert",
        ],
        .english: [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million",
        ],
        .russian: [
            "ноль", "один", "одна", "два", "две", "три", "четыре", "пять", "шесть", "семь", "восемь",
            "девять", "десять", "двадцать", "тридцать", "сорок", "пятьдесят", "сто", "двести",
            "пятьсот", "тысяча", "тысячи", "тысяч", "миллион",
        ],
        .ukrainian: [
            "нуль", "одне", "чотири", "п'ять", "шість", "сім", "вісім", "дев'ять",
            "двадцять", "тридцять", "п'ятдесят", "двісті", "п'ятсот", "тисяча", "тисячі", "тисяч", "мільйон",
        ],
        // Articles `un`, `una`, and `une` are deliberately omitted: marking
        // every article would spend the false-warning budget immediately.
        .spanish: [
            "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve", "diez",
            "once", "doce", "veinte", "treinta", "cuarenta", "cincuenta", "cien", "mil", "millón",
        ],
        .italian: [
            "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove", "dieci",
            "undici", "dodici", "venti", "trenta", "quaranta", "cinquanta", "cento", "mille", "milione",
        ],
        // French `cent` is omitted because a bare form is also an English
        // currency word and the measured corpus does not justify guessing.
        .french: [
            "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix",
            "onze", "douze", "vingt", "trente", "quarante", "cinquante", "mille", "million",
        ],
    ]

    /// Weekdays are dates too: "Friday" heard as "Monday" is exactly the class
    /// of error this product exists to surface.
    ///
    /// English and German capitalize them, which is why their absence here was
    /// not merely a gap — the entity heuristic caught them instead and reported
    /// them as people's names.
    ///
    /// Inflected forms are listed because they are how a deadline is actually
    /// spoken: "до пятницы", "до п'ятниці", "bis Freitag".
    static let weekdayWords: [SpeechLanguage: Set<String>] = [
        .german: ["montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonnabend", "sonntag"],
        .english: ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"],
        .russian: [
            "понедельник", "понедельника", "вторник", "вторника", "среда", "среду", "среды",
            "четверг", "четверга", "пятница", "пятницу", "пятницы",
            "суббота", "субботу", "субботы", "воскресенье", "воскресенья",
        ],
        .ukrainian: [
            "понеділок", "понеділка", "вівторок", "вівторка", "середа", "середу", "середи",
            "четвер", "четверга", "п'ятниця", "п'ятницю", "п'ятниці",
            "субота", "суботу", "суботи", "неділя", "неділю", "неділі",
        ],
        .spanish: ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"],
        .italian: ["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"],
        .french: ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"],
    ]

    static let monthWords: [SpeechLanguage: Set<String>] = [
        .german: ["januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember"],
        .english: ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"],
        // Genitive is how Russian and Ukrainian dates are spoken.
        .russian: ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"],
        .ukrainian: ["січня", "лютого", "березня", "квітня", "травня", "червня", "липня", "серпня", "вересня", "жовтня", "листопада", "грудня"],
        .spanish: ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
        .italian: ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"],
        .french: ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
    ]

    static let ordinalWords: [SpeechLanguage: Set<String>] = [
        .german: ["ersten", "zweiten", "dritten", "vierten", "fünften", "sechsten", "siebten", "achten", "neunten", "zehnten", "elften", "zwölften", "fünfzehnten", "zwanzigsten"],
        .english: ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "fifteenth", "twentieth"],
        .russian: ["первого", "второго", "третьего", "четвёртого", "четвертого", "пятого", "шестого", "седьмого", "восьмого", "девятого", "десятого", "пятнадцатого", "двадцатого"],
        .ukrainian: ["першого", "другого", "третього", "четвертого", "п'ятого", "шостого", "сьомого", "восьмого", "дев'ятого", "десятого", "п'ятнадцятого", "двадцятого"],
        .spanish: ["primero", "segundo", "tercero", "cuarto", "quinto", "sexto", "séptimo", "octavo", "noveno", "décimo", "decimoquinto", "vigésimo"],
        .italian: ["primo", "secondo", "terzo", "quarto", "quinto", "sesto", "settimo", "ottavo", "nono", "decimo", "quindicesimo", "ventesimo"],
        .french: ["premier", "première", "deuxième", "troisième", "quatrième", "cinquième", "sixième", "septième", "huitième", "neuvième", "dixième", "quinzième", "vingtième"],
    ]
}
