using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Languages;
using Witness.Core.Text;

namespace Witness.Core.Tests;

[TestClass]
public sealed class ConservativeCleanupTests
{
    private readonly ConservativeCleanupService _service = new();

    [TestMethod]
    public void SentencesAreCapitalizedAndClosedWithoutGuessingGermanNouns()
    {
        var result = _service.Clean("bitte überweise den betrag", SpeechLanguage.German);
        Assert.AreEqual("Bitte überweise den betrag.", result.Cleaned);
        CollectionAssert.AreEquivalent(new[] { TextEditKind.Capitalization, TextEditKind.Punctuation }, result.Edits.Select(edit => edit.Kind).ToArray());
    }

    [TestMethod]
    public void WhitespaceAndPunctuationSpacingAreConservative()
    {
        Assert.AreEqual("Der Termin ist offen.", _service.Clean("  Der   Termin ist offen.  ", SpeechLanguage.German).Cleaned);
        Assert.AreEqual("Der Termin ist offen. Müller wartet.", _service.Clean("Der Termin ist offen .Müller wartet", SpeechLanguage.German).Cleaned);
        Assert.AreEqual("Um 12:30 Uhr.", _service.Clean("um 12:30 Uhr", SpeechLanguage.German).Cleaned);
        Assert.AreEqual("Betrag 1.450,00 Euro.", _service.Clean("Betrag 1.450,00 Euro", SpeechLanguage.German).Cleaned);
    }

    [TestMethod]
    public void FillersAreLanguageKeyedAndAmbiguousWordsRemain()
    {
        Assert.AreEqual("Ich brauche die Rechnung.", _service.Clean("Ich äh brauche die Rechnung", SpeechLanguage.German).Cleaned);
        Assert.AreEqual("I need the invoice.", _service.Clean("I um need the invoice", SpeechLanguage.English).Cleaned);
        Assert.AreEqual("Bitten um Geduld.", _service.Clean("bitten um Geduld", SpeechLanguage.German).Cleaned);
        Assert.AreEqual("Ну вот и всё.", _service.Clean("ну вот и всё", SpeechLanguage.Russian).Cleaned);
    }

    [TestMethod]
    public void LeadingFillerRemovalMovesCapitalizationToFirstContentWord()
    {
        var result = _service.Clean("ähm der termin steht", SpeechLanguage.German);
        Assert.AreEqual("Der termin steht.", result.Cleaned);
        Assert.AreEqual("ähm ", result.Edits.Single(edit => edit.Kind == TextEditKind.FillerRemoval).RawText);
    }

    [TestMethod]
    public void WordSequenceNumbersAndNegationArePreserved()
    {
        var cases = new[]
        {
            ("bitte überweise 1450 euro bis freitag an müller", SpeechLanguage.German),
            ("переведи 1450 евро мюллеру до пятницы не сегодня", SpeechLanguage.Russian),
            ("переказати 1450 євро мюллеру до п'ятниці не сьогодні", SpeechLanguage.Ukrainian),
            ("please do not transfer 1450 euro before friday", SpeechLanguage.English),
        };
        foreach (var (text, language) in cases)
        {
            var before = WordScanner.Words(text).Select(word => word.Lowercased).ToArray();
            var after = WordScanner.Words(_service.Clean(text, language).Cleaned).Select(word => word.Lowercased).ToArray();
            CollectionAssert.AreEqual(before, after, language.Code);
        }
    }

    [TestMethod]
    public void UnverifiedLanguageRulesStayOffRatherThanGuessing()
    {
        Assert.IsTrue(SpeechLanguage.TryCreate("pl", out var polish));
        var raw = "  um tekst bez zmian  ";
        var result = _service.Clean(raw, polish);
        Assert.AreEqual(raw, result.Cleaned);
        Assert.HasCount(0, result.Edits);
    }

    [TestMethod]
    public void EveryRuleCanBeDisabled()
    {
        var raw = "  ähm der termin  ";
        var result = _service.Clean(raw, SpeechLanguage.German, CleanupOptions.None);
        Assert.AreEqual(raw, result.Cleaned);
        Assert.HasCount(0, result.Edits);
    }

    [TestMethod]
    public void EveryEditDescribesExactRawAndCleanedGraphemes()
    {
        const string raw = "  ähm bitte überweise 1450 euro .Müller wartet  ";
        var result = _service.Clean(raw, SpeechLanguage.German);
        var rawMap = new TextIndexMap(result.Raw);
        var cleanedMap = new TextIndexMap(result.Cleaned);
        Assert.IsNotEmpty(result.Edits);
        foreach (var edit in result.Edits)
        {
            Assert.AreEqual(edit.RawText, rawMap.Slice(edit.RawRange));
            Assert.AreEqual(edit.CleanedText, cleanedMap.Slice(edit.CleanedRange));
        }
        Assert.AreEqual(raw, result.Raw);
    }

    [TestMethod]
    public void UntouchedWordsRoundTripThroughEditMapAcrossUnicode()
    {
        foreach (var (raw, language) in new[]
        {
            ("  ähm müller schuldet 1450 euro für die prüfung  ", SpeechLanguage.German),
            ("переведи 1450 евро мюллеру до пятницы", SpeechLanguage.Russian),
            ("переказати 1450 євро мюллеру до п'ятниці", SpeechLanguage.Ukrainian),
        })
        {
            var result = _service.Clean(raw, language);
            var rawMap = new TextIndexMap(result.Raw);
            var cleanedMap = new TextIndexMap(result.Cleaned);
            foreach (var word in WordScanner.Words(result.Raw))
            {
                var touchesEdit = result.Edits.Any(edit => Overlaps(edit.RawRange, word.Range));
                if (touchesEdit) continue;
                var cleanedRange = result.Map.CleanedRangeForRaw(word.Range);
                Assert.AreEqual(word.Text, cleanedMap.Slice(cleanedRange), raw);
                Assert.AreEqual(word.Range, result.Map.RawRangeForCleaned(cleanedRange), raw);
                Assert.AreEqual(word.Text, rawMap.Slice(word.Range), raw);
            }
        }
    }

    [TestMethod]
    public void SegmentsTileRawAndCleanedWithoutGaps()
    {
        var result = _service.Clean("  ähm bitte überweise 1450 euro .Müller wartet  ", SpeechLanguage.German);
        var rawPosition = 0;
        var cleanedPosition = 0;
        foreach (var segment in result.Map.Segments)
        {
            Assert.AreEqual(rawPosition, segment.Raw.Start);
            Assert.AreEqual(cleanedPosition, segment.Cleaned.Start);
            rawPosition = segment.Raw.End;
            cleanedPosition = segment.Cleaned.End;
        }
        Assert.AreEqual(result.Map.RawLength, rawPosition);
        Assert.AreEqual(result.Map.CleanedLength, cleanedPosition);
        Assert.AreEqual(new TextIndexMap(result.Raw).GraphemeCount, result.Map.RawLength);
        Assert.AreEqual(new TextIndexMap(result.Cleaned).GraphemeCount, result.Map.CleanedLength);
    }

    [TestMethod]
    public void WordScannerPreservesOffsetsJoinersAndNumericSeparators()
    {
        CollectionAssert.AreEqual(new[] { "Müller", "з'їзд", "don't", "1.450,00", "12:30" }, WordScanner.Words("Müller з'їзд don't 1.450,00 12:30").Select(word => word.Text).ToArray());
        CollectionAssert.AreEqual(new[] { "Meyer", "und", "Schmidt" }, WordScanner.Words("Meyer- und Schmidt").Select(word => word.Text).ToArray());
        CollectionAssert.AreEqual(new[] { "Der", "Müller" }, WordScanner.Words("Der Termin ist offen. Müller wartet").Where(word => word.IsSentenceInitial).Select(word => word.Text).ToArray());
    }

    private static bool Overlaps(TextRange left, TextRange right) => left.Start < right.End && right.Start < left.End;
}
