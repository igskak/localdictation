using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Platform.Windows.Insertion;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class StandardEditInsertionServiceTests
{
    private static readonly InsertionTarget Target = new(42, 10);

    [TestMethod]
    public void KnownEditReplacesOnlyTheSelectionAndVerifiesExactValue()
    {
        var native = new FakeEditNative
        {
            Reads = new Queue<StandardEditSnapshot>(
            [new("draft old", 6, 3), new("draft new words", 15, 0)]),
        };

        var result = new StandardEditInsertionService(native).TryInsert(Target, "new words");

        Assert.AreEqual(DirectTextInsertionResult.Verified, result);
        Assert.AreEqual(1, native.ReplaceCalls);
        Assert.AreEqual("new words", native.LastReplacement);
    }

    [TestMethod]
    public void PasswordAndReadOnlyEditsAreNeverWritten()
    {
        foreach (var control in new[]
        {
            new StandardEditControl(20, IsPassword: true, IsReadOnly: false),
            new StandardEditControl(20, IsPassword: false, IsReadOnly: true),
        })
        {
            var native = new FakeEditNative { Control = control };
            var service = new StandardEditInsertionService(native);
            var result = service.TryInsert(Target, "text");
            Assert.AreEqual(
                control.IsPassword ? DirectTextInsertionResult.Protected : DirectTextInsertionResult.Unsupported,
                result);
            Assert.AreEqual(0, native.ReplaceCalls);
        }
    }

    [TestMethod]
    public void UnknownControlIsNotTreatedAsDirectWriteCapable()
    {
        var native = new FakeEditNative { Control = null };
        var service = new StandardEditInsertionService(native);

        Assert.IsFalse(service.SupportsVerifiedSelectionReplacement(Target));
        Assert.AreEqual(DirectTextInsertionResult.Unsupported, service.TryInsert(Target, "text"));
        Assert.AreEqual(0, native.ReplaceCalls);
    }

    [TestMethod]
    public void UnverifiedWriteIsTerminalAndOccursOnlyOnce()
    {
        var native = new FakeEditNative
        {
            Reads = new Queue<StandardEditSnapshot>(
            [new("draft old", 6, 3), new("unexpected", 10, 0)]),
        };
        var service = new StandardEditInsertionService(native);

        Assert.AreEqual(DirectTextInsertionResult.UnverifiedAfterWrite, service.TryInsert(Target, "new"));
        Assert.AreEqual(1, native.ReplaceCalls);
    }

    private sealed class FakeEditNative : IStandardEditNativeApi
    {
        public StandardEditControl? Control { get; init; } = new(20, false, false);
        public Queue<StandardEditSnapshot> Reads { get; init; } =
            new([new("before", 6, 0), new("beforetext", 10, 0)]);
        public int ReplaceCalls { get; private set; }
        public string? LastReplacement { get; private set; }

        public bool TryGetFocusedEdit(InsertionTarget target, out StandardEditControl? control)
        {
            control = Control;
            return control is not null;
        }

        public bool TryRead(StandardEditControl control, out StandardEditSnapshot? snapshot)
        {
            snapshot = Reads.Count > 0 ? Reads.Dequeue() : null;
            return snapshot is not null;
        }

        public bool TryReplaceSelection(StandardEditControl control, string text)
        {
            ReplaceCalls++;
            LastReplacement = text;
            return true;
        }
    }
}
