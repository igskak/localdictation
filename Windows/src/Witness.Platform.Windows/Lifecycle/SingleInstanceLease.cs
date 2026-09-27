using System.Threading;

namespace Witness.Platform.Windows.Lifecycle;

public sealed class SingleInstanceLease : IDisposable
{
    private readonly Mutex mutex;
    private bool ownsMutex;

    private SingleInstanceLease(Mutex mutex, bool ownsMutex)
    {
        this.mutex = mutex;
        this.ownsMutex = ownsMutex;
    }

    public bool IsPrimaryInstance => ownsMutex;

    public static SingleInstanceLease TryAcquire(string applicationId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(applicationId);
        var safeId = string.Concat(applicationId.Select(character =>
            char.IsLetterOrDigit(character) || character is '.' or '-' or '_' ? character : '_'));
        var mutex = new Mutex(initiallyOwned: true, $"Local\\{safeId}.SingleInstance", out var createdNew);
        return new SingleInstanceLease(mutex, createdNew);
    }

    public void Dispose()
    {
        if (ownsMutex)
        {
            mutex.ReleaseMutex();
            ownsMutex = false;
        }
        mutex.Dispose();
    }
}
