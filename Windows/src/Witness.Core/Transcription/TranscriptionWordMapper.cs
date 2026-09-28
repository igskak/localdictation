using System.Text.RegularExpressions;
using Witness.Core.Text;

namespace Witness.Core.Transcription;

public static partial class TranscriptionWordMapper
{
    public static MappedTranscript Map(IReadOnlyList<TranscriptionSegment> segments)
    {
        ArgumentNullException.ThrowIfNull(segments);
        var text = string.Concat(segments.Select(segment => segment.Text));
        var words = new List<TranscriptionWord>();
        var graphemeBase = 0;

        for (var segmentIndex = 0; segmentIndex < segments.Count; segmentIndex++)
        {
            var segment = segments[segmentIndex]
                ?? throw new ArgumentException("Transcript segments must not contain null.", nameof(segments));
            ValidateSegment(segment);
            var indexMap = new TextIndexMap(segment.Text);
            var tokenSpans = BuildTokenSpans(segment);

            foreach (Match match in WordPattern().Matches(segment.Text))
            {
                var startGrapheme = indexMap.Utf16BoundaryToGrapheme(match.Index);
                var endGrapheme = indexMap.Utf16BoundaryToGrapheme(match.Index + match.Length);
                var overlapping = tokenSpans
                    .Where(token => token.End > match.Index && token.Start < match.Index + match.Length)
                    .ToArray();
                var hasTokenTiming = overlapping.Length > 0
                    && overlapping.All(token => HasValidTokenTiming(token.Token, segment));

                var start = hasTokenTiming
                    ? overlapping.Min(token => token.Token.Start!.Value)
                    : segment.Start;
                var end = hasTokenTiming
                    ? overlapping.Max(token => token.Token.End!.Value)
                    : segment.End;
                var probability = overlapping.Length == 0
                    ? null
                    : (float?)overlapping.Average(token => (double)token.Token.Probability);

                words.Add(new TranscriptionWord(
                    match.Value,
                    new TextRange(graphemeBase + startGrapheme, endGrapheme - startGrapheme),
                    start,
                    end,
                    probability,
                    hasTokenTiming
                        ? TranscriptionTimingGranularity.Token
                        : TranscriptionTimingGranularity.Segment,
                    segmentIndex));
            }

            graphemeBase += indexMap.GraphemeCount;
        }

        var granularity = words.Count > 0
            && words.All(word => word.TimingGranularity == TranscriptionTimingGranularity.Token)
                ? TranscriptionTimingGranularity.Token
                : TranscriptionTimingGranularity.Segment;
        return new MappedTranscript(text, words, granularity);
    }

    private static IReadOnlyList<TokenSpan> BuildTokenSpans(TranscriptionSegment segment)
    {
        if (segment.Tokens.Count == 0
            || !string.Equals(
                string.Concat(segment.Tokens.Select(token => token.Text)),
                segment.Text,
                StringComparison.Ordinal))
        {
            return [];
        }

        var spans = new List<TokenSpan>(segment.Tokens.Count);
        var offset = 0;
        foreach (var token in segment.Tokens)
        {
            ArgumentNullException.ThrowIfNull(token);
            spans.Add(new TokenSpan(offset, checked(offset + token.Text.Length), token));
            offset += token.Text.Length;
        }
        return spans;
    }

    private static bool HasValidTokenTiming(
        TranscriptionToken token,
        TranscriptionSegment segment) =>
        token.Start is TimeSpan start
        && token.End is TimeSpan end
        && start >= segment.Start
        && end > start
        && end <= segment.End;

    private static void ValidateSegment(TranscriptionSegment segment)
    {
        ArgumentNullException.ThrowIfNull(segment.Text);
        ArgumentNullException.ThrowIfNull(segment.Tokens);
        if (segment.Start < TimeSpan.Zero || segment.End < segment.Start)
        {
            throw new ArgumentException("Transcript segment timing is invalid.", nameof(segment));
        }
    }

    [GeneratedRegex(@"[\p{L}\p{M}\p{N}]+(?:['’-][\p{L}\p{M}\p{N}]+)*", RegexOptions.CultureInvariant)]
    private static partial Regex WordPattern();

    private sealed record TokenSpan(int Start, int End, TranscriptionToken Token);
}
