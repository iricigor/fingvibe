using System.Net;

namespace FingVibe.Core.Networking;

public static class SubnetCalculator
{
    public static IPAddress GetNetworkAddress(IPAddress address, int prefixLength)
    {
        Validate(address, prefixLength);
        var mask = prefixLength == 0 ? 0u : uint.MaxValue << (32 - prefixLength);
        return FromUInt32(ToUInt32(address) & mask);
    }

    public static IPAddress GetBroadcastAddress(IPAddress address, int prefixLength)
    {
        Validate(address, prefixLength);
        var mask = prefixLength == 0 ? 0u : uint.MaxValue << (32 - prefixLength);
        return FromUInt32((ToUInt32(address) & mask) | ~mask);
    }

    public static int GetUsableHostCount(int prefixLength)
    {
        ValidatePrefix(prefixLength);

        if (prefixLength == 32)
        {
            return 1;
        }

        if (prefixLength == 31)
        {
            return 2;
        }

        var totalAddresses = 1L << (32 - prefixLength);
        var usableAddresses = totalAddresses - 2;
        return usableAddresses > int.MaxValue ? int.MaxValue : (int)usableAddresses;
    }

    public static IEnumerable<IPAddress> EnumerateUsableHosts(
        IPAddress networkAddress,
        int prefixLength,
        int maximumHosts = 65_534)
    {
        Validate(networkAddress, prefixLength);
        var hostCount = GetUsableHostCount(prefixLength);

        if (hostCount > maximumHosts)
        {
            throw new InvalidOperationException(
                $"The detected {prefixLength}-bit subnet contains {hostCount:N0} or more usable addresses. " +
                $"For safety, FingVibe scans at most {maximumHosts:N0} addresses at once.");
        }

        var start = ToUInt32(GetNetworkAddress(networkAddress, prefixLength));
        if (prefixLength <= 30)
        {
            start++;
        }

        for (var offset = 0; offset < hostCount; offset++)
        {
            yield return FromUInt32(start + (uint)offset);
        }
    }

    private static void Validate(IPAddress address, int prefixLength)
    {
        ArgumentNullException.ThrowIfNull(address);
        if (address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
        {
            throw new ArgumentException("Only IPv4 addresses are supported.", nameof(address));
        }

        ValidatePrefix(prefixLength);
    }

    private static void ValidatePrefix(int prefixLength)
    {
        if (prefixLength is < 0 or > 32)
        {
            throw new ArgumentOutOfRangeException(nameof(prefixLength), "IPv4 prefixes must be between 0 and 32.");
        }
    }

    private static uint ToUInt32(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return ((uint)bytes[0] << 24)
            | ((uint)bytes[1] << 16)
            | ((uint)bytes[2] << 8)
            | bytes[3];
    }

    private static IPAddress FromUInt32(uint address) =>
        new(new[]
        {
            (byte)(address >> 24),
            (byte)(address >> 16),
            (byte)(address >> 8),
            (byte)address
        });
}
