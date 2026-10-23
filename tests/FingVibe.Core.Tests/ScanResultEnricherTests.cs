using System.Net;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanResultEnricherTests
{
    [Fact]
    public async Task EnrichAsync_PreservesDiscoveredSsdpNameAndReturnsEnrichmentData()
    {
        var address = IPAddress.IPv6Loopback;
        var names = new Dictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>>
        {
            [address] = [new("Living Room TV", "urn:schemas-upnp-org:device:MediaRenderer:1",
                null, null, "Linux/5.0 UPnP/1.0")]
        };
        var enricher = new ScanResultEnricher(
            new DeviceNameResolver(TimeSpan.Zero),
            new PortScannerService(TimeSpan.Zero),
            new MacAddressResolver(),
            new IeeeVendorRegistry(),
            new MdnsDeviceDiscoveryService(TimeSpan.Zero));

        var result = await enricher.EnrichAsync(
            address,
            Task.FromResult<IReadOnlyDictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>>>(names),
            CancellationToken.None);

        Assert.Equal("Living Room TV", result.DeviceName);
        Assert.Null(result.MacAddress);
        Assert.Equal("Unknown", result.VendorName);
        Assert.Equal(Models.DeviceOperatingSystem.Linux, result.Classification!.OperatingSystem);
        Assert.Equal(Models.DeviceType.MediaDevice, result.Classification.Type);
        Assert.All(
            result.OpenPorts,
            port => Assert.Equal(PortScannerService.CommonPorts[port.Port], port.ServiceName));
    }
}
