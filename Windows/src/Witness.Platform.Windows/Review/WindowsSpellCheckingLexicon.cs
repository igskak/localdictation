using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Witness.Core.Languages;
using Witness.Core.Review;

namespace Witness.Platform.Windows.Review;

public interface IWindowsSpellCheckNative
{
    bool TryResolveLanguageTag(IReadOnlyList<string> candidates, out string languageTag);
    bool TryIsKnownWord(string languageTag, string word, out bool isKnown);
}

/// <summary>
/// Reports only dictionaries the current Windows account actually has. A
/// missing dictionary or any COM failure disables malformed-word warnings for
/// that language rather than turning platform uncertainty into a warning.
/// </summary>
public sealed class WindowsSpellCheckingLexicon : ILexicon
{
    private static readonly IReadOnlyDictionary<SpeechLanguage, IReadOnlyList<string>> CandidateTags =
        new Dictionary<SpeechLanguage, IReadOnlyList<string>>
        {
            [SpeechLanguage.German] = ["de-DE", "de-AT", "de-CH"],
            [SpeechLanguage.English] = ["en-US", "en-GB", "en-CA", "en-AU"],
            [SpeechLanguage.Russian] = ["ru-RU"],
            [SpeechLanguage.Ukrainian] = ["uk-UA"],
        };

    private readonly IWindowsSpellCheckNative native;
    private readonly ConcurrentDictionary<SpeechLanguage, Capability> capabilities = new();

    public WindowsSpellCheckingLexicon(IWindowsSpellCheckNative? native = null) =>
        this.native = native ?? new ComWindowsSpellCheckNative();

    public bool Supports(SpeechLanguage language) => CapabilityFor(language).Supported;

    public bool IsKnownWord(string word, SpeechLanguage language)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(word);
        var capability = CapabilityFor(language);
        if (!capability.Supported || capability.LanguageTag is null)
        {
            return true;
        }

        return native.TryIsKnownWord(capability.LanguageTag, word, out var isKnown)
            ? isKnown
            : true;
    }

    private Capability CapabilityFor(SpeechLanguage language) =>
        capabilities.GetOrAdd(language, Resolve);

    private Capability Resolve(SpeechLanguage language)
    {
        if (!language.IsVerified || !CandidateTags.TryGetValue(language, out var candidates))
        {
            return Capability.Unsupported;
        }
        return native.TryResolveLanguageTag(candidates, out var languageTag)
            ? new Capability(true, languageTag)
            : Capability.Unsupported;
    }

    private sealed record Capability(bool Supported, string? LanguageTag)
    {
        public static Capability Unsupported { get; } = new(false, null);
    }
}

public sealed class ComWindowsSpellCheckNative : IWindowsSpellCheckNative
{
    public bool TryResolveLanguageTag(IReadOnlyList<string> candidates, out string languageTag)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        languageTag = string.Empty;
        object? factoryObject = null;
        try
        {
            factoryObject = Activator.CreateInstance(
                Type.GetTypeFromCLSID(SpellCheckInterop.SpellCheckerFactoryClassId, throwOnError: true)!);
            var factory = (SpellCheckInterop.ISpellCheckerFactory)factoryObject!;
            foreach (var candidate in candidates)
            {
                if (factory.IsSupported(candidate, out var supported) >= 0 && supported)
                {
                    languageTag = candidate;
                    return true;
                }
            }
            return false;
        }
        catch (COMException)
        {
            return false;
        }
        catch (PlatformNotSupportedException)
        {
            return false;
        }
        finally
        {
            Release(factoryObject);
        }
    }

    public bool TryIsKnownWord(string languageTag, string word, out bool isKnown)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(languageTag);
        ArgumentException.ThrowIfNullOrWhiteSpace(word);
        isKnown = true;
        object? factoryObject = null;
        SpellCheckInterop.ISpellChecker? checker = null;
        SpellCheckInterop.IEnumSpellingError? errors = null;
        SpellCheckInterop.ISpellingError? error = null;
        try
        {
            factoryObject = Activator.CreateInstance(
                Type.GetTypeFromCLSID(SpellCheckInterop.SpellCheckerFactoryClassId, throwOnError: true)!);
            var factory = (SpellCheckInterop.ISpellCheckerFactory)factoryObject!;
            if (factory.CreateSpellChecker(languageTag, out checker) < 0 || checker is null)
            {
                return false;
            }
            if (checker.Check(word, out errors) < 0 || errors is null)
            {
                return false;
            }

            var next = errors.Next(out error);
            if (next == SpellCheckInterop.NoMoreItems)
            {
                isKnown = true;
                return true;
            }
            if (next >= 0 && error is not null)
            {
                isKnown = false;
                return true;
            }
            return false;
        }
        catch (COMException)
        {
            return false;
        }
        catch (PlatformNotSupportedException)
        {
            return false;
        }
        finally
        {
            Release(error);
            Release(errors);
            Release(checker);
            Release(factoryObject);
        }
    }

    private static void Release(object? value)
    {
        if (value is not null && Marshal.IsComObject(value))
        {
            Marshal.ReleaseComObject(value);
        }
    }
}

internal static class SpellCheckInterop
{
    internal const int NoMoreItems = 1;
    internal static readonly Guid SpellCheckerFactoryClassId =
        new("7AB36653-1796-484B-BDFA-E74F1DB7C1DC");

    [ComImport]
    [Guid("8E018A9D-2415-4677-BF08-794EA61F94BB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISpellCheckerFactory
    {
        [PreserveSig]
        int GetSupportedLanguages(out nint value);

        [PreserveSig]
        int IsSupported(
            [MarshalAs(UnmanagedType.LPWStr)] string languageTag,
            [MarshalAs(UnmanagedType.Bool)] out bool value);

        [PreserveSig]
        int CreateSpellChecker(
            [MarshalAs(UnmanagedType.LPWStr)] string languageTag,
            [MarshalAs(UnmanagedType.Interface)] out ISpellChecker? value);
    }

    [ComImport]
    [Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISpellChecker
    {
        [PreserveSig]
        int GetLanguageTag(out nint value);

        [PreserveSig]
        int Check(
            [MarshalAs(UnmanagedType.LPWStr)] string text,
            [MarshalAs(UnmanagedType.Interface)] out IEnumSpellingError? value);
    }

    [ComImport]
    [Guid("803E3BD4-2828-4410-8290-418D1D73C762")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IEnumSpellingError
    {
        [PreserveSig]
        int Next([MarshalAs(UnmanagedType.Interface)] out ISpellingError? value);
    }

    [ComImport]
    [Guid("B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ISpellingError
    {
    }
}
