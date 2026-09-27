using System.Globalization;
using System.Text;

namespace Witness.Core.Text;

public readonly record struct TextRange(int Start, int Length)
{
    public int End => checked(Start + Length);
}

public sealed class TextIndexMap
{
    private readonly string _text;
    private readonly int[] _utf16Boundaries;
    private readonly int[] _utf8Boundaries;

    public TextIndexMap(string text)
    {
        _text = text ?? throw new ArgumentNullException(nameof(text));
        var utf16 = new List<int> { 0 };
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            var next = enumerator.ElementIndex + enumerator.GetTextElement().Length;
            if (next > utf16[^1])
            {
                utf16.Add(next);
            }
        }
        if (utf16[^1] != text.Length)
        {
            utf16.Add(text.Length);
        }
        _utf16Boundaries = utf16.ToArray();
        _utf8Boundaries = _utf16Boundaries
            .Select(boundary => Encoding.UTF8.GetByteCount(text.AsSpan(0, boundary)))
            .ToArray();
    }

    public int GraphemeCount => _utf16Boundaries.Length - 1;
    public int Utf16Length => _text.Length;
    public int Utf8Length => _utf8Boundaries[^1];

    public TextRange GraphemeRangeToUtf16(TextRange graphemeRange)
    {
        ValidateGraphemeRange(graphemeRange);
        var start = _utf16Boundaries[graphemeRange.Start];
        var end = _utf16Boundaries[graphemeRange.End];
        return new TextRange(start, end - start);
    }

    public TextRange GraphemeRangeToUtf8(TextRange graphemeRange)
    {
        ValidateGraphemeRange(graphemeRange);
        var start = _utf8Boundaries[graphemeRange.Start];
        var end = _utf8Boundaries[graphemeRange.End];
        return new TextRange(start, end - start);
    }

    public int Utf16BoundaryToGrapheme(int utf16Offset) => BoundaryToGrapheme(_utf16Boundaries, utf16Offset, nameof(utf16Offset));
    public int Utf8BoundaryToGrapheme(int utf8Offset) => BoundaryToGrapheme(_utf8Boundaries, utf8Offset, nameof(utf8Offset));

    public string Slice(TextRange graphemeRange)
    {
        var utf16 = GraphemeRangeToUtf16(graphemeRange);
        return _text.Substring(utf16.Start, utf16.Length);
    }

    private void ValidateGraphemeRange(TextRange range)
    {
        if (range.Start < 0 || range.Length < 0 || range.End > GraphemeCount)
        {
            throw new ArgumentOutOfRangeException(nameof(range));
        }
    }

    private static int BoundaryToGrapheme(int[] boundaries, int offset, string parameterName)
    {
        var index = Array.BinarySearch(boundaries, offset);
        return index >= 0
            ? index
            : throw new ArgumentException("The offset splits a grapheme cluster.", parameterName);
    }
}

public static class GraphemeSearch
{
    public static IReadOnlyList<TextRange> FindAll(string text, string value, StringComparison comparison = StringComparison.Ordinal)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentException.ThrowIfNullOrEmpty(value);
        var textMap = new TextIndexMap(text);
        var ranges = new List<TextRange>();
        var searchFrom = 0;
        while (searchFrom <= text.Length - value.Length)
        {
            var found = text.IndexOf(value, searchFrom, comparison);
            if (found < 0)
            {
                break;
            }
            var end = found + value.Length;
            try
            {
                var startGrapheme = textMap.Utf16BoundaryToGrapheme(found);
                var endGrapheme = textMap.Utf16BoundaryToGrapheme(end);
                ranges.Add(new TextRange(startGrapheme, endGrapheme - startGrapheme));
            }
            catch (ArgumentException)
            {
            }
            searchFrom = Math.Max(end, found + 1);
        }
        return ranges;
    }
}
