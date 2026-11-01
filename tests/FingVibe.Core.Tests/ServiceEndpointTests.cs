using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ServiceEndpointTests
{
    [Fact]
    public void IdentityAndFilteringDistinguishProtocolsAndExcludeInconclusiveObservations()
    {
        OpenPort[] ports = [new(53, "DNS"), new(53, "DNS", EndpointProtocol.Udp), new(53, "DNS")];
        Assert.Equal(2, ports.DistinctBy(port => port.Identity).Count());
        var result = new ScanResult(IPAddress.Loopback, HostStatus.Alive, 1, TimeSpan.Zero,
            OpenPorts: ports, UdpObservations: [new(123, "NTP", UdpServiceState.NoResponse, "Deadline expired.")]);
        Assert.True(result.MatchesFilter("53/TCP"));
        Assert.True(result.MatchesFilter("53/UDP"));
        Assert.False(result.MatchesFilter("123/UDP"));
        var row = new ScanResultRow(result with { OpenPorts = [] }, 32);
        Assert.Empty(row.OpenPortItems);
        Assert.False(row.MatchesFilter("NTP"));
        Assert.False(new DeviceResultFilter(false, true, "").Matches(row));
        row.UpdateOpenPorts([new(123, "NTP", EndpointProtocol.Udp)]);
        Assert.True(new DeviceResultFilter(false, true, "123/UDP").Matches(row));
    }

    [Fact]
    public async Task UdpEndpointsNeverBecomeTcpBannerEvidence()
    {
        var results = await new ServiceBannerProbe().ProbeAsync(IPAddress.Loopback,
            [new(22, "SSH", EndpointProtocol.Udp), new(80, "HTTP", EndpointProtocol.Udp)], CancellationToken.None);
        Assert.Empty(results);
        var classification = DeviceClassifier.ClassifyAdvertisements([], null,
            openPorts: [new(445, "SMB", EndpointProtocol.Udp)], responseTtl: 128);
        Assert.Equal(DeviceOperatingSystem.Unknown, classification.OperatingSystem);
    }

    [Fact]
    public void EveryCatalogEndpointHasANeutralFamilyGlyph()
    {
        foreach (var port in PortScannerService.CommonPorts.Concat(PortScannerService.AdditionalPorts))
            Assert.NotEqual("\uE9CE", PortServiceIcons.Glyph(new(port.Key, port.Value)));
        Assert.Equal(PortServiceIcons.Glyph(new(1883, "MQTT")), PortServiceIcons.Glyph(new(8883, "Secure MQTT")));
        Assert.NotEqual(PortServiceIcons.Glyph(new(1883, "MQTT")), PortServiceIcons.Glyph(new(15672, "RabbitMQ management")));
        Assert.NotEqual(PortServiceIcons.Glyph(new(123, "Unknown")), PortServiceIcons.Glyph(new(123, "NTP", EndpointProtocol.Udp)));
        Assert.Equal("1883/TCP - MQTT", new OpenPort(1883, "MQTT").AccessibleLabel);
        Assert.Equal("123/UDP - NTP", new OpenPort(123, "NTP", EndpointProtocol.Udp).AccessibleLabel);
    }

    [Fact]
    public async Task InventoryPreservesProtocolsAndObservationsWithoutChangingPresence()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var result = new ScanResult(IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1, TimeSpan.Zero,
            MacAddress: PhysicalAddress.Parse("001122334455"),
            OpenPorts: [new(53, "DNS"), new(53, "DNS", EndpointProtocol.Udp)],
            UdpObservations: [new(53, "DNS", UdpServiceState.Responded, "Valid reply."),
                new(123, "NTP", UdpServiceState.Error, "Invalid reply.")]);
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("network",
            new("192.0.2.0/24", DateTimeOffset.UtcNow, [result]));
        try
        {
            var store = new DeviceInventoryStore(Path.Combine(directory, "inventory.json"));
            await store.SaveAsync(data, Guid.Empty);
            var saved = (await store.LoadAsync())!.Devices["001122334455"];
            var restored = saved.LatestObservation!.ToScanResult(saved.Mac);
            Assert.Equal(result.OpenPortItems, restored.OpenPortItems);
            Assert.Equal(result.UdpObservationItems, restored.UdpObservationItems);
            Assert.True(saved.LatestObservation.Present);
            Assert.Equal(InventoryDeviceStatus.Unknown, saved.Status);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void LegacyInventoryPortJsonRetainsTcpMeaning()
    {
        var port = JsonSerializer.Deserialize<OpenPort>("""{"port":53,"serviceName":"DNS"}""",
            new JsonSerializerOptions(JsonSerializerDefaults.Web));
        Assert.Equal(new OpenPort(53, "DNS"), port);
    }
}
