import Foundation
@testable import LocalDictation

#if DEBUG
/// Ordinary work prose, as a corpus of correct text.
///
/// The Phase 3 smoke corpus was written so every sentence carries an amount, a
/// date, a name, and a negation, because that is what makes it useful for
/// recall. It also makes its false-warning density an upper bound and not a
/// typical figure — and Phase 4 is where the difference starts costing the user
/// time, because a mark now interrupts a path that would otherwise show no
/// window at all.
///
/// So these are sentences a knowledge worker actually dictates: tasks, ticket
/// comments, mail, notes. Numbers and names appear at the rate they appear in
/// real writing rather than in every sentence, and German keeps its capitalized
/// nouns, which is precisely what the entity heuristic must not fire on.
///
/// Committed as text rather than loaded from disk: it is written here, carries
/// no licensed speech, and a measurement that only runs where a corpus happens
/// to be installed is a measurement nobody runs.
enum ProseCorpus {
    static let german = [
        "Ich habe den Entwurf gelesen und finde die Struktur gut.",
        "Die Kollegen aus dem Support melden dasselbe Verhalten wie letzte Woche.",
        "Bitte schau dir den zweiten Absatz noch einmal an, bevor wir das rausschicken.",
        "Der Termin für die Abstimmung steht noch nicht fest.",
        "Wir sollten die Dokumentation aktualisieren, sobald die Änderung durch ist.",
        "Das Problem tritt nur auf, wenn die Verbindung langsam ist.",
        "Ich habe drei Tickets zusammengefasst, weil sie dieselbe Ursache haben.",
        "Die Prüfung der Verträge liegt bei der Rechtsabteilung.",
        "Kannst du mir sagen, ob die Zahlen aus dem alten Bericht noch stimmen?",
        "Wir verschieben das Gespräch auf nächste Woche.",
        "Der Bericht ist fertig, aber die Zusammenfassung fehlt noch.",
        "Ich schlage vor, wir klären das kurz im Gespräch statt per Mail.",
    ]

    static let english = [
        "I read through the draft and the structure works well.",
        "Support is seeing the same behaviour they reported last week.",
        "Please take another look at the second paragraph before this goes out.",
        "The date for the review has not been fixed yet.",
        "We should update the documentation once this change lands.",
        "The problem only shows up when the connection is slow.",
        "I merged three tickets because they share the same cause.",
        "Legal is still reviewing the contract.",
        "Can you tell me whether the figures in the old report still hold?",
        "Let us move the conversation to next week.",
        "The report is finished but the summary is still missing.",
        "I suggest we sort this out in a call rather than over mail.",
    ]

    static let russian = [
        "Я прочитал черновик, структура выглядит удачной.",
        "Поддержка сообщает о том же поведении, что и на прошлой неделе.",
        "Посмотри, пожалуйста, второй абзац ещё раз, прежде чем мы это отправим.",
        "Дата обсуждения пока не назначена.",
        "Документацию стоит обновить, как только изменение пройдёт.",
        "Проблема появляется только при медленном соединении.",
        "Я объединил три задачи, потому что причина у них одна.",
        "Юристы ещё смотрят договор.",
        "Скажи, пожалуйста, цифры из старого отчёта всё ещё актуальны?",
        "Давай перенесём разговор на следующую неделю.",
        "Отчёт готов, но резюме пока нет.",
        "Предлагаю обсудить это голосом, а не письмами.",
    ]

    static let ukrainian = [
        "Я прочитав чернетку, структура виглядає вдалою.",
        "Підтримка повідомляє про ту саму поведінку, що й минулого тижня.",
        "Подивись, будь ласка, другий абзац ще раз, перш ніж ми це надішлемо.",
        "Дата обговорення поки не призначена.",
        "Документацію варто оновити, щойно зміна пройде.",
        "Проблема з'являється лише за повільного з'єднання.",
        "Я об'єднав три задачі, бо причина в них одна.",
        "Юристи ще дивляться договір.",
        "Скажи, будь ласка, цифри зі старого звіту досі актуальні?",
        "Перенесімо розмову на наступний тиждень.",
        "Звіт готовий, але резюме ще немає.",
        "Пропоную обговорити це голосом, а не листами.",
    ]

    /// A tenth of the sentences carry a figure, which is roughly the rate at
    /// which ordinary work prose does. Kept in one place so the ratio is a
    /// visible decision rather than an accident of who wrote which sentence.
    static let withFigures = [
        (SpeechLanguage.german, "Die Antwort kam am 14. Mai, also drei Tage später."),
        (.german, "Wir haben 12 Kommentare bekommen, die meisten zum Aufbau."),
        (.english, "The reply arrived on 14 May, three days later."),
        (.english, "We got 12 comments, most of them about the structure."),
        (.russian, "Ответ пришёл 14 мая, то есть на три дня позже."),
        (.russian, "Мы получили 12 комментариев, в основном про структуру."),
        (.ukrainian, "Відповідь надійшла 14 травня, тобто на три дні пізніше."),
        (.ukrainian, "Ми отримали 12 коментарів, здебільшого про структуру."),
    ]

    static var corpus: BenchmarkCorpus {
        var samples: [BenchmarkSample] = []
        let plain: [(SpeechLanguage, [String])] = [
            (.german, german),
            (.english, english),
            (.russian, russian),
            (.ukrainian, ukrainian),
        ]
        for (language, sentences) in plain {
            for (index, sentence) in sentences.enumerated() {
                samples.append(
                    BenchmarkSample(
                        audio: "\(language.rawValue)-\(index).wav",
                        reference: sentence,
                        language: language,
                        profile: nil
                    )
                )
            }
        }
        for (offset, entry) in withFigures.enumerated() {
            samples.append(
                BenchmarkSample(
                    audio: "\(entry.0.rawValue)-figure-\(offset).wav",
                    reference: entry.1,
                    language: entry.0,
                    profile: nil
                )
            )
        }
        return BenchmarkCorpus(name: "ordinary-prose", samples: samples)
    }
}
#endif
