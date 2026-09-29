using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Witness.Core.Licensing;

namespace Witness.Platform.Windows.Licensing;

public interface IEntitlementFileSystem
{
    bool Exists(string path);
    string ReadAllText(string path);
    void WriteAllText(string path, string contents);
    void MoveReplacing(string source, string destination);
    void DeleteIfExists(string path);
}

public sealed class LocalEntitlementFileSystem : IEntitlementFileSystem
{
    public bool Exists(string path) => File.Exists(path);
    public string ReadAllText(string path) => File.ReadAllText(path);

    public void WriteAllText(string path, string contents)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)
            ?? throw new ArgumentException("An entitlement directory is required.", nameof(path)));
        File.WriteAllText(path, contents);
    }

    public void MoveReplacing(string source, string destination) => File.Move(source, destination, overwrite: true);

    public void DeleteIfExists(string path)
    {
        if (File.Exists(path)) File.Delete(path);
    }
}

public sealed class EntitlementStoreException : Exception
{
    public EntitlementStoreException(string message, Exception innerException) : base(message, innerException) { }
}

/// <summary>
/// Stores exactly the five fields needed for offline entitlement decisions.
/// No transcript, glossary, application, microphone or diagnostic data can be
/// serialized through this fixed document type.
/// </summary>
public sealed class JsonEntitlementStore : IEntitlementStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        WriteIndented = true,
    };

    private readonly string path;
    private readonly IEntitlementFileSystem fileSystem;

    public JsonEntitlementStore(string path, IEntitlementFileSystem? fileSystem = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        this.path = Path.GetFullPath(path);
        this.fileSystem = fileSystem ?? new LocalEntitlementFileSystem();
    }

    public static string DefaultPath()
    {
        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localData))
            throw new InvalidOperationException("Windows did not provide a local application-data directory.");
        return Path.Combine(localData, "Witness", "license.json");
    }

    public UsageRecord? Load()
    {
        if (!fileSystem.Exists(path)) return null;
        try
        {
            var document = JsonSerializer.Deserialize<EntitlementDocument>(fileSystem.ReadAllText(path), JsonOptions)
                ?? throw new JsonException("The entitlement document is empty.");
            if (string.IsNullOrWhiteSpace(document.InstallId))
                throw new JsonException("The entitlement install ID is missing.");
            return new UsageRecord(
                document.InstalledAt,
                document.InstallId,
                document.FirstDictationAt,
                document.FurthestSeenAt,
                document.LicenseToken);
        }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            throw new EntitlementStoreException("The local license record could not be read.", exception);
        }
    }

    public void Save(UsageRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        var document = new EntitlementDocument(
            record.InstalledAt,
            record.InstallId,
            record.FirstDictationAt,
            record.FurthestSeenAt,
            record.LicenseToken);
        var temporaryPath = string.Concat(path, ".tmp");
        try
        {
            fileSystem.WriteAllText(temporaryPath, JsonSerializer.Serialize(document, JsonOptions));
            fileSystem.MoveReplacing(temporaryPath, path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            throw new EntitlementStoreException("The local license record could not be saved.", exception);
        }
        finally
        {
            fileSystem.DeleteIfExists(temporaryPath);
        }
    }

    private sealed record EntitlementDocument(
        DateTimeOffset InstalledAt,
        string InstallId,
        DateTimeOffset? FirstDictationAt,
        DateTimeOffset FurthestSeenAt,
        string? LicenseToken);
}
