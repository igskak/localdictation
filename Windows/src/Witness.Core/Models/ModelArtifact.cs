namespace Witness.Core.Models;

public sealed record ModelArtifact(
    string Id,
    string Revision,
    string FileName,
    Uri DownloadUri,
    long SizeBytes,
    string Sha256,
    string License)
{
    public void Validate()
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(Id);
        ArgumentException.ThrowIfNullOrWhiteSpace(Revision);
        ArgumentException.ThrowIfNullOrWhiteSpace(FileName);
        ArgumentException.ThrowIfNullOrWhiteSpace(Sha256);
        ArgumentException.ThrowIfNullOrWhiteSpace(License);

        if (!string.Equals(FileName, Path.GetFileName(FileName), StringComparison.Ordinal)
            || FileName is "." or "..")
        {
            throw new ArgumentException("The model file name must not contain a path.", nameof(FileName));
        }

        if (!DownloadUri.IsAbsoluteUri || DownloadUri.Scheme != Uri.UriSchemeHttps)
        {
            throw new ArgumentException("The model download URI must use HTTPS.", nameof(DownloadUri));
        }

        if (SizeBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(SizeBytes));
        }

        if (Sha256.Length != 64
            || Sha256.Any(character => !Uri.IsHexDigit(character) || char.IsUpper(character)))
        {
            throw new ArgumentException("The model SHA-256 must be 64 lowercase hexadecimal characters.", nameof(Sha256));
        }
    }
}
