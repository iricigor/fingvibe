using System.Net.NetworkInformation;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceEnrichmentTests
{
    [Fact]
    public void VendorLookup_UsesLongestMatchingPrefix()
    {
        const string registries = """
            Registry,Assignment,Organization Name,Organization Address
            MA-L,001122,Broad Vendor,
            MA-M,0011223,Medium Vendor,
            MA-S,001122334,Specific Vendor,
            """;
        var lookup = VendorPrefixLookup.Parse([registries]);

        var vendor = lookup.Resolve(PhysicalAddress.Parse("00-11-22-33-44-55"));

        Assert.Equal("Specific Vendor", vendor);
    }

    [Theory]
    [InlineData("02-00-00-00-00-01", true)]
    [InlineData("06-00-00-00-00-01", true)]
    [InlineData("00-11-22-33-44-55", false)]
    public void PrivateMacDetection_UsesLocallyAdministeredBit(string value, bool expected)
    {
        var address = PhysicalAddress.Parse(value);

        Assert.Equal(expected, MacAddressResolver.IsPrivateOrRandomized(address));
    }

    [Fact]
    public void NameSelection_UsesDeterministicSourcePrecedence()
    {
        DeviceNameCandidate[] candidates =
        [
            new("reverse.example", DeviceNameSource.ReverseDns),
            new("OFFICE-PC", DeviceNameSource.NetBios),
            new("Living Room TV", DeviceNameSource.Ssdp)
        ];

        var name = DeviceNameResolver.SelectDisplayName(candidates);

        Assert.Equal("Living Room TV", name);
    }

    [Fact]
    public void NameSelection_TrimsWhitespaceAndMdnsSuffixDot()
    {
        DeviceNameCandidate[] candidates =
        [
            new(" printer.local. ", DeviceNameSource.Mdns)
        ];

        var name = DeviceNameResolver.SelectDisplayName(candidates);

        Assert.Equal("printer.local", name);
    }

    [Fact]
    public void MdnsQuery_RequestsUnicastPtrResponse()
    {
        var query = DeviceNameResolver.CreateDnsQuery("1.0.168.192.in-addr.arpa", 12);

        Assert.Equal(1, query[5]);
        Assert.Equal(12, query[^3]);
        Assert.Equal(0x80, query[^2]);
        Assert.Equal(0x01, query[^1]);
    }

    [Fact]
    public void MdnsParser_ReadsPtrHostName()
    {
        byte[] response =
        [
            0,
            0,
            0x84,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            12,
            0,
            1,
            0,
            0,
            0,
            120,
            0,
            14,
            6,
            (byte)'d',
            (byte)'e',
            (byte)'v',
            (byte)'i',
            (byte)'c',
            (byte)'e',
            5,
            (byte)'l',
            (byte)'o',
            (byte)'c',
            (byte)'a',
            (byte)'l',
            0
        ];

        var name = DeviceNameResolver.ParsePtrResponse(response);

        Assert.Equal("device.local", name);
    }

    [Fact]
    public void CommonPortDefinitions_AreStableAndHaveAccessibleLabels()
    {
        var expectedPorts = new[] { 22, 53, 80, 443, 445, 554, 8008, 8009, 8080, 9100 };

        Assert.Equal(expectedPorts, PortScannerService.CommonPorts.Keys);
        Assert.All(
            PortScannerService.CommonPorts,
            port => Assert.Equal(
                $"{port.Key} {port.Value}",
                new OpenPort(port.Key, port.Value).AccessibleLabel));
    }

    [Fact]
    public void AdditionalPortDefinitions_AreBoundedAndDoNotRepeatCommonPorts()
    {
        Assert.InRange(PortScannerService.AdditionalPorts.Count, 1, 32);
        Assert.Empty(PortScannerService.CommonPorts.Keys.Intersect(PortScannerService.AdditionalPorts.Keys));
        Assert.All(PortScannerService.AdditionalPorts.Keys, port => Assert.InRange(port, 1, 65_535));
    }
}
