using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;
using Witness.Core.Review;
using Witness.Core.Text;

namespace Witness.Core.Tests;

[TestClass]
public sealed class RiskEngineParityTests
{
    private readonly ConservativeCleanupService _cleanup = new();

    [TestMethod]
    public void DigitsAmountsWeekdaysAndContextualDatesAreMarked()
    {
        AssertMarked("Bitte überweise 1450 Euro bis Freitag", SpeechLanguage.German,
            RiskReasonKind.Number, "1450");
        AssertMarked("Bitte überweise 1450 Euro bis Freitag", SpeechLanguage.German,
            RiskReasonKind.Amount, "Euro");
        AssertMarked("Bitte überweise 1450 Euro bis Freitag", SpeechLanguage.German,
            RiskReasonKind.Date, "Freitag");

        var cases = new[]
        {
            ("Der Termin am dritten März", SpeechLanguage.German, new[] { "dritten", "März" }),
            ("The meeting on March third", SpeechLanguage.English, new[] { "March", "third" }),
            ("Встреча третьего марта", SpeechLanguage.Russian, new[] { "третьего", "марта" }),
            ("Зустріч третього березня", SpeechLanguage.Ukrainian, new[] { "третього", "березня" }),
        };
        foreach (var (text, language, expected) in cases)
        {
            var marked = new NumberRiskSignal().Spans(Context(text, language))
                .Where(span => span.Reason == RiskReasonKind.Date)
                .Select(span => Slice(text, span.Range)).ToArray();
            CollectionAssert.AreEqual(expected, marked, language.Code);
        }
    }

    [TestMethod]
    public void BareOrdinalsInOrdinaryProseAreNotDates()
    {
        var german = new NumberRiskSignal().Spans(Context("Bitte lies den zweiten Absatz", SpeechLanguage.German));
        var english = new NumberRiskSignal().Spans(Context("Please read the second paragraph", SpeechLanguage.English));
        Assert.IsFalse(german.Any(span => span.Reason == RiskReasonKind.Date));
        Assert.IsFalse(english.Any(span => span.Reason == RiskReasonKind.Date));
    }

    [TestMethod]
    public void GermanNounsAreNotEntitiesButTitledNamesAndAcronymsAre()
    {
        var ordinary = new EntityRiskSignal().Spans(Context(
            "Die Rechnung für die Prüfung der Verträge ist offen", SpeechLanguage.German));
        Assert.HasCount(0, ordinary);
        Assert.IsFalse(EntityRiskSignal.UsesCapitalizationHeuristic(SpeechLanguage.German));

        var titled = new EntityRiskSignal().Spans(Context(
            "Frau Schneider hat den Vertrag abgelehnt", SpeechLanguage.German));
        CollectionAssert.AreEqual(new[] { "Schneider" }, titled.Select(span => Slice("Frau Schneider hat den Vertrag abgelehnt", span.Range)).ToArray());

        var acronymText = "Die GmbH und die AG";
        var acronyms = new EntityRiskSignal().Spans(Context(acronymText, SpeechLanguage.German));
        CollectionAssert.AreEqual(new[] { "AG" }, acronyms.Select(span => Slice(acronymText, span.Range)).ToArray());
    }

    [TestMethod]
    public void EnglishPronounSentenceStartsAndNumbersAreNotNames()
    {
        Assert.HasCount(0, new EntityRiskSignal().Spans(Context("Tomorrow I will send it", SpeechLanguage.English)));
        Assert.HasCount(0, new EntityRiskSignal().Spans(Context("Invoice 1450 is open", SpeechLanguage.English)));
        Assert.HasCount(0, new EntityRiskSignal().Spans(Context("Переведи деньги. Счёт открыт", SpeechLanguage.Russian)));
    }

    [TestMethod]
    public void GlossarySilencesExactNamesAndMarksScopedNearMisses()
    {
        var russianText = "обсуждение перенесли во Флок";
        Assert.HasCount(1, new EntityRiskSignal().Spans(Context(russianText, SpeechLanguage.Russian)));
        Assert.HasCount(0, new EntityRiskSignal().Spans(Context(
            russianText, SpeechLanguage.Russian, glossary: [new GlossaryEntry("Флок", SpeechLanguage.Russian)])));

        var germanText = "Bitte an Miller überweisen";
        var nearMiss = new GlossaryRiskSignal().Spans(Context(
            germanText, SpeechLanguage.German, glossary: [new GlossaryEntry("Müller", SpeechLanguage.German)]));
        Assert.HasCount(1, nearMiss);
        Assert.AreEqual("Miller", Slice(germanText, nearMiss[0].Range));
        Assert.AreEqual("Müller", nearMiss[0].Detail);

        Assert.HasCount(0, new GlossaryRiskSignal().Spans(Context(
            "Bitte an Müller überweisen", SpeechLanguage.German,
            glossary: [new GlossaryEntry("Müller", SpeechLanguage.German)])));
        Assert.HasCount(0, new GlossaryRiskSignal().Spans(Context(
            "Мюлер получил счёт", SpeechLanguage.German,
            glossary: [new GlossaryEntry("Мюллер", SpeechLanguage.Russian)])));
        Assert.AreEqual(1, GlossaryRiskSignal.AllowedDistance(3));
    }

    [TestMethod]
    public void LanguageSwitchUsesOnlyEvidenceTheSelectedProfileSupports()
    {
        var russian = new LanguageProfile(SpeechLanguage.Russian);
        var mixed = new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.English);
        var text = "Счёт открыт meeting завтра";
        var outside = new LanguageSwitchRiskSignal().Spans(new RiskContext(text, russian));
        Assert.HasCount(1, outside);
        Assert.AreEqual("meeting", Slice(text, outside[0].Range));
        Assert.AreEqual(SpeechLanguage.English, outside[0].Language);
        Assert.HasCount(0, new LanguageSwitchRiskSignal().Spans(new RiskContext(text, mixed, SpeechLanguage.Russian)));

        var ukrainianEvidence = new LanguageSwitchRiskSignal().Spans(new RiskContext(
            "Рахунок відкритий", russian, SpeechLanguage.Russian));
        Assert.HasCount(1, ukrainianEvidence);
        Assert.AreEqual(SpeechLanguage.Ukrainian, ukrainianEvidence[0].Language);
    }

    [TestMethod]
    public void UnverifiedProfilesDisablePerLanguageLetterGuessing()
    {
        Assert.IsTrue(SpeechLanguage.TryCreate("sv", out var swedish));
        var profile = new LanguageProfile(swedish);
        Assert.HasCount(0, new LanguageSwitchRiskSignal().Spans(new RiskContext("för", profile, swedish)));
    }

    [TestMethod]
    public void MalformedShapeMatchesMeasuredRulesAndGates()
    {
        Assert.IsTrue(MalformedWordSignal.HasImpossibleShape("ррверка", SpeechLanguage.Russian));
        Assert.IsTrue(MalformedWordSignal.HasImpossibleShape("пперевірка", SpeechLanguage.Ukrainian));
        Assert.IsTrue(MalformedWordSignal.HasImpossibleShape("abkrtlnst", SpeechLanguage.English));
        Assert.IsFalse(MalformedWordSignal.HasImpossibleShape("бодрствовать", SpeechLanguage.Russian));
        Assert.IsFalse(MalformedWordSignal.HasImpossibleShape("strengths", SpeechLanguage.English));
        Assert.IsFalse(MalformedWordSignal.HasImpossibleShape("Angstschweiß", SpeechLanguage.German));
        Assert.IsFalse(MalformedWordSignal.UsesConsonantRunRule(SpeechLanguage.German));

        var context = Context("ррверка прошла успешно", SpeechLanguage.Russian);
        Assert.HasCount(1, new MalformedWordSignal(new ShapeOnlyLexicon()).Spans(context));
        Assert.HasCount(0, new MalformedWordSignal(new EmptyLexicon()).Spans(context));
        Assert.HasCount(0, new MalformedWordSignal(new ShapeOnlyLexicon()).Spans(Context(
            "проект Ррверк закрыт", SpeechLanguage.Russian,
            glossary: [new GlossaryEntry("Ррверк", SpeechLanguage.Russian)])));
    }

    [TestMethod]
    public void MalformedRuleIsOffOutsideVerifiedTier()
    {
        Assert.IsTrue(SpeechLanguage.TryCreate("pl", out var polish));
        Assert.HasCount(0, new MalformedWordSignal(new ShapeOnlyLexicon()).Spans(
            new RiskContext("łódź", new LanguageProfile(polish), polish)));
    }

    [TestMethod]
    public void ConfidenceRunsButHasZeroDefaultWeight()
    {
        var raw = "der termin steht";
        var cleanup = _cleanup.Clean(raw, SpeechLanguage.German);
        var tokens = new[]
        {
            Token("der", raw, 0, .3, .05),
            Token("termin", raw, .3, .7, .05),
            Token("steht", raw, .7, 1, .05),
        };
        var spans = RiskEngine.Standard().Analyze(cleanup, new LanguageProfile(SpeechLanguage.German), tokens);
        var confidence = spans.Where(span => span.Reason == RiskReasonKind.Confidence).ToArray();
        Assert.HasCount(3, confidence);
        Assert.IsTrue(confidence.All(span => span.Weight == 0));
        Assert.IsFalse(ReviewCoordinator.Decide(spans).DeservesAttention);

        var enabled = RiskEngine.Standard(new RiskWeights { ModelConfidence = 1 }).Analyze(
            cleanup, new LanguageProfile(SpeechLanguage.German), [Token("termin", raw, .3, .7, .1)]);
        Assert.AreEqual(.8, enabled.Single(span => span.Reason == RiskReasonKind.Confidence).Weight, .0001);
    }

    [TestMethod]
    public void CleanupSpansMapToTheCorrectUnicodeText()
    {
        foreach (var (raw, language) in new[]
        {
            ("  ähm bitte überweise 1450 euro  ", SpeechLanguage.German),
            ("переведи 1450 евро мюллеру до пятницы", SpeechLanguage.Russian),
        })
        {
            var cleanup = _cleanup.Clean(raw, language);
            var spans = RiskEngine.Standard().Analyze(cleanup, new LanguageProfile(language));
            var map = new TextIndexMap(cleanup.Cleaned);
            foreach (var span in spans.Where(span => span.HasExtentInCleanedText))
                Assert.AreEqual(map.Slice(span.CleanedRange), span.Text);
        }
    }

    [TestMethod]
    public void TimingWindowCoversAllOverlappingTokens()
    {
        var raw = "bitte überweise 1450 euro";
        var tokens = TimedWords(raw, .5);
        var spans = RiskEngine.Standard().Analyze(
            _cleanup.Clean(raw, SpeechLanguage.German),
            new LanguageProfile(SpeechLanguage.German),
            tokens);
        var amount = spans.Single(span => span.Text == "1450");
        Assert.AreEqual(1, amount.StartSeconds);
        Assert.AreEqual(1.5, amount.EndSeconds);
        Assert.IsTrue(amount.IsPlayable);
    }

    [TestMethod]
    public void DuplicateCategoriesCollapseButSpecificReasonsSurvive()
    {
        var range = new TextRange(0, 4);
        var duplicate = new RawRiskSpan(RiskReasonKind.Number, range);
        var engine = new RiskEngine([new StubSignal("a", duplicate), new StubSignal("b", duplicate)]);
        Assert.HasCount(1, engine.Analyze(CleanupResult.Unchanged("1450", SpeechLanguage.German), new LanguageProfile(SpeechLanguage.German)));

        var specific = new RiskEngine([
            new StubSignal("number", duplicate),
            new StubSignal("glossary", new RawRiskSpan(RiskReasonKind.Glossary, range, "1450")),
        ]);
        Assert.HasCount(2, specific.Analyze(CleanupResult.Unchanged("1450", SpeechLanguage.German), new LanguageProfile(SpeechLanguage.German)));
    }

    [TestMethod]
    public void WeekdaysMonthsAndCurrenciesAreNotAlsoNames()
    {
        var cases = new[]
        {
            ("Please transfer €1450 to Miller by Friday.", "Friday", RiskReasonKind.Date),
            ("The meeting on March 3 was not confirmed.", "March", RiskReasonKind.Date),
            ("Balance 2500 EUR.", "EUR", RiskReasonKind.Amount),
            ("Balance 2500 Euro.", "Euro", RiskReasonKind.Amount),
        };
        foreach (var (text, word, reason) in cases)
        {
            var spans = Analyze(text, SpeechLanguage.English, new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.English));
            var matching = spans.Where(span => span.Text == word).ToArray();
            Assert.HasCount(1, matching, word);
            Assert.AreEqual(reason, matching[0].Reason, word);
        }
        AssertMarked("Send it to ACME today.", SpeechLanguage.English, RiskReasonKind.NamedEntity, "ACME");
    }

    [TestMethod]
    public void RussianAndUkrainianFalsePositiveRegressionsStayCorrect()
    {
        var russian = Analyze("Переведи 1450 евро Мюллеру до пятницы.", SpeechLanguage.Russian,
            new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.English));
        AssertReason(russian, "1450", RiskReasonKind.Number);
        AssertReason(russian, "евро", RiskReasonKind.Amount);
        AssertReason(russian, "Мюллеру", RiskReasonKind.NamedEntity);
        AssertReason(russian, "пятницы", RiskReasonKind.Date);

        var mixed = Analyze("Делай commit, merge и push.", SpeechLanguage.Russian,
            new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.English));
        Assert.IsFalse(mixed.Any(span => span.Reason == RiskReasonKind.LanguageSwitch));

        var ukrainian = Analyze("Зустріч 3 березня не підтверджена.", SpeechLanguage.Ukrainian,
            new LanguageProfile(SpeechLanguage.Russian, SpeechLanguage.Ukrainian));
        AssertReason(ukrainian, "3", RiskReasonKind.Number);
        AssertReason(ukrainian, "березня", RiskReasonKind.Date);
        Assert.IsFalse(ukrainian.Any(span => span.Text == "підтверджена"));
    }

    [TestMethod]
    public void OrdinaryProseStaysInsideReleaseBudgets()
    {
        var samples = ProseSamples();
        var wordCount = 0;
        var flaggedCount = 0;
        var falseWarnings = 0;
        var germanEntityMarks = 0;
        foreach (var (language, text) in samples)
        {
            wordCount += WordScanner.Words(text).Count;
            var spans = RiskEngine.Standard(lexicon: new ShapeOnlyLexicon()).Analyze(
                _cleanup.Clean(text, language), new LanguageProfile(language));
            var decision = ReviewCoordinator.Decide(spans);
            if (decision.DeservesAttention) flaggedCount++;
            falseWarnings += decision.Flagged.Count;
            if (language == SpeechLanguage.German)
                germanEntityMarks += spans.Count(span => span.Reason == RiskReasonKind.NamedEntity);
        }
        var density = falseWarnings * 100D / wordCount;
        var attentionRate = flaggedCount / (double)samples.Count;
        Assert.IsLessThanOrEqualTo(6, density, $"marks per 100 words: {density:F2}");
        Assert.IsLessThanOrEqualTo(.25, attentionRate, $"attention rate: {attentionRate:P1}");
        Assert.IsLessThanOrEqualTo(1, germanEntityMarks);
    }

    [TestMethod]
    public void CorrectNamesNeverEarnAttentionAtReleaseThreshold()
    {
        var names = new[]
        {
            (SpeechLanguage.German, "Ich habe die Notiz in Notion abgelegt und Anna Bescheid gesagt."),
            (SpeechLanguage.German, "Der Build läuft wieder, Jenkins hat ihn heute Nacht durchgezogen."),
            (SpeechLanguage.English, "I put the note in Notion and let Anna know."),
            (SpeechLanguage.English, "The build is green again, Jenkins pushed it through last night."),
            (SpeechLanguage.Russian, "Я скинул заметку в Notion и написал Анне."),
            (SpeechLanguage.Russian, "Обсуждение мы перенесли во Флок, там вся команда."),
            (SpeechLanguage.Ukrainian, "Я скинув нотатку в Notion і написав Анні."),
            (SpeechLanguage.Ukrainian, "Обговорення ми перенесли у Флок, там уся команда."),
        };
        foreach (var (language, text) in names)
            Assert.IsFalse(ReviewCoordinator.Decide(Analyze(text, language, new LanguageProfile(language))).DeservesAttention, text);
    }

    private RiskContext Context(string text, SpeechLanguage language, IReadOnlyList<GlossaryEntry>? glossary = null) =>
        new(text, new LanguageProfile(language), language, glossary: glossary);

    private IReadOnlyList<RiskSpan> Analyze(string text, SpeechLanguage language, LanguageProfile profile) =>
        RiskEngine.Standard().Analyze(_cleanup.Clean(text, language), profile);

    private void AssertMarked(string text, SpeechLanguage language, RiskReasonKind reason, string expected)
    {
        AssertReason(Analyze(text, language, new LanguageProfile(language)), expected, reason);
    }

    private static void AssertReason(IEnumerable<RiskSpan> spans, string text, RiskReasonKind reason)
    {
        var matching = spans.Where(span => span.Text == text).ToArray();
        Assert.IsTrue(matching.Any(span => span.Reason == reason), $"Expected {text} to be marked as {reason}.");
    }

    private static string Slice(string text, TextRange range) => new TextIndexMap(text).Slice(range);

    private static TranscriptToken Token(string word, string text, double start, double end, double? confidence = null) =>
        new(word, GraphemeSearch.FindAll(text, word, StringComparison.OrdinalIgnoreCase).Single(), start, end, confidence);

    private static IReadOnlyList<TranscriptToken> TimedWords(string text, double secondsPerWord)
    {
        var words = WordScanner.Words(text);
        return words.Select((word, index) => new TranscriptToken(
            word.Text, word.Range, index * secondsPerWord, (index + 1) * secondsPerWord, .95)).ToArray();
    }

    private static List<(SpeechLanguage Language, string Text)> ProseSamples()
    {
        var result = new List<(SpeechLanguage, string)>();
        Add(SpeechLanguage.German,
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
            "Die Antwort kam am 14. Mai, also drei Tage später.",
            "Wir haben 12 Kommentare bekommen, die meisten zum Aufbau.",
            "Ich habe die Notiz in Notion abgelegt und Anna Bescheid gesagt.",
            "Der Build läuft wieder, Jenkins hat ihn heute Nacht durchgezogen.");
        Add(SpeechLanguage.English,
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
            "The reply arrived on 14 May, three days later.",
            "We got 12 comments, most of them about the structure.",
            "I put the note in Notion and let Anna know.",
            "The build is green again, Jenkins pushed it through last night.");
        Add(SpeechLanguage.Russian,
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
            "Ответ пришёл 14 мая, то есть на три дня позже.",
            "Мы получили 12 комментариев, в основном про структуру.",
            "Я скинул заметку в Notion и написал Анне.",
            "Обсуждение мы перенесли во Флок, там вся команда.");
        Add(SpeechLanguage.Ukrainian,
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
            "Відповідь надійшла 14 травня, тобто на три дні пізніше.",
            "Ми отримали 12 коментарів, здебільшого про структуру.",
            "Я скинув нотатку в Notion і написав Анні.",
            "Обговорення ми перенесли у Флок, там уся команда.");
        return result;

        void Add(SpeechLanguage language, params string[] texts) => result.AddRange(texts.Select(text => (language, text)));
    }

    private sealed class StubSignal(string identifier, params RawRiskSpan[] spans) : IRiskSignal
    {
        public string Identifier { get; } = identifier;
        public IReadOnlyList<RawRiskSpan> Spans(RiskContext context) => spans;
    }
}
