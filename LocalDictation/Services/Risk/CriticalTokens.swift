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
        word.contains { currencySymbols.contains($0) } || currencyWords.contains(word.lowercased())
    }

    /// Digits, currency, and the spelled-out number words of the four supported
    /// languages — the fragments that turn a good transcript into a silent error.
    static func isNumeric(_ word: String) -> Bool {
        containsDigit(word) || isCurrency(word) || numberWords.contains(word.lowercased())
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
        let lowercased = word.lowercased()
        if monthWords.contains(lowercased) || weekdayWords.contains(lowercased) { return true }
        guard ordinalWords.contains(lowercased) else { return false }
        if (previous + next).contains(where: { monthWords.contains($0.lowercased()) }) { return true }
        return previous.contains { dateMarkerWords.contains($0.lowercased()) }
    }

    static func isCritical(_ word: String, precededBy previous: [String] = [], followedBy next: [String] = []) -> Bool {
        isNumeric(word) || isDate(word, precededBy: previous, followedBy: next)
    }

    /// The most specific category that applies, or `nil` for ordinary words.
    /// Currency wins over bare number, and a month name is a date even though
    /// "March third" also contains an ordinal.
    static func category(
        of word: String,
        precededBy previous: [String] = [],
        followedBy next: [String] = []
    ) -> Category? {
        if isCurrency(word) { return .currency }
        if isDate(word, precededBy: previous, followedBy: next) { return .date }
        if isNumeric(word) { return .number }
        return nil
    }

    /// How many words on each side decide whether an ordinal is a day.
    static let dateContextWindow = 2

    /// The words that introduce a spoken date, which is how a day of the month
    /// is said without naming the month: "am fünfzehnten", "до пятнадцатого".
    static let dateMarkerWords: Set<String> = [
        // German
        "am", "vom", "zum", "bis", "ab", "seit", "nach",
        // English
        "on", "by", "until", "till", "after", "before", "since",
        // Russian
        "до", "с", "по", "к", "после", "числа",
        // Ukrainian
        "з", "після", "числа",
    ]

    static let currencyWords: Set<String> = [
        "euro", "eur", "cent", "cents", "dollar", "dollars", "usd", "pfund", "pound",
        "евро", "євро", "гривень", "гривня", "гривні", "рублей", "рубль", "рубля",
        "центов", "долларов", "доларів",
    ]

    static let numberWords: Set<String> = [
        // German
        "null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
        "elf", "zwölf", "zwanzig", "dreißig", "vierzig", "fünfzig", "hundert", "tausend", "million",
        "zweitausend", "zweitausendfünfhundert", "fünfhundert",
        // English
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "twenty", "thirty", "forty", "fifty", "hundred", "thousand", "million",
        // Russian
        "ноль", "один", "одна", "два", "две", "три", "четыре", "пять", "шесть", "семь", "восемь",
        "девять", "десять", "двадцать", "тридцать", "сорок", "пятьдесят", "сто", "двести",
        "пятьсот", "тысяча", "тысячи", "тысяч", "миллион",
        // Ukrainian
        "нуль", "одне", "чотири", "п'ять", "шість", "сім", "вісім", "дев'ять",
        "двадцять", "тридцять", "п'ятдесят", "двісті", "п'ятсот", "тисяча", "тисячі", "тисяч",
        "мільйон",
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
    static let weekdayWords: Set<String> = [
        // German
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag",
        "sonnabend", "sonntag",
        // English
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        // Russian
        "понедельник", "понедельника", "вторник", "вторника", "среда", "среду", "среды",
        "четверг", "четверга", "пятница", "пятницу", "пятницы",
        "суббота", "субботу", "субботы", "воскресенье", "воскресенья",
        // Ukrainian
        "понеділок", "понеділка", "вівторок", "вівторка", "середа", "середу", "середи",
        "четвер", "четверга", "п'ятниця", "п'ятницю", "п'ятниці",
        "субота", "суботу", "суботи", "неділя", "неділю", "неділі",
    ]

    static let monthWords: Set<String> = [
        // German
        "januar", "februar", "märz", "april", "mai", "juni", "juli",
        "august", "september", "oktober", "november", "dezember",
        // English
        "january", "february", "march", "may", "june", "july", "october", "december",
        // Russian (genitive is how a date is spoken: "третьего марта")
        "января", "февраля", "марта", "апреля", "мая", "июня", "июля",
        "августа", "сентября", "октября", "ноября", "декабря",
        // Ukrainian
        "січня", "лютого", "березня", "квітня", "травня", "червня", "липня",
        "серпня", "вересня", "жовтня", "листопада", "грудня",
    ]

    static let ordinalWords: Set<String> = [
        // German
        "ersten", "zweiten", "dritten", "vierten", "fünften", "sechsten", "siebten",
        "achten", "neunten", "zehnten", "elften", "zwölften", "fünfzehnten", "zwanzigsten",
        // English
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        "ninth", "tenth", "fifteenth", "twentieth",
        // Russian
        "первого", "второго", "третьего", "четвёртого", "четвертого", "пятого", "шестого",
        "седьмого", "восьмого", "девятого", "десятого", "пятнадцатого", "двадцатого",
        // Ukrainian
        "першого", "другого", "третього", "четвертого", "п'ятого", "шостого", "сьомого",
        "восьмого", "дев'ятого", "десятого", "п'ятнадцятого", "двадцятого",
    ]
}
