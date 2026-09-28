using Witness.Core.Text;

namespace Witness.Core.Transcription;

public enum TranscriptionTimingGranularity
{
    Segment,
    Token,
}

public sealed record TranscriptionToken(
    string Text,
    float Probability,
    TimeSpan? Start = null,
    TimeSpan? End = null);

public sealed record TranscriptionSegment(
    string Text,
    TimeSpan Start,
    TimeSpan End,
    IReadOnlyList<TranscriptionToken> Tokens);

public sealed record TranscriptionWord(
    string Text,
    TextRange GraphemeRange,
    TimeSpan Start,
    TimeSpan End,
    float? MeanTokenProbability,
    TranscriptionTimingGranularity TimingGranularity,
    int SegmentIndex);

public sealed record MappedTranscript(
    string Text,
    IReadOnlyList<TranscriptionWord> Words,
    TranscriptionTimingGranularity TimingGranularity);
