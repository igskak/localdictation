using System.Text;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Platform.Windows.Insertion;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class ProtectedClipboardServiceTests
{
    [TestMethod]
    public void TextIsWrittenOnlyAfterAllThreePrivacyFormats()
    {
        var native = new FakeClipboard { ExistingText = "previous", SequenceNumber = 41 };
        var service = new ProtectedClipboardService(native, ownerWindow: 7);

        var result = service.TryWrite("dictation");

        Assert.IsTrue(result.Succeeded);
        Assert.AreEqual(new ClipboardTextSnapshot(true, "previous"), result.Snapshot);
        Assert.AreEqual((uint)42, result.SequenceNumber);
        CollectionAssert.AreEqual(
            new[] { "Exclude", "History", "Cloud", "Text" },
            native.SetCalls.Select(call => call.Label).ToArray());
        foreach (var privacy in native.SetCalls.Take(3))
            CollectionAssert.AreEqual(new byte[4], privacy.Data);
        Assert.AreEqual("dictation\0", Encoding.Unicode.GetString(native.SetCalls[3].Data));
        Assert.AreEqual(1, native.EmptyCalls);
        Assert.AreEqual(1, native.CloseCalls);
    }

    [TestMethod]
    public void RegistrationFailureLeavesExistingClipboardUntouched()
    {
        var native = new FakeClipboard { FailingRegistration = ProtectedClipboardService.UploadToCloudFormatName };
        var result = new ProtectedClipboardService(native, 7).TryWrite("dictation");

        Assert.IsFalse(result.Succeeded);
        Assert.AreEqual(0, native.OpenCalls);
        Assert.AreEqual(0, native.EmptyCalls);
        Assert.HasCount(0, native.SetCalls);
    }

    [TestMethod]
    public void PrivacyFailureClearsPartialFormatsWithoutWritingText()
    {
        var native = new FakeClipboard { FailingSetLabel = "History" };
        var result = new ProtectedClipboardService(native, 7).TryWrite("dictation");

        Assert.IsFalse(result.Succeeded);
        Assert.AreEqual(2, native.EmptyCalls);
        CollectionAssert.AreEqual(
            new[] { "Exclude", "History" },
            native.SetCalls.Select(call => call.Label).ToArray());
    }

    [TestMethod]
    public void TextFailureClearsProtectedButIncompleteClipboard()
    {
        var native = new FakeClipboard { FailingSetLabel = "Text" };
        var result = new ProtectedClipboardService(native, 7).TryWrite("dictation");

        Assert.IsFalse(result.Succeeded);
        Assert.AreEqual(2, native.EmptyCalls);
        CollectionAssert.AreEqual(
            new[] { "Exclude", "History", "Cloud", "Text" },
            native.SetCalls.Select(call => call.Label).ToArray());
    }

    [TestMethod]
    public void UnreadableExistingTextDoesNotPreventProtectedWriteButCannotBeRestored()
    {
        var native = new FakeClipboard { ExistingText = "private", ReadSucceeds = false };
        var service = new ProtectedClipboardService(native, 7);

        var write = service.TryWrite("dictation");
        var restore = service.TryRestore(write.Snapshot, write.SequenceNumber!.Value);

        Assert.IsTrue(write.Succeeded);
        Assert.AreEqual(ClipboardTextSnapshot.Unavailable, write.Snapshot);
        Assert.AreEqual(ClipboardSnapshotRestoreResult.SkippedUnavailable, restore);
        Assert.AreEqual(1, native.OpenCalls);
    }

    [TestMethod]
    public void RestoreChecksSequenceWhileClipboardIsOpen()
    {
        var native = new FakeClipboard { SequenceNumber = 80 };
        var service = new ProtectedClipboardService(native, 7);

        var result = service.TryRestore(new ClipboardTextSnapshot(true, "previous"), 79);

        Assert.AreEqual(ClipboardSnapshotRestoreResult.SkippedSequenceChanged, result);
        Assert.AreEqual(1, native.OpenCalls);
        Assert.AreEqual(0, native.EmptyCalls);
        Assert.AreEqual(1, native.CloseCalls);
    }

    [TestMethod]
    public void RestoreOfTextIsAlsoProtectedAndUsesTheOriginalValue()
    {
        var native = new FakeClipboard { SequenceNumber = 12 };
        var service = new ProtectedClipboardService(native, 7);

        var result = service.TryRestore(new ClipboardTextSnapshot(true, "previous"), 12);

        Assert.AreEqual(ClipboardSnapshotRestoreResult.Restored, result);
        CollectionAssert.AreEqual(
            new[] { "Exclude", "History", "Cloud", "Text" },
            native.SetCalls.Select(call => call.Label).ToArray());
        Assert.AreEqual("previous\0", Encoding.Unicode.GetString(native.SetCalls[3].Data));
    }

    [TestMethod]
    public void RestoreOfPreviouslyEmptyClipboardWritesNoContent()
    {
        var native = new FakeClipboard { SequenceNumber = 12 };
        var result = new ProtectedClipboardService(native, 7)
            .TryRestore(ClipboardTextSnapshot.Empty, 12);

        Assert.AreEqual(ClipboardSnapshotRestoreResult.Restored, result);
        Assert.AreEqual(1, native.EmptyCalls);
        Assert.HasCount(0, native.SetCalls);
    }

    private sealed class FakeClipboard : IClipboardNativeApi
    {
        private static readonly IReadOnlyDictionary<string, uint> RegisteredFormats =
            new Dictionary<string, uint>
            {
                [ProtectedClipboardService.ExcludeMonitorFormatName] = 100,
                [ProtectedClipboardService.IncludeHistoryFormatName] = 101,
                [ProtectedClipboardService.UploadToCloudFormatName] = 102,
            };

        public string? ExistingText { get; init; }
        public bool ReadSucceeds { get; init; } = true;
        public string? FailingRegistration { get; init; }
        public string? FailingSetLabel { get; init; }
        public uint SequenceNumber { get; set; }
        public int OpenCalls { get; private set; }
        public int EmptyCalls { get; private set; }
        public int CloseCalls { get; private set; }
        public List<(string Label, byte[] Data)> SetCalls { get; } = [];

        public uint RegisterFormat(string name) =>
            name == FailingRegistration ? 0 : RegisteredFormats[name];

        public bool Open(nint ownerWindow)
        {
            OpenCalls++;
            return true;
        }

        public bool Empty()
        {
            EmptyCalls++;
            SequenceNumber++;
            return true;
        }

        public bool HasFormat(uint format) => ExistingText is not null;

        public bool TryReadUnicodeText(out string? value)
        {
            value = ReadSucceeds ? ExistingText : null;
            return ReadSucceeds;
        }

        public bool TrySetBytes(uint format, byte[] data)
        {
            var label = format switch
            {
                100 => "Exclude",
                101 => "History",
                102 => "Cloud",
                ProtectedClipboardService.UnicodeTextFormat => "Text",
                _ => "Unknown",
            };
            SetCalls.Add((label, data.ToArray()));
            return label != FailingSetLabel;
        }

        public uint GetSequenceNumber() => SequenceNumber;

        public bool Close()
        {
            CloseCalls++;
            return true;
        }
    }
}
