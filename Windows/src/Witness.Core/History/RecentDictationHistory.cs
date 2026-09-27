namespace Witness.Core.History;

public sealed record RecentDictation(string Text, DateTimeOffset CreatedAt);

public sealed class RecentDictationHistory
{
    public const int MaximumCount = 10;
    private readonly List<RecentDictation> _items = [];

    public IReadOnlyList<RecentDictation> Items => _items;

    public bool Add(string text, DateTimeOffset createdAt, bool insertionRefusedForProtectedField = false)
    {
        if (insertionRefusedForProtectedField || string.IsNullOrWhiteSpace(text))
        {
            return false;
        }
        _items.Insert(0, new RecentDictation(text, createdAt));
        if (_items.Count > MaximumCount)
        {
            _items.RemoveRange(MaximumCount, _items.Count - MaximumCount);
        }
        return true;
    }

    public void Clear() => _items.Clear();
}
