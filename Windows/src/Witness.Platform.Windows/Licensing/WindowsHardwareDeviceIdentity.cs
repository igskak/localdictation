using System.Buffers.Binary;
using System.Runtime.InteropServices;
using Witness.Core.Licensing;

namespace Witness.Platform.Windows.Licensing;

public interface IRawSmbiosProvider
{
    byte[]? Read();
}

public sealed record DeviceIdentityResult(string? DeviceId, string? Error)
{
    public bool IsAvailable => DeviceId is not null;
}

public sealed class WindowsHardwareDeviceIdentity
{
    private readonly IRawSmbiosProvider provider;

    public WindowsHardwareDeviceIdentity(IRawSmbiosProvider? provider = null)
    {
        this.provider = provider ?? new NativeRawSmbiosProvider();
    }

    public DeviceIdentityResult Resolve()
    {
        var firmware = provider.Read();
        if (firmware is null)
        {
            return Unavailable();
        }

        var uuid = RawSmbiosSystemUuid.TryRead(firmware);
        if (uuid is null || !DeviceIdentityDerivation.TryDerive(uuid, out var deviceId))
        {
            return Unavailable();
        }

        return new DeviceIdentityResult(deviceId, null);
    }

    private static DeviceIdentityResult Unavailable() => new(
        null,
        "Windows did not provide a usable hardware identity. Activation is unavailable on this computer.");
}

public static class RawSmbiosSystemUuid
{
    private const int RawHeaderLength = 8;
    private const int StructureHeaderLength = 4;
    private const int SystemInformationType = 1;
    private const int EndOfTableType = 127;
    private const int SystemUuidOffset = 8;
    private const int SystemUuidLength = 16;

    public static string? TryRead(ReadOnlySpan<byte> rawTable)
    {
        if (rawTable.Length < RawHeaderLength)
        {
            return null;
        }

        var major = rawTable[1];
        var minor = rawTable[2];
        var declaredLength = BinaryPrimitives.ReadUInt32LittleEndian(rawTable.Slice(4, 4));
        if (declaredLength > int.MaxValue || declaredLength > rawTable.Length - RawHeaderLength)
        {
            return null;
        }

        var table = rawTable.Slice(RawHeaderLength, (int)declaredLength);
        var offset = 0;
        while (offset + StructureHeaderLength <= table.Length)
        {
            var type = table[offset];
            var formattedLength = table[offset + 1];
            if (formattedLength < StructureHeaderLength || offset + formattedLength > table.Length)
            {
                return null;
            }
            if (type == EndOfTableType)
            {
                return null;
            }
            if (type == SystemInformationType && formattedLength >= SystemUuidOffset + SystemUuidLength)
            {
                var bytes = table.Slice(offset + SystemUuidOffset, SystemUuidLength);
                if (All(bytes, 0x00) || All(bytes, 0xff))
                {
                    return null;
                }
                return IsSmbios26OrNewer(major, minor)
                    ? new Guid(bytes).ToString("D").ToLowerInvariant()
                    : FormatNetworkOrderUuid(bytes);
            }

            var strings = offset + formattedLength;
            var terminator = FindDoubleNull(table, strings);
            if (terminator < 0)
            {
                return null;
            }
            offset = terminator + 2;
        }

        return null;
    }

    private static bool IsSmbios26OrNewer(byte major, byte minor) => major > 2 || major == 2 && minor >= 6;

    private static string FormatNetworkOrderUuid(ReadOnlySpan<byte> bytes)
    {
        var hex = Convert.ToHexStringLower(bytes);
        return $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..]}";
    }

    private static bool All(ReadOnlySpan<byte> bytes, byte value)
    {
        foreach (var item in bytes)
        {
            if (item != value) return false;
        }
        return true;
    }

    private static int FindDoubleNull(ReadOnlySpan<byte> bytes, int start)
    {
        for (var index = start; index + 1 < bytes.Length; index++)
        {
            if (bytes[index] == 0 && bytes[index + 1] == 0) return index;
        }
        return -1;
    }
}

public sealed class NativeRawSmbiosProvider : IRawSmbiosProvider
{
    private const uint RawSmbiosProvider = 0x52534d42; // 'RSMB'
    private const uint MaximumFirmwareTableBytes = 4 * 1024 * 1024;

    public byte[]? Read()
    {
        var required = GetSystemFirmwareTable(RawSmbiosProvider, 0, null, 0);
        if (required == 0 || required > MaximumFirmwareTableBytes)
        {
            return null;
        }

        var buffer = new byte[required];
        var written = GetSystemFirmwareTable(RawSmbiosProvider, 0, buffer, required);
        if (written == 0 || written > required)
        {
            return null;
        }
        return written == required ? buffer : buffer[..(int)written];
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetSystemFirmwareTable(
        uint firmwareTableProviderSignature,
        uint firmwareTableId,
        [Out] byte[]? firmwareTableBuffer,
        uint bufferSize);
}
