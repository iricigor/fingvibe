using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Formatting;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanSnapshotStoreTests
{
    [Fact]
    public async Task SaveAndLoadAsync_PreservesSubnetCompletionTimeAndDeviceDetails()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var store = new ScanSnapshotStore(Path.Combine(directory, "latest-scan.json"));
        var completedAt = new DateTimeOffset(2026, 10, 22, 21, 30, 0, TimeSpan.Zero);
        var snapshot = new ScanSnapshot(
            "192.168.1.0/24",
            completedAt,
            [
                new ScanResult(
                    IPAddress.Parse("192.168.1.42"),
                    HostStatus.Alive,
                    17,
                    TimeSpan.FromMilliseconds(20),
                    "office-printer",
                    PhysicalAddress.Parse("AABBCCDDEEFF"),
                    "Example Devices",
                    [new OpenPort(443, "HTTPS")],
                    new DeviceClassification(DeviceOperatingSystem.Linux, DeviceType.Printer,
                        "SSDP SERVER advertises Linux.", "Printer manufacturer and TCP 9100.",
                        TypeIsInferred: true)),
                new ScanResult(
                    IPAddress.Parse("192.168.1.43"),
                    HostStatus.Unreachable,
                    null,
                    TimeSpan.FromMilliseconds(11))
            ]);

        try
        {
            await store.SaveAsync(snapshot);
            var loaded = await store.LoadAsync();

            Assert.NotNull(loaded);
            Assert.Equal(snapshot.Subnet, loaded.Subnet);
            Assert.Equal(snapshot.CompletedAt, loaded.CompletedAt);
            Assert.Equal(snapshot.Results.Count, loaded.Results.Count);
            Assert.Equal(snapshot.Results[0].Address, loaded.Results[0].Address);
            Assert.Equal(snapshot.Results[0].Status, loaded.Results[0].Status);
            Assert.Equal(snapshot.Results[0].RoundtripTimeMilliseconds, loaded.Results[0].RoundtripTimeMilliseconds);
            Assert.Equal(snapshot.Results[0].ProbeDuration, loaded.Results[0].ProbeDuration);
            Assert.Equal(snapshot.Results[0].DeviceName, loaded.Results[0].DeviceName);
            Assert.Equal(snapshot.Results[0].VendorName, loaded.Results[0].VendorName);
            Assert.Equal("AABBCCDDEEFF", loaded.Results[0].MacAddress!.ToString());
            Assert.Equal(snapshot.Results[1].Address, loaded.Results[1].Address);
            Assert.Equal(snapshot.Results[1].Status, loaded.Results[1].Status);
            Assert.Equal(snapshot.Results[1].ProbeDuration, loaded.Results[1].ProbeDuration);
            Assert.Equal(new OpenPort(443, "HTTPS"), Assert.Single(loaded.Results[0].OpenPortItems));
            Assert.Equal(snapshot.Results[0].Classification, loaded.Results[0].Classification);
            Assert.Equal(DeviceClassification.Unknown, loaded.Results[1].DetectedClassification);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task LoadAsync_OlderSnapshotWithoutClassificationRemainsReadable()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "cache.json");
        try
        {
            await File.WriteAllTextAsync(path, """
                {"version":1,"subnet":"192.168.1.0/24","completedAt":"2026-10-22T21:30:00Z",
                 "results":[{"address":"192.168.1.1","status":0,"probeDuration":"00:00:00","openPorts":[{"port":53,"serviceName":"DNS"}]}]}
                """);
            var loaded = await new ScanSnapshotStore(path).LoadAsync();
            Assert.Equal(DeviceClassification.Unknown, Assert.Single(loaded!.Results).DetectedClassification);
            Assert.Equal(EndpointProtocol.Tcp, Assert.Single(loaded.Results[0].OpenPortItems).Protocol);
            Assert.Empty(loaded.Results[0].UdpObservationItems);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task ProtocolsAndUdpObservationsRoundTripSeparately()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var store = new ScanSnapshotStore(Path.Combine(directory, "latest-scan.json"));
        var result = new ScanResult(IPAddress.Loopback, HostStatus.Alive, 1, TimeSpan.Zero,
            OpenPorts: [new(53, "DNS"), new(53, "DNS", EndpointProtocol.Udp)],
            UdpObservations: [new(53, "DNS", UdpServiceState.Responded, "Valid reply."),
                new(123, "NTP", UdpServiceState.NoResponse, "Deadline expired.")]);
        try
        {
            await store.SaveAsync(new("127.0.0.1/32", DateTimeOffset.UtcNow, [result]));
            var loaded = Assert.Single((await store.LoadAsync())!.Results);
            Assert.Equal(result.OpenPortItems, loaded.OpenPortItems);
            Assert.Equal(result.UdpObservationItems, loaded.UdpObservationItems);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public async Task LoadAsync_ReturnsNullWhenCacheDoesNotExist()
    {
        var store = new ScanSnapshotStore(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "cache.json"));

        Assert.Null(await store.LoadAsync());
    }

    [Fact]
    public async Task LoadAsync_RejectsInvalidCache()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new ScanSnapshotStore(Path.Combine(directory, "cache.json"));

        try
        {
            await File.WriteAllTextAsync(Path.Combine(directory, "cache.json"), "{");

            await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadAsync());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task LoadAsync_RejectsCacheWithNullDeviceEntry()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "cache.json");

        try
        {
            await File.WriteAllTextAsync(
                path,
                """{"version":1,"subnet":"192.168.1.0/24","completedAt":"2026-10-22T21:30:00Z","results":[null]}""");

            await Assert.ThrowsAsync<InvalidDataException>(() => new ScanSnapshotStore(path).LoadAsync());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Theory]
    [InlineData(0, "0 seconds")]
    [InlineData(1, "1 second")]
    [InlineData(59, "59 seconds")]
    [InlineData(60, "1 minute")]
    [InlineData(120, "2 minutes")]
    [InlineData(3600, "1 hour")]
    [InlineData(7200, "2 hours")]
    [InlineData(86400, "1 day")]
    [InlineData(172800, "2 days")]
    public void FormatAge_UsesWholeUnitsAndCorrectPluralization(int seconds, string expected)
    {
        Assert.Equal(expected, ScanAgeFormatter.FormatAge(TimeSpan.FromSeconds(seconds)));
    }

    [Fact]
    public void FormatAge_ClampsFutureTimestampsToZeroSeconds()
    {
        Assert.Equal("0 seconds", ScanAgeFormatter.FormatAge(TimeSpan.FromSeconds(-1)));
    }

    [Fact]
    public void FormatAge_DoesNotDisplayFractionalUnits()
    {
        Assert.Equal("1 second", ScanAgeFormatter.FormatAge(TimeSpan.FromMilliseconds(1_999)));
    }
}
