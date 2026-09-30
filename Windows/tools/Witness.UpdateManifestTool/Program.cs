using System.Security.Cryptography;
using System.Text.Json;
using NSec.Cryptography;
using Witness.Core;
using Witness.Update;

namespace Witness.UpdateManifestTool;

internal static class Program
{
    private const string PrivateKeyEnvironment = "WITNESS_UPDATE_SIGNING_PRIVATE_KEY";
    private const string PublicKeyEnvironment = "WITNESS_UPDATE_MANIFEST_PUBLIC_KEY";

    public static int Main(string[] arguments)
    {
        try
        {
            var options = Parse(arguments);
            var packagePath = Path.GetFullPath(Required(options, "package"));
            var outputPath = Path.GetFullPath(Required(options, "output"));
            var releaseNotesPath = Path.GetFullPath(Required(options, "release-notes"));
            var packageUri = RequirePackageUri(Required(options, "package-url"));
            var packageHosts = RequirePackageHosts(Required(options, "package-hosts"));
            if (!packageHosts.Contains(packageUri.Host))
                throw new ArgumentException("--package-url host must be present in --package-hosts.");
            var version = Required(options, "version");
            if (!Velopack.SemanticVersion.TryParse(version, out _))
                throw new ArgumentException("--version must be a semantic version.");
            if (!int.TryParse(Required(options, "build"), out var build) || build <= 0)
                throw new ArgumentException("--build must be a positive integer.");
            var keyId = Required(options, "key-id");
            if (keyId.Length > 80
                || keyId.Any(character => !(char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-')))
                throw new ArgumentException("--key-id must contain 1-80 ASCII letters, digits, dots, underscores or hyphens.");
            if (!File.Exists(packagePath)) throw new FileNotFoundException("The full update package does not exist.", packagePath);
            if (!packagePath.EndsWith(".nupkg", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("--package must name a full .nupkg.");
            var releaseNotes = File.ReadAllText(releaseNotesPath);
            if (releaseNotes.Length > 16 * 1024)
                throw new ArgumentException("Release notes exceed the signed manifest limit.");

            var seed = DecodeExactEnvironment(PrivateKeyEnvironment, 32);
            var expectedPublicKey = DecodeExactEnvironment(PublicKeyEnvironment, 32);
            try
            {
                using var key = Key.Import(SignatureAlgorithm.Ed25519, seed, KeyBlobFormat.RawPrivateKey);
                var actualPublicKey = key.PublicKey.Export(KeyBlobFormat.RawPublicKey);
                if (!CryptographicOperations.FixedTimeEquals(actualPublicKey, expectedPublicKey))
                    throw new CryptographicException("The signing seed does not match the configured update public key.");

                using var package = File.OpenRead(packagePath);
                var manifest = new UpdateManifest
                {
                    Schema = 1,
                    Platform = "windows",
                    Architecture = ProductMetadata.Architecture,
                    Channel = ProductMetadata.Channel,
                    PackageId = ProductMetadata.WindowsAppId,
                    Version = version,
                    Build = build,
                    ReleaseUrl = packageUri.AbsoluteUri,
                    Size = package.Length,
                    Sha256 = Convert.ToHexStringLower(SHA256.HashData(package)),
                    MinimumOs = ProductMetadata.MinimumWindowsVersion,
                    ProductMajor = ProductMetadata.ProductMajor,
                    ReleaseNotes = releaseNotes,
                };
                var jsonOptions = new JsonSerializerOptions
                {
                    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                    WriteIndented = false,
                };
                var manifestBytes = JsonSerializer.SerializeToUtf8Bytes(manifest, jsonOptions);
                var envelope = new SignedUpdateEnvelope
                {
                    Schema = 1,
                    KeyId = keyId,
                    Manifest = Convert.ToBase64String(manifestBytes),
                    Signature = Convert.ToBase64String(SignatureAlgorithm.Ed25519.Sign(key, manifestBytes)),
                };
                var envelopeBytes = JsonSerializer.SerializeToUtf8Bytes(envelope, jsonOptions);
                Directory.CreateDirectory(Path.GetDirectoryName(outputPath)
                    ?? throw new ArgumentException("--output must include a directory."));
                var temporaryPath = outputPath + ".tmp";
                try
                {
                    File.WriteAllBytes(temporaryPath, envelopeBytes);
                    File.Move(temporaryPath, outputPath, overwrite: true);
                }
                finally
                {
                    File.Delete(temporaryPath);
                }
                Console.WriteLine($"Signed {Path.GetFileName(packagePath)} as {Path.GetFileName(outputPath)} with key {keyId}.");
            }
            finally
            {
                CryptographicOperations.ZeroMemory(seed);
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.Message);
            return 1;
        }
    }

    private static Dictionary<string, string> Parse(string[] arguments)
    {
        if (arguments.Length == 0 || arguments.Length % 2 != 0)
            throw new ArgumentException("Expected --package, --package-url, --package-hosts, --output, --release-notes, --version, --build and --key-id values.");
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < arguments.Length; index += 2)
        {
            var option = arguments[index];
            if (!option.StartsWith("--", StringComparison.Ordinal) || !result.TryAdd(option[2..], arguments[index + 1]))
                throw new ArgumentException($"Invalid or repeated option: {option}.");
        }
        return result;
    }

    private static string Required(IReadOnlyDictionary<string, string> options, string name) =>
        options.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"--{name} is required.");

    private static Uri RequirePackageUri(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || !string.IsNullOrEmpty(uri.UserInfo)
            || !string.IsNullOrEmpty(uri.Query)
            || !string.IsNullOrEmpty(uri.Fragment)
            || !uri.AbsolutePath.EndsWith(".nupkg", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("--package-url must be an exact HTTPS .nupkg URL without credentials, query or fragment.");
        return uri;
    }

    private static HashSet<string> RequirePackageHosts(string value)
    {
        var hosts = value
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (hosts.Count == 0 || hosts.Any(host => Uri.CheckHostName(host) == UriHostNameType.Unknown))
            throw new ArgumentException("--package-hosts must contain comma-separated bare DNS names or IP addresses.");
        return hosts;
    }

    private static byte[] DecodeExactEnvironment(string name, int length)
    {
        var value = Environment.GetEnvironmentVariable(name);
        if (string.IsNullOrWhiteSpace(value)) throw new InvalidOperationException($"{name} is required.");
        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(value);
        }
        catch (FormatException error)
        {
            throw new InvalidOperationException($"{name} must be valid Base64.", error);
        }
        if (bytes.Length != length)
        {
            CryptographicOperations.ZeroMemory(bytes);
            throw new InvalidOperationException($"{name} must contain exactly {length} bytes.");
        }
        return bytes;
    }
}
