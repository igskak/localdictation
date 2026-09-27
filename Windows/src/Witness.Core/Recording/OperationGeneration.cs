namespace Witness.Core.Recording;

public sealed class OperationGeneration
{
    private long _current;

    public long Current => Interlocked.Read(ref _current);

    public long Supersede() => Interlocked.Increment(ref _current);

    public bool IsCurrent(long generation) => generation == Current;
}
