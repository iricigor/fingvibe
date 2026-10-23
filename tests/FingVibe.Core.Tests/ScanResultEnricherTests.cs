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
        var names = new Dictionary<IPAddress, string>
        {
            [address] = "Living Room TV"
        };
        var enricher = new ScanResultEnricher(
            new DeviceNameResolver(TimeSpan.Zero),
            new PortScannerService(TimeSpan.Zero),
            new MacAddressResolver(),
            new IeeeVendorRegistry());

        var result = await enricher.EnrichAsync(
            address,
            Task.FromResult<IReadOnlyDictionary<IPAddress, string>>(names),
            CancellationToken.None);

        Assert.Equal("Living Room TV", result.DeviceName);
        Assert.Null(result.MacAddress);
        Assert.Equal("Unknown", result.VendorName);
        Assert.All(
            result.OpenPorts,
            port => Assert.Equal(PortScannerService.CommonPorts[port.Port], port.ServiceName));
    }
}
