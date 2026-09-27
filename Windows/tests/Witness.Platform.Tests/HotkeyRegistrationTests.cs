using Microsoft.VisualStudio.TestTools.UnitTesting;
using Witness.Core.Input;
using Witness.Platform.Windows.Hotkeys;

namespace Witness.Platform.Tests;

[TestClass]
public sealed class HotkeyRegistrationTests
{
    [TestMethod]
    public void ConflictPreservesPreviousWorkingRegistration()
    {
        var native = new FakeRegistration();
        using var coordinator = new HotkeyRegistrationCoordinator(native);
        var original = new HotkeyChord(HotkeyModifiers.Control, 65);
        var conflicting = new HotkeyChord(HotkeyModifiers.Alt, 66);
        Assert.AreEqual(HotkeyRegistrationStatus.Registered, coordinator.Change(original).Status);
        native.AllowRegistration = false;

        var result = coordinator.Change(conflicting);

        Assert.AreEqual(HotkeyRegistrationStatus.Conflict, result.Status);
        Assert.AreEqual(original, coordinator.ActiveChord);
        Assert.HasCount(0, native.UnregisteredIds);
    }

    [TestMethod]
    public void SuccessfulChangeRegistersCandidateBeforeRemovingPreviousChord()
    {
        var native = new FakeRegistration();
        using var coordinator = new HotkeyRegistrationCoordinator(native);
        coordinator.Change(new HotkeyChord(HotkeyModifiers.Control, 65));

        var result = coordinator.Change(new HotkeyChord(HotkeyModifiers.Alt, 66));

        Assert.AreEqual(HotkeyRegistrationStatus.Registered, result.Status);
        CollectionAssert.AreEqual(new[] { "register:22272", "register:22273", "unregister:22272" }, native.Events);
    }

    private sealed class FakeRegistration : IHotkeyNativeRegistration
    {
        public bool AllowRegistration { get; set; } = true;
        public List<int> UnregisteredIds { get; } = [];
        public List<string> Events { get; } = [];

        public bool TryRegister(int id, HotkeyChord chord)
        {
            Events.Add($"register:{id}");
            return AllowRegistration;
        }

        public void Unregister(int id)
        {
            Events.Add($"unregister:{id}");
            UnregisteredIds.Add(id);
        }
    }
}
