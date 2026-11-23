using System.Globalization;
using System.Net;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SubnetDescriptionFormatterTests
{
    [Theory]
    [InlineData(0, "Entire IPv4 address space / default route", "4300M IP addresses")]
    [InlineData(1, "Half of IPv4 address space", "2100M IP addresses")]
    [InlineData(2, "Quarter of IPv4 address space", "1100M IP addresses")]
    [InlineData(3, "Eighth of IPv4 address space", "540M IP addresses")]
    [InlineData(4, "16 \u00d7 A class", "270M IP addresses")]
    [InlineData(5, "8 \u00d7 A class", "130M IP addresses")]
    [InlineData(6, "4 \u00d7 A class", "67M IP addresses")]
    [InlineData(7, "2 \u00d7 A class", "34M IP addresses")]
    [InlineData(8, "A class", "17M IP addresses")]
    [InlineData(9, "A \u00f7 2", "8.4M IP addresses")]
    [InlineData(10, "A \u00f7 4", "4.2M IP addresses")]
    [InlineData(11, "A \u00f7 8", "2.1M IP addresses")]
    [InlineData(12, "16 \u00d7 B class", "1.0M IP addresses")]
    [InlineData(13, "8 \u00d7 B class", "524286 IP addresses")]
    [InlineData(14, "4 \u00d7 B class", "262142 IP addresses")]
    [InlineData(15, "2 \u00d7 B class", "131070 IP addresses")]
    [InlineData(16, "B class", "65534 IP addresses")]
    [InlineData(17, "B \u00f7 2", "32766 IP addresses + 2 reserved")]
    [InlineData(18, "B \u00f7 4", "16382 IP addresses + 2 reserved")]
    [InlineData(19, "B \u00f7 8", "8190 IP addresses + 2 reserved")]
    [InlineData(20, "16 \u00d7 C class", "4094 IP addresses + 2 reserved")]
    [InlineData(21, "8 \u00d7 C class", "2046 IP addresses + 2 reserved")]
    [InlineData(22, "4 \u00d7 C class", "1022 IP addresses + 2 reserved")]
    [InlineData(23, "2 \u00d7 C class", "510 IP addresses + 2 reserved")]
    [InlineData(24, "C class", "254 IP addresses + 2 reserved")]
    [InlineData(25, "C \u00f7 2", "126 IP addresses + 2 reserved")]
    [InlineData(26, "C \u00f7 4", "62 IP addresses + 2 reserved")]
    [InlineData(27, "C \u00f7 8", "30 IP addresses + 2 reserved")]
    [InlineData(28, "Small subnet", "14 IP addresses + 2 reserved")]
    [InlineData(29, "Small subnet", "6 IP addresses + 2 reserved")]
    [InlineData(30, "Two-host subnet / point-to-point link", "2 IP addresses + 2 reserved")]
    [InlineData(31, "Point-to-point subnet", "2 IP addresses")]
    [InlineData(32, "Single host", "1 IP address")]
    public void Format_ExplainsEveryPrefix(int prefix, string size, string addressCount)
    {
        var result = SubnetDescriptionFormatter.Format(IPAddress.Parse("192.168.10.123"), prefix);

        Assert.Equal(size, result.Size);
        Assert.Equal($"Masked bits: /{prefix}", result.Mask);
        var normalizedCount = result.AddressCount.Contains('M')
            ? result.AddressCount.Replace(CultureInfo.CurrentCulture.NumberFormat.NumberDecimalSeparator, ".")
            : result.AddressCount.Replace(CultureInfo.CurrentCulture.NumberFormat.NumberGroupSeparator, "");
        Assert.Equal(addressCount, normalizedCount);

        var badge = prefix switch { 8 => "A", 16 => "B", 24 => "C", _ => $"/{prefix}" };
        Assert.Equal(badge, result.Badge);
        Assert.Equal(prefix is 8 or 16 or 24 ? "class" : "mask", result.BadgeLabel);
    }

    [Fact]
    public void Format_UsesCurrentCultureForExactAndRoundedCounts()
    {
        var originalCulture = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("de-DE");
            Assert.Equal("8,4M IP addresses", Describe("10.0.0.1", 9).AddressCount);
            Assert.Equal("65.534 IP addresses", Describe("192.168.0.1", 16).AddressCount);
        }
        finally
        {
            CultureInfo.CurrentCulture = originalCulture;
        }
    }

    [Theory]
    [InlineData("10.0.0.1", 8)]
    [InlineData("10.2.3.4", 16)]
    [InlineData("172.16.0.1", 16)]
    [InlineData("172.31.255.254", 24)]
    [InlineData("192.168.10.1", 24)]
    [InlineData("192.168.255.254", 16)]
    public void Format_IdentifiesStandardSizePrivateSubnets(string address, int prefix) =>
        Assert.Equal("Standard-size private subnet", Describe(address, prefix).Scope);

    [Theory]
    [InlineData("10.0.0.0", 9)]
    [InlineData("172.16.0.0", 12)]
    [InlineData("192.168.10.128", 25)]
    [InlineData("192.168.10.0", 23)]
    [InlineData("192.168.255.255", 32)]
    public void Format_IdentifiesOtherPrivateSizes(string address, int prefix) =>
        Assert.Equal("Non-standard-size private subnet", Describe(address, prefix).Scope);

    [Theory]
    [InlineData("8.8.8.8", 24)]
    [InlineData("9.255.255.255", 32)]
    [InlineData("11.0.0.0", 8)]
    [InlineData("100.63.255.255", 32)]
    [InlineData("100.128.0.0", 32)]
    [InlineData("169.253.255.255", 32)]
    [InlineData("169.255.0.0", 32)]
    [InlineData("172.15.255.255", 32)]
    [InlineData("172.32.0.0", 32)]
    [InlineData("192.167.255.255", 32)]
    [InlineData("192.169.0.0", 32)]
    [InlineData("223.255.255.255", 32)]
    public void Format_IdentifiesPublicScopeOutsidePrivateAndSpecialRanges(string address, int prefix) =>
        Assert.Equal("Public scope", Describe(address, prefix).Scope);

    [Theory]
    [InlineData("0.0.0.0", 8, "this network")]
    [InlineData("100.64.0.0", 10, "shared address space (CGNAT)")]
    [InlineData("100.127.255.255", 32, "shared address space (CGNAT)")]
    [InlineData("127.0.0.1", 8, "loopback")]
    [InlineData("169.254.0.0", 16, "APIPA / link-local")]
    [InlineData("169.254.255.255", 32, "APIPA / link-local")]
    [InlineData("192.0.0.0", 24, "IETF protocol assignments")]
    [InlineData("192.0.2.1", 24, "documentation")]
    [InlineData("192.31.196.1", 24, "AS112")]
    [InlineData("192.52.193.1", 24, "automatic multicast tunneling")]
    [InlineData("192.88.99.1", 24, "deprecated 6to4 relay")]
    [InlineData("192.175.48.1", 24, "AS112")]
    [InlineData("198.18.0.0", 15, "benchmarking")]
    [InlineData("198.51.100.1", 24, "documentation")]
    [InlineData("203.0.113.1", 24, "documentation")]
    [InlineData("224.0.0.1", 4, "multicast")]
    [InlineData("239.255.255.255", 32, "multicast")]
    [InlineData("240.0.0.1", 4, "reserved")]
    [InlineData("255.255.255.254", 32, "reserved")]
    [InlineData("255.255.255.255", 32, "limited broadcast")]
    public void Format_NamesSpecialPurposeRanges(string address, int prefix, string scope) =>
        Assert.Equal($"Special-purpose scope: {scope}", Describe(address, prefix).Scope);

    [Theory]
    [InlineData("0.0.0.0", 0)]
    [InlineData("10.0.0.1", 7)]
    [InlineData("172.16.0.1", 11)]
    [InlineData("192.168.10.1", 15)]
    [InlineData("169.254.10.1", 15)]
    [InlineData("198.51.100.1", 23)]
    public void Format_DoesNotClassifyMixedSubnetsByOneAddress(string address, int prefix) =>
        Assert.StartsWith("Mixed scope:", Describe(address, prefix).Scope);

    [Theory]
    [InlineData(-1)]
    [InlineData(33)]
    public void Format_RejectsInvalidPrefixes(int prefix) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => Describe("192.168.10.1", prefix));

    [Fact]
    public void Format_RejectsIpv6() =>
        Assert.Throws<ArgumentException>(() => SubnetDescriptionFormatter.Format(IPAddress.IPv6Loopback, 24));

    [Fact]
    public void Format_RejectsMissingAddress() =>
        Assert.Throws<ArgumentNullException>(() => SubnetDescriptionFormatter.Format(null!, 24));

    private static SubnetDescription Describe(string address, int prefix) =>
        SubnetDescriptionFormatter.Format(IPAddress.Parse(address), prefix);
}
