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
    public void ReportedNamesKeepAllProtocolsAndAdvertisementsWithoutChangingSelection()
    {
        DeviceNameCandidate[] names =
        [
            new("display name", DeviceNameSource.Ssdp),
            new("synthetic.local.", DeviceNameSource.Mdns),
            new("SYNTHETIC-PC", DeviceNameSource.NetBios),
            new("synthetic.example", DeviceNameSource.ReverseDns)
        ];
        var values = ScanResultEnricher.CollectReportedValues(
            [new("display name", null, null, null, null) { DeviceUuid = "synthetic-one" },
             new("Other SSDP name", null, null, null, null) { DeviceUuid = "synthetic-two" }], null, names);
        Assert.Equal("display name", DeviceNameResolver.SelectDisplayName(names));
        Assert.Equal(2, values.Count(item => item.Kind == ReportedDeviceValueKind.SsdpName));
        Assert.Equal(2, values.Count(item => item.Kind == ReportedDeviceValueKind.UpnpUuid));
        Assert.Contains(new(ReportedDeviceValueKind.MdnsName, "synthetic.local."), values);
        Assert.Contains(new(ReportedDeviceValueKind.NetBiosName, "SYNTHETIC-PC"), values);
        Assert.Contains(new(ReportedDeviceValueKind.ReverseDnsName, "synthetic.example"), values);
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
    public void MdnsQuery_RequestsMulticastRepliesWhenSharingStandardPort()
    {
        var query = DeviceNameResolver.CreateDnsQuery("_ipp._tcp.local", 12, requestUnicast: false);
        Assert.Equal(0, query[^2]);
        Assert.Equal(1, query[^1]);
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
        int[] original = [22, 53, 80, 443, 445, 554, 8008, 8009, 8080, 9100];
        int[] added = [139, 515, 631, 1883, 5357, 8123, 8888];

        Assert.Equal(original.Concat(added).Order(), PortScannerService.CommonPorts.Keys);
        Assert.Equal(17, PortScannerService.CommonPorts.Count);
        Assert.All(
            PortScannerService.CommonPorts,
            port => Assert.Equal(
                $"{port.Key}/TCP - {port.Value}",
                new OpenPort(port.Key, port.Value).AccessibleLabel));
    }

    [Fact]
    public void AdditionalPortDefinitions_AreBoundedAndDoNotRepeatCommonPorts()
    {
        int[] originalCatalogue = [20, 21, 23, 25, 110, 135, 139, 143, 389, 465, 587, 993, 995, 1433, 1521, 1883,
            3306, 3389, 5432, 5672, 5900, 6379, 8000, 8443, 8883, 115, 548, 873, 989, 990, 2049, 3260, 593, 5800,
            5901, 5902, 5985, 5986, 109, 119, 563, 2525, 4190, 88, 636, 464, 749, 3268, 3269, 3050, 7474, 7687,
            8529, 9042, 9160, 11211, 27017, 28015, 4222, 4369, 5671, 6650, 9092, 15672, 61613, 3000, 3001, 5000,
            5001, 8001, 8081, 8088, 8888, 9000, 9443, 5601, 8006, 9090, 10000, 1880, 3689, 5004, 6600, 7000, 8060,
            8096, 8920, 8123, 8200, 8384, 32400, 111, 179, 515, 631, 2375, 2376, 6443, 9101, 9200];
        var additional = PortScannerService.AdditionalPorts.Keys.ToArray();

        Assert.Equal(100, originalCatalogue.Distinct().Count());
        Assert.All(originalCatalogue.Except(PortScannerService.CommonPorts.Keys),
            port => Assert.Contains(port, additional));
        Assert.True(additional.Except(originalCatalogue).Count() >= 50, "Expected genuinely new service coverage.");
        Assert.InRange(additional.Length, originalCatalogue.Length + 1, 200);
        Assert.Equal(additional.Length, additional.Distinct().Count());
        Assert.All(PortScannerService.AdditionalPorts.Values, name => Assert.False(string.IsNullOrWhiteSpace(name)));
        Assert.Empty(PortScannerService.CommonPorts.Keys.Intersect(additional));
        Assert.All(additional, port => Assert.InRange(port, 1, 65_535));
    }
}
