using System.Buffers.Binary;
using System.Globalization;
using System.Net;

namespace FingVibe.Core.Networking;

public sealed record SubnetDescription(
    string Badge,
    string BadgeLabel,
    string Size,
    string Mask,
    string AddressCount,
    string Scope);

public static class SubnetDescriptionFormatter
{
    private static readonly AddressRange[] SpecialRanges =
    [
        Range("0.0.0.0", 8, "Special-purpose scope: this network"),
        Range("10.0.0.0", 8, "Private", isPrivate: true),
        Range("100.64.0.0", 10, "Special-purpose scope: shared address space (CGNAT)"),
        Range("127.0.0.0", 8, "Special-purpose scope: loopback"),
        Range("169.254.0.0", 16, "Special-purpose scope: APIPA / link-local"),
        Range("172.16.0.0", 12, "Private", isPrivate: true),
        Range("192.0.0.0", 24, "Special-purpose scope: IETF protocol assignments"),
        Range("192.0.2.0", 24, "Special-purpose scope: documentation"),
        Range("192.31.196.0", 24, "Special-purpose scope: AS112"),
        Range("192.52.193.0", 24, "Special-purpose scope: automatic multicast tunneling"),
        Range("192.88.99.0", 24, "Special-purpose scope: deprecated 6to4 relay"),
        Range("192.168.0.0", 16, "Private", isPrivate: true),
        Range("192.175.48.0", 24, "Special-purpose scope: AS112"),
        Range("198.18.0.0", 15, "Special-purpose scope: benchmarking"),
        Range("198.51.100.0", 24, "Special-purpose scope: documentation"),
        Range("203.0.113.0", 24, "Special-purpose scope: documentation"),
        Range("224.0.0.0", 4, "Special-purpose scope: multicast"),
        Range("240.0.0.0", 4, "Special-purpose scope: reserved"),
        Range("255.255.255.255", 32, "Special-purpose scope: limited broadcast")
    ];

    public static SubnetDescription Format(IPAddress address, int prefixLength)
    {
        var start = ToUInt32(SubnetCalculator.GetNetworkAddress(address, prefixLength));
        var end = ToUInt32(SubnetCalculator.GetBroadcastAddress(address, prefixLength));
        var badge = prefixLength switch { 8 => "A", 16 => "B", 24 => "C", _ => $"/{prefixLength}" };

        return new SubnetDescription(
            badge,
            prefixLength is 8 or 16 or 24 ? "class" : "mask",
            FormatSize(prefixLength),
            $"Masked bits: /{prefixLength}",
            FormatAddressCount(prefixLength),
            FormatScope(start, end, prefixLength));
    }

    private static string FormatSize(int prefixLength) => prefixLength switch
    {
        0 => "Entire IPv4 address space / default route",
        1 => "Half of IPv4 address space",
        2 => "Quarter of IPv4 address space",
        3 => "Eighth of IPv4 address space",
        >= 4 and <= 7 => $"{1 << (8 - prefixLength)} \u00d7 A class",
        8 => "A class",
        >= 9 and <= 11 => $"A \u00f7 {1 << (prefixLength - 8)}",
        >= 12 and <= 15 => $"{1 << (16 - prefixLength)} \u00d7 B class",
        16 => "B class",
        >= 17 and <= 19 => $"B \u00f7 {1 << (prefixLength - 16)}",
        >= 20 and <= 23 => $"{1 << (24 - prefixLength)} \u00d7 C class",
        24 => "C class",
        >= 25 and <= 27 => $"C \u00f7 {1 << (prefixLength - 24)}",
        28 or 29 => "Small subnet",
        30 => "Two-host subnet / point-to-point link",
        31 => "Point-to-point subnet",
        32 => "Single host",
        _ => throw new ArgumentOutOfRangeException(nameof(prefixLength))
    };

    private static string FormatAddressCount(int prefixLength)
    {
        // Display capacity is not capped by the scanner's safety limit.
        var total = 1UL << (32 - prefixLength);
        var usable = prefixLength is 0 or >= 31 ? total : total - 2;
        if (usable >= 1_000_000)
        {
            var magnitude = Math.Pow(10, Math.Floor(Math.Log10(usable)) - 1);
            var millions = Math.Round(usable / magnitude, MidpointRounding.AwayFromZero)
                * magnitude / 1_000_000;
            var number = millions.ToString(millions < 10 ? "0.0" : "0", CultureInfo.CurrentCulture);
            return $"{number}M IP addresses";
        }

        var label = usable == 1 ? "IP address" : "IP addresses";
        var reserved = prefixLength is >= 17 and <= 30 ? " + 2 reserved" : "";
        return $"{usable.ToString("N0", CultureInfo.CurrentCulture)} {label}{reserved}";
    }

    private static string FormatScope(uint start, uint end, int prefixLength)
    {
        // More-specific ranges take precedence, e.g. limited broadcast within 240/4.
        foreach (var range in SpecialRanges.OrderBy(range => (ulong)range.End - range.Start))
        {
            if (start >= range.Start && end <= range.End)
            {
                return range.IsPrivate
                    ? prefixLength is 8 or 16 or 24
                        ? "Standard-size private subnet"
                        : "Non-standard-size private subnet"
                    : range.Name;
            }
        }

        return SpecialRanges.Any(range => start <= range.End && end >= range.Start)
            ? "Mixed scope: spans private, public, or special-purpose ranges"
            : "Public scope";
    }

    private static AddressRange Range(string address, int prefixLength, string name, bool isPrivate = false)
    {
        var ip = IPAddress.Parse(address);
        return new AddressRange(
            ToUInt32(SubnetCalculator.GetNetworkAddress(ip, prefixLength)),
            ToUInt32(SubnetCalculator.GetBroadcastAddress(ip, prefixLength)),
            name,
            isPrivate);
    }

    private static uint ToUInt32(IPAddress address) =>
        BinaryPrimitives.ReadUInt32BigEndian(address.GetAddressBytes());

    private sealed record AddressRange(uint Start, uint End, string Name, bool IsPrivate);
}
