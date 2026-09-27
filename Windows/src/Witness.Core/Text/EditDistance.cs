using System.Globalization;

namespace Witness.Core.Text;

public static class EditDistance
{
    /// <summary>Returns null as soon as the grapheme edit distance is proven to exceed the bound.</summary>
    public static int? Bounded(string left, string right, int limit)
    {
        ArgumentNullException.ThrowIfNull(left);
        ArgumentNullException.ThrowIfNull(right);
        ArgumentOutOfRangeException.ThrowIfNegative(limit);
        var lhs = Graphemes(left);
        var rhs = Graphemes(right);
        if (Math.Abs(lhs.Length - rhs.Length) > limit) return null;
        if (lhs.Length == 0) return rhs.Length <= limit ? rhs.Length : null;
        if (rhs.Length == 0) return lhs.Length <= limit ? lhs.Length : null;

        var previous = Enumerable.Range(0, rhs.Length + 1).ToArray();
        var current = new int[rhs.Length + 1];
        for (var row = 1; row <= lhs.Length; row++)
        {
            current[0] = row;
            var rowMinimum = row;
            for (var column = 1; column <= rhs.Length; column++)
            {
                var substitution = previous[column - 1]
                    + (string.Equals(lhs[row - 1], rhs[column - 1], StringComparison.Ordinal) ? 0 : 1);
                current[column] = Math.Min(substitution, Math.Min(previous[column] + 1, current[column - 1] + 1));
                rowMinimum = Math.Min(rowMinimum, current[column]);
            }
            if (rowMinimum > limit) return null;
            (previous, current) = (current, previous);
        }
        return previous[rhs.Length] <= limit ? previous[rhs.Length] : null;
    }

    private static string[] Graphemes(string value)
    {
        var result = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(value);
        while (enumerator.MoveNext()) result.Add(enumerator.GetTextElement());
        return result.ToArray();
    }
}
