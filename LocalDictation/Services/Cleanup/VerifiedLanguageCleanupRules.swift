import Foundation

struct SpokenCommandRule: Sendable, Equatable {
    let phrase: [String]
    let output: String
    let kind: TextEdit.Kind
    var finalPositionOnly = false
}

enum VerifiedLanguageCleanupRules {
    static let commands: [SpeechLanguage: [SpokenCommandRule]] = [
        .english: (punctuation([
            (["full", "stop"], "."), (["period"], "."), (["comma"], ","),
            (["question", "mark"], "?"), (["exclamation", "mark"], "!"),
            (["colon"], ":"), (["semicolon"], ";"), (["insert", "dash"], "—"),
            (["open", "parenthesis"], "("), (["close", "parenthesis"], ")"),
        ]) + breaks([(["new", "line"], "\n"), (["new", "paragraph"], "\n\n")]))
            .map { rule in rule.phrase == ["period"] ? SpokenCommandRule(phrase: rule.phrase, output: rule.output, kind: rule.kind, finalPositionOnly: true) : rule },
        .german: punctuation([
            (["punkt"], "."), (["komma"], ","), (["fragezeichen"], "?"),
            (["ausrufezeichen"], "!"), (["doppelpunkt"], ":"), (["semikolon"], ";"),
            (["gedankenstrich"], "—"), (["klammer", "auf"], "("), (["klammer", "zu"], ")"),
        ]) + breaks([(["neue", "zeile"], "\n"), (["neuer", "absatz"], "\n\n")]),
        .russian: punctuation([
            (["точка"], "."), (["запятая"], ","), (["вопросительный", "знак"], "?"),
            (["восклицательный", "знак"], "!"), (["двоеточие"], ":"),
            (["точка", "с", "запятой"], ";"), (["тире"], "—"),
            (["открыть", "скобку"], "("), (["закрыть", "скобку"], ")"),
        ]) + breaks([(["новая", "строка"], "\n"), (["новый", "абзац"], "\n\n")]),
        .ukrainian: punctuation([
            (["крапка"], "."), (["кома"], ","), (["знак", "питання"], "?"),
            (["знак", "оклику"], "!"), (["двокрапка"], ":"), (["крапка", "з", "комою"], ";"),
            (["тире"], "—"), (["відкрити", "дужку"], "("), (["закрити", "дужку"], ")"),
        ]) + breaks([(["новий", "рядок"], "\n"), (["новий", "абзац"], "\n\n")]),
    ]

    private static func punctuation(_ values: [([String], String)]) -> [SpokenCommandRule] {
        values.map { SpokenCommandRule(phrase: $0.0, output: $0.1, kind: .spokenPunctuation) }
    }

    private static func breaks(_ values: [([String], String)]) -> [SpokenCommandRule] {
        values.map {
            SpokenCommandRule(
                phrase: $0.0,
                output: $0.1,
                kind: $0.1 == "\n" ? .lineBreak : .paragraphBreak
            )
        }
    }
}
