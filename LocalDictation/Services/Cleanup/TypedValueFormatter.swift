import Foundation

struct TypedValueFormatter: Sendable {
    struct Parsed: Sendable, Equatable {
        let range: Range<Int>
        let rendered: String
        let record: TypedValueRecord
        let kind: TextEdit.Kind
    }

    private struct Lexicon {
        let values: [String: Int]
        let tens: [String: Int]
        let hundred: Set<String>
        let thousand: Set<String>
        let percent: Set<String>
        let currencies: [String: String]
        let units: [String: String]
        let timePrepositions: Set<String>
        let months: [String: Int]
        let ordinals: [String: Int]
    }

    func transform(_ text: String, language: SpeechLanguage, protected: [ProtectedSpan]) -> CleanupResult {
        guard let lexicon = Self.lexicons[language] else { return .unchanged(text, language: language) }
        let words = WordScanner.words(in: text)
        var parsed: [Parsed] = []
        parsed += parseDates(words, language: language, lexicon: lexicon)
        parsed += parseTimes(words, lexicon: lexicon)
        parsed += parseQualifiedNumbers(words, language: language, lexicon: lexicon)
        parsed += parseCardinals(words, lexicon: lexicon)
        parsed.sort {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            if $0.range.count != $1.range.count { return $0.range.count > $1.range.count }
            return priority($0.kind) < priority($1.kind)
        }
        let source = Array(text)
        var replacements: [CleanupReplacement] = []
        for value in parsed where !replacements.contains(where: { $0.range.overlaps(value.range) || $0.range == value.range }) {
            guard !String(source[value.range]).contains(where: { $0 == "\n" || $0 == "\r" }) else { continue }
            let conflicts = protected.filter { $0.range.overlaps(value.range) || $0.range == value.range }
            guard conflicts.allSatisfy({ value.range.lowerBound <= $0.range.lowerBound && value.range.upperBound >= $0.range.upperBound }) else {
                continue
            }
            replacements.append(
                .init(range: value.range, text: value.rendered, kind: value.kind, typedValue: value.record)
            )
        }
        return CleanupTransformation.apply(replacements, to: text, language: language)
    }

    private func priority(_ kind: TextEdit.Kind) -> Int {
        switch kind {
        case .dateFormatting: 0
        case .timeFormatting: 1
        case .currencyFormatting, .percentageFormatting, .unitFormatting: 2
        case .numberFormatting: 3
        default: 4
        }
    }

    func parseRendered(_ text: String, category: TypedValueRecord.Category) -> String? {
        switch category {
        case .number: return Int(text).map(String.init)
        case .percentage: return Int(text.dropLast(text.hasSuffix("%") ? 1 : 0)).map { "\($0)%" }
        case .time:
            let parts = text.split(separator: ":"); guard parts.count == 2,
                let hour = Int(parts[0]), let minute = Int(parts[1]), hour < 24, minute < 60 else { return nil }
            return String(format: "%02d:%02d", hour, minute)
        case .currency:
            guard let symbol = text.first(where: { "$€£₽₴".contains($0) }),
                  let value = Int(text.filter(\.isNumber)) else { return nil }
            return "\(value):\(symbol)"
        case .unit:
            let parts = text.split(separator: " ")
            guard parts.count == 2, let value = Int(parts[0]) else { return nil }
            return "\(value):\(parts[1])"
        case .date:
            let folded = text.lowercased().replacingOccurrences(of: ".", with: "")
            guard let day = folded.split(separator: " ").compactMap({ Int($0) }).first else { return nil }
            for (language, lexicon) in Self.lexicons {
                if let month = lexicon.months.first(where: { folded.contains($0.key) })?.value {
                    _ = language
                    return String(format: "%02d-%02d", month, day)
                }
            }
            return nil
        }
    }

    private func parseCardinals(_ words: [TextWord], lexicon: Lexicon) -> [Parsed] {
        var results: [Parsed] = []
        var index = 0
        while index < words.count {
            // A run of simple number words is commonly a dictated identifier
            // (phone, account, or product number). Keep it literal rather than
            // guessing that adjacent digits should be added together.
            if lexicon.values[words[index].lowercased] != nil,
               index + 1 < words.count,
               lexicon.values[words[index + 1].lowercased] != nil {
                repeat { index += 1 }
                while index < words.count && lexicon.values[words[index].lowercased] != nil
                continue
            }
            guard !words[index].text.contains(where: \.isNumber),
                  let (value, end) = parseNumber(words, from: index, lexicon: lexicon), end > index
            else { index += 1; continue }
            let range = words[index].range.lowerBound..<words[end - 1].range.upperBound
            results.append(.init(range: range, rendered: String(value), record: .init(category: .number, canonicalValue: String(value)), kind: .numberFormatting))
            index = end
        }
        return results
    }

    private func parseQualifiedNumbers(_ words: [TextWord], language: SpeechLanguage, lexicon: Lexicon) -> [Parsed] {
        var results: [Parsed] = []
        for start in words.indices {
            guard let (value, end) = parseNumber(words, from: start, lexicon: lexicon), end < words.count else { continue }
            let qualifier = words[end].lowercased
            let range = words[start].range.lowerBound..<words[end].range.upperBound
            if lexicon.percent.contains(qualifier) {
                let rendered = "\(value)%"
                results.append(.init(range: range, rendered: rendered, record: .init(category: .percentage, canonicalValue: rendered), kind: .percentageFormatting))
            } else if let symbol = lexicon.currencies[qualifier] {
                let rendered = language == .english && symbol == "$" ? "$\(value)" : "\(value) \(symbol)"
                results.append(.init(range: range, rendered: rendered, record: .init(category: .currency, canonicalValue: "\(value):\(symbol)"), kind: .currencyFormatting))
            } else if let unit = lexicon.units[qualifier] {
                let rendered = "\(value) \(unit)"
                results.append(.init(range: range, rendered: rendered, record: .init(category: .unit, canonicalValue: "\(value):\(unit)"), kind: .unitFormatting))
            }
        }
        return results
    }

    private func parseTimes(_ words: [TextWord], lexicon: Lexicon) -> [Parsed] {
        guard words.count >= 3 else { return [] }
        var results: [Parsed] = []
        for index in 1..<(words.count - 1) where lexicon.timePrepositions.contains(words[index - 1].lowercased) {
            guard let hour = simple(words[index].lowercased, lexicon: lexicon),
                  let minute = simple(words[index + 1].lowercased, lexicon: lexicon),
                  (0..<24).contains(hour), (0..<60).contains(minute) else { continue }
            let rendered = String(format: "%02d:%02d", hour, minute)
            results.append(.init(range: words[index].range.lowerBound..<words[index + 1].range.upperBound, rendered: rendered, record: .init(category: .time, canonicalValue: rendered), kind: .timeFormatting))
        }
        return results
    }

    private func parseDates(_ words: [TextWord], language: SpeechLanguage, lexicon: Lexicon) -> [Parsed] {
        guard words.count >= 2 else { return [] }
        var results: [Parsed] = []
        for index in 0..<(words.count - 1) {
            let first = words[index].lowercased, second = words[index + 1].lowercased
            let day: Int?, month: Int?, range: Range<Int>
            if let m = lexicon.months[first], let d = lexicon.ordinals[second] ?? simple(second, lexicon: lexicon) {
                month = m; day = d; range = words[index].range.lowerBound..<words[index + 1].range.upperBound
            } else if let d = lexicon.ordinals[first] ?? simple(first, lexicon: lexicon), let m = lexicon.months[second] {
                day = d; month = m; range = words[index].range.lowerBound..<words[index + 1].range.upperBound
            } else { continue }
            guard let day, let month, (1...31).contains(day) else { continue }
            let canonical = String(format: "%02d-%02d", month, day)
            let rendered = language == .english
                ? "\(Self.monthName(month, language: language)) \(day)"
                : "\(day). \(Self.monthName(month, language: language))"
            results.append(.init(range: range, rendered: rendered, record: .init(category: .date, canonicalValue: canonical), kind: .dateFormatting))
        }
        return results
    }

    private func parseNumber(_ words: [TextWord], from start: Int, lexicon: Lexicon) -> (Int, Int)? {
        var total = 0, group = 0, index = start, consumed = false
        var previousWasSimpleValue = false
        while index < words.count {
            let token = words[index].lowercased
            if let value = lexicon.values[token] {
                guard !previousWasSimpleValue else { break }
                group += value
                previousWasSimpleValue = true
            }
            else if let value = lexicon.tens[token] { group += value; previousWasSimpleValue = false }
            else if lexicon.hundred.contains(token), group > 0 { group *= 100; previousWasSimpleValue = false }
            else if lexicon.thousand.contains(token), group > 0 { total += group * 1_000; group = 0; previousWasSimpleValue = false }
            else { break }
            consumed = true; index += 1
        }
        guard consumed else { return nil }
        return (total + group, index)
    }

    private func simple(_ token: String, lexicon: Lexicon) -> Int? {
        lexicon.values[token] ?? lexicon.tens[token]
    }

    private static func monthName(_ month: Int, language: SpeechLanguage) -> String {
        let names: [SpeechLanguage: [String]] = [
            .english: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
            .german: ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"],
            .russian: ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"],
            .ukrainian: ["січня", "лютого", "березня", "квітня", "травня", "червня", "липня", "серпня", "вересня", "жовтня", "листопада", "грудня"],
        ]
        return names[language]?[month - 1] ?? String(month)
    }

    private static let lexicons: [SpeechLanguage: Lexicon] = [
        .english: .init(values: ["zero":0,"one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,"eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12,"thirteen":13,"fourteen":14,"fifteen":15,"sixteen":16,"seventeen":17,"eighteen":18,"nineteen":19], tens: ["twenty":20,"thirty":30,"forty":40,"fifty":50,"sixty":60,"seventy":70,"eighty":80,"ninety":90], hundred:["hundred"], thousand:["thousand"], percent:["percent"], currencies:["dollars":"$","dollar":"$","euros":"€","euro":"€","pounds":"£"], units:["kilometers":"km","kilometres":"km","kilograms":"kg","meters":"m","metres":"m","degrees":"°"], timePrepositions:["at"], months:["january":1,"february":2,"march":3,"april":4,"may":5,"june":6,"july":7,"august":8,"september":9,"october":10,"november":11,"december":12], ordinals:["first":1,"second":2,"third":3,"fifteenth":15]),
        .german: .init(values:["null":0,"eins":1,"ein":1,"zwei":2,"drei":3,"vier":4,"fünf":5,"sechs":6,"sieben":7,"acht":8,"neun":9,"zehn":10,"elf":11,"zwölf":12,"fünfzehn":15], tens:["zwanzig":20,"dreißig":30,"vierzig":40,"fünfzig":50], hundred:["hundert"], thousand:["tausend"], percent:["prozent"], currencies:["euro":"€","dollar":"$","pfund":"£"], units:["kilometer":"km","kilogramm":"kg","meter":"m","grad":"°"], timePrepositions:["um"], months:["januar":1,"februar":2,"märz":3,"april":4,"mai":5,"juni":6,"juli":7,"august":8,"september":9,"oktober":10,"november":11,"dezember":12], ordinals:["erste":1,"zweite":2,"dritte":3,"fünfzehnte":15]),
        .russian: .init(values:["ноль":0,"один":1,"два":2,"три":3,"четыре":4,"пять":5,"шесть":6,"семь":7,"восемь":8,"девять":9,"десять":10,"двенадцать":12,"пятнадцать":15], tens:["двадцать":20,"тридцать":30,"сорок":40,"пятьдесят":50], hundred:["сто"], thousand:["тысяча"], percent:["процент","процентов"], currencies:["евро":"€","долларов":"$","рублей":"₽"], units:["километров":"км","килограммов":"кг","метров":"м","градусов":"°"], timePrepositions:["в"], months:["января":1,"февраля":2,"марта":3,"апреля":4,"мая":5,"июня":6,"июля":7,"августа":8,"сентября":9,"октября":10,"ноября":11,"декабря":12], ordinals:["первое":1,"второе":2,"третье":3,"пятнадцатое":15]),
        .ukrainian: .init(values:["нуль":0,"один":1,"два":2,"три":3,"чотири":4,"п'ять":5,"шість":6,"сім":7,"вісім":8,"дев'ять":9,"десять":10,"дванадцять":12,"п'ятнадцять":15], tens:["двадцять":20,"тридцять":30,"сорок":40,"п'ятдесят":50], hundred:["сто"], thousand:["тисяча"], percent:["відсоток","відсотків"], currencies:["євро":"€","доларів":"$","гривень":"₴"], units:["кілометрів":"км","кілограмів":"кг","метрів":"м","градусів":"°"], timePrepositions:["о"], months:["січня":1,"лютого":2,"березня":3,"квітня":4,"травня":5,"червня":6,"липня":7,"серпня":8,"вересня":9,"жовтня":10,"листопада":11,"грудня":12], ordinals:["перше":1,"друге":2,"третє":3,"п'ятнадцяте":15]),
    ]
}
