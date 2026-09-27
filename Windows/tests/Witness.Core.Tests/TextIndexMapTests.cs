using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Text;

namespace Witness.Core.Tests;

[TestClass]
public sealed class TextIndexMapTests
{
    [TestMethod]
    public void ConvertsCyrillicUmlautCombiningEmojiAndCjkAcrossIndexSpaces()
    {
        const string text = "їєґ A\u0308 👍🏽 中文\r\n";
        var map = new TextIndexMap(text);

        Assert.AreEqual(11, map.GraphemeCount);
        Assert.IsGreaterThan(map.GraphemeCount, map.Utf16Length);
        Assert.IsGreaterThan(map.Utf16Length, map.Utf8Length);

        var combining = map.GraphemeRangeToUtf16(new TextRange(4, 1));
        Assert.AreEqual("A\u0308", text.Substring(combining.Start, combining.Length));
        Assert.AreEqual(2, combining.Length);

        var emoji = map.GraphemeRangeToUtf16(new TextRange(6, 1));
        Assert.AreEqual("👍🏽", text.Substring(emoji.Start, emoji.Length));
        Assert.AreEqual(4, emoji.Length);
        Assert.AreEqual(8, map.GraphemeRangeToUtf8(new TextRange(6, 1)).Length);

        Assert.Throws<ArgumentException>(() => map.Utf16BoundaryToGrapheme(emoji.Start + 1));
    }

    [TestMethod]
    public void CrLfIsOneGraphemeAndOffsetsRoundTripOnlyAtBoundaries()
    {
        var map = new TextIndexMap("a\r\nb");
        Assert.AreEqual(3, map.GraphemeCount);
        var lineBreak = map.GraphemeRangeToUtf16(new TextRange(1, 1));
        Assert.AreEqual(new TextRange(1, 2), lineBreak);
        Assert.AreEqual(1, map.Utf16BoundaryToGrapheme(1));
        Assert.AreEqual(2, map.Utf16BoundaryToGrapheme(3));
    }

    [TestMethod]
    public void RepeatedWordsReceiveTheirOwnRangesRatherThanFirstIndex()
    {
        const string text = "так так так";
        var ranges = GraphemeSearch.FindAll(text, "так");
        CollectionAssert.AreEqual(
            new[] { new TextRange(0, 3), new TextRange(4, 3), new TextRange(8, 3) },
            ranges.ToArray());
    }

    [TestMethod]
    public void SliceUsesDomainGraphemeOffsets()
    {
        var map = new TextIndexMap("🙂e\u0301ї");
        Assert.AreEqual("e\u0301", map.Slice(new TextRange(1, 1)));
        Assert.AreEqual("ї", map.Slice(new TextRange(2, 1)));
    }
}
