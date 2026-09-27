namespace Witness.Core.Languages;

public sealed class LanguageDetectionTimingPolicy
{
    public bool CanCommitFinalLanguage(bool recordingCompleted) => recordingCompleted;
}
