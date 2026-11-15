import Foundation
@testable import Witness

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

    static let spanish = [
        "He leído el borrador y la estructura funciona bien.",
        "El equipo de soporte observa el mismo comportamiento que la semana pasada.",
        "Revisa de nuevo el segundo párrafo antes de enviarlo.",
        "La fecha de la revisión todavía no está fijada.",
        "Debemos actualizar la documentación cuando llegue el cambio.",
        "El problema solo aparece cuando la conexión es lenta.",
        "Agrupé varias tareas porque comparten la misma causa.",
        "El departamento jurídico todavía revisa el contrato.",
        "Confirma si los datos del informe anterior siguen vigentes.",
        "Podemos mover la conversación a la próxima semana.",
        "El informe está terminado pero falta el resumen.",
        "Propongo resolverlo en una llamada en lugar de otro correo.",
    ]

    static let italian = [
        "Ho letto la bozza e la struttura funziona bene.",
        "Il supporto vede lo stesso comportamento della settimana scorsa.",
        "Controlla di nuovo il secondo paragrafo prima di inviarlo.",
        "La data della revisione non è ancora fissata.",
        "Dovremmo aggiornare la documentazione quando arriva la modifica.",
        "Il problema compare soltanto quando la connessione è lenta.",
        "Ho riunito diverse attività perché hanno la stessa causa.",
        "Il reparto legale sta ancora esaminando il contratto.",
        "Conferma se i dati del vecchio rapporto sono ancora validi.",
        "Possiamo spostare la conversazione alla prossima settimana.",
        "Il rapporto è pronto ma manca ancora il riepilogo.",
        "Propongo di risolvere tutto con una chiamata invece di un'altra email.",
    ]

    static let french = [
        "J'ai lu le brouillon et la structure fonctionne bien.",
        "Le support observe le même comportement que la semaine dernière.",
        "Relis le deuxième paragraphe avant de l'envoyer.",
        "La date de la revue n'est pas encore fixée.",
        "Nous devrions actualiser la documentation après cette modification.",
        "Le problème apparaît seulement quand la connexion est lente.",
        "J'ai regroupé plusieurs tâches parce qu'elles ont la même cause.",
        "Le service juridique examine encore le contrat.",
        "Confirme si les données de l'ancien rapport sont toujours valables.",
        "Nous pouvons déplacer la conversation à la semaine prochaine.",
        "Le rapport est terminé mais le résumé manque encore.",
        "Je propose de régler cela pendant un appel plutôt que par mail.",
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
        (.spanish, "La respuesta llegó el 14 de mayo, tres días más tarde."),
        (.spanish, "Recibimos 12 comentarios, la mayoría sobre la estructura."),
        (.italian, "La risposta è arrivata il 14 maggio, tre giorni dopo."),
        (.italian, "Abbiamo ricevuto 12 commenti, soprattutto sulla struttura."),
        (.french, "La réponse est arrivée le 14 mai, trois jours plus tard."),
        (.french, "Nous avons reçu 12 commentaires, surtout sur la structure."),
    ]

    /// Sentences whose proper nouns came out **right**.
    ///
    /// This is the case the corpus was missing, and missing it hid a real cost.
    /// The entity signal is a capitalization heuristic, so every correctly
    /// recognized product, company, or person name is a mark — and the corpus
    /// above contains almost none, which made the heuristic look free when in a
    /// working day it was the most frequently fired signal in the engine. The
    /// complaint that started Phase 5 was precisely this: a messenger's name
    /// marked as risky in sentence after sentence, while a genuinely mangled
    /// word went through unmarked.
    ///
    /// Every name here is spelled as the speaker meant it, so every mark on one
    /// is a false warning by construction.
    static let withNames = [
        (SpeechLanguage.german, "Ich habe die Notiz in Notion abgelegt und Anna Bescheid gesagt."),
        (.german, "Der Build läuft wieder, Jenkins hat ihn heute Nacht durchgezogen."),
        (.english, "I put the note in Notion and let Anna know."),
        (.english, "The build is green again, Jenkins pushed it through last night."),
        (.russian, "Я скинул заметку в Notion и написал Анне."),
        (.russian, "Обсуждение мы перенесли во Флок, там вся команда."),
        (.ukrainian, "Я скинув нотатку в Notion і написав Анні."),
        (.ukrainian, "Обговорення ми перенесли у Флок, там уся команда."),
        (.spanish, "Guardé la nota en Notion y avisé a Ana."),
        (.spanish, "Jenkins terminó la compilación durante la noche."),
        (.italian, "Ho salvato la nota in Notion e avvisato Anna."),
        (.italian, "Jenkins ha completato la compilazione durante la notte."),
        (.french, "J'ai enregistré la note dans Notion et prévenu Anna."),
        (.french, "Jenkins a terminé la compilation pendant la nuit."),
    ]

    static var corpus: BenchmarkCorpus {
        var samples: [BenchmarkSample] = []
        let plain: [(SpeechLanguage, [String])] = [
            (.german, german),
            (.english, english),
            (.russian, russian),
            (.ukrainian, ukrainian),
            (.spanish, spanish),
            (.italian, italian),
            (.french, french),
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
        for (offset, entry) in withNames.enumerated() {
            samples.append(
                BenchmarkSample(
                    audio: "\(entry.0.rawValue)-name-\(offset).wav",
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
