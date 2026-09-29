namespace Witness.Core.Review;

/// <summary>
/// Owns at most one completed in-memory recording for optional review replay.
/// A new result, dismissal, or disposal clears the previous sample array before
/// releasing it. No audio is added to history or exposed to persistence.
/// </summary>
public sealed class ReviewAudioLease : IDisposable
{
    private readonly object gate = new();
    private float[]? samples;
    private int sampleRate;
    private ProcessedDictation? dictation;
    private bool disposed;

    public bool HasAudio
    {
        get
        {
            lock (gate)
            {
                return samples is not null;
            }
        }
    }

    public int FrameCount
    {
        get
        {
            lock (gate)
            {
                return samples?.Length ?? 0;
            }
        }
    }

    public bool Replace(float[] completedAudio, int completedSampleRate, ProcessedDictation result)
    {
        ArgumentNullException.ThrowIfNull(completedAudio);
        ArgumentNullException.ThrowIfNull(result);
        if (completedSampleRate <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(completedSampleRate));
        }

        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            ReleaseLocked();
            if (!result.RetainAudioForReview || completedAudio.Length == 0)
            {
                Array.Clear(completedAudio);
                return false;
            }

            samples = completedAudio;
            sampleRate = completedSampleRate;
            dictation = result;
            return true;
        }
    }

    public bool TryCopyFlaggedFragment(
        RiskSpan span,
        out float[] fragment,
        double paddingSeconds = 0.15)
    {
        ArgumentNullException.ThrowIfNull(span);
        if (paddingSeconds < 0 || !double.IsFinite(paddingSeconds))
        {
            throw new ArgumentOutOfRangeException(nameof(paddingSeconds));
        }

        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            fragment = [];
            if (samples is null
                || dictation is null
                || !dictation.Review.Flagged.Contains(span)
                || span.StartSeconds is not double start
                || span.EndSeconds is not double end
                || !double.IsFinite(start)
                || !double.IsFinite(end)
                || end < start)
            {
                return false;
            }

            var first = Math.Clamp(
                (int)Math.Floor((start - paddingSeconds) * sampleRate),
                0,
                samples.Length);
            var last = Math.Clamp(
                (int)Math.Ceiling((end + paddingSeconds) * sampleRate),
                first,
                samples.Length);
            if (last == first)
            {
                return false;
            }

            fragment = samples[first..last];
            return true;
        }
    }

    public void Release()
    {
        lock (gate)
        {
            if (!disposed)
            {
                ReleaseLocked();
            }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }
            ReleaseLocked();
            disposed = true;
        }
    }

    private void ReleaseLocked()
    {
        if (samples is not null)
        {
            Array.Clear(samples);
        }
        samples = null;
        sampleRate = 0;
        dictation = null;
    }
}
