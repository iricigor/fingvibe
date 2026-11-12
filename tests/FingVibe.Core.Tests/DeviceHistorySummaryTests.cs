using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceHistorySummaryTests
{
    private const string Network = "current-network";
    private const string Subnet = "192.0.2.0/24";
    private const string Normal = "001122334455";
    private const string Private = "D0C907000001";
    private const string Rotated = "D0C907000002";
    private static readonly DateTimeOffset Start = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);

    private static ScanResult Result(string mac) =>
        new(IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
            null, PhysicalAddress.Parse(mac), mac.StartsWith("D0C907") ? "Private" : "Example");

    private static DeviceInventoryData Scan(DeviceInventoryData data, int minute, params string[] macs) =>
        data.ObserveCompletedScan(Network, new(Subnet, Start.AddMinutes(minute), macs.Select(Result).ToArray()));

    [Fact]
    public void NormalAndVirtualSummariesFollowEachScanWithoutResettingOnMacRotation()
    {
        var data = DeviceInventoryData.Empty;
        var states = new[] { true, true, false, false, true };
        var lastSeen = new[] { 0, 1, 1, 1, 4 };
        var since = new[] { 0, 0, 2, 2, 4 };
        Guid? virtualId = null;
        for (var i = 0; i < states.Length; i++)
        {
            data = Scan(data, i, states[i] ? [Normal, i == 0 ? Private : Rotated] : []);
            var slot = Assert.Single(data.VirtualDevices);
            virtualId ??= slot.Id;
            Assert.Equal(virtualId, slot.Id);
            var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
            Assert.Equal(2, rows.Length);
            foreach (var row in rows)
            {
                var summary = row.GetHistorySummary(Network, Subnet);
                Assert.Equal(Start, summary.FirstSeen);
                Assert.Equal(Start.AddMinutes(lastSeen[i]), summary.LastSeen);
                Assert.Equal(Start.AddMinutes(since[i]), summary.Since);
                Assert.Equal(states[i], summary.Latest!.Present);
                Assert.Equal(i + 1, summary.History.Count);
                Assert.Equal(summary.History.Where(item => item.Present).Min(item => item.CompletedAt), summary.FirstSeen);
                Assert.Equal(summary.History.Where(item => item.Present).Max(item => item.CompletedAt), summary.LastSeen);
                Assert.False(summary.FirstSeenIsAggregate);
                Assert.False(summary.LastSeenIsAggregate);
                Assert.Equal($"Latest recorded {(states[i] ? "responding" : "nonresponding")} run started: 2026-11-01 12:0{since[i]}:00 (local)",
                    DeviceDetailsPresentation.ObservedSince(summary, TimeZoneInfo.Utc));
            }
        }
    }

    [Fact]
    public void ScopeIsExactAndDoesNotFallbackOrModifyRetainedEvidence()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Normal, Private);
        data = data.ObserveCompletedScan("other-network", new(Subnet, Start.AddDays(-10), [Result(Normal)]));
        data = data.ObserveCompletedScan(Network, new("198.51.100.0/24", Start.AddDays(10), [Result(Normal)]));
        data = data.ObserveCompletedScan(null, new(Subnet, Start.AddDays(20), [Result(Normal)]));
        var row = new ScanResultRow(data.Devices[Normal], 24);
        var current = row.GetHistorySummary(Network, Subnet);
        Assert.Single(current.History);
        Assert.Equal(Start, current.FirstSeen);
        Assert.Equal(Start, current.LastSeen);
        Assert.Equal(Start, current.Since);
        Assert.Equal(4, row.ScanHistory.Count);
        foreach (var (network, subnet) in new (string?, string?)[]
                 { (null, Subnet), ("", Subnet), (Network, null), ("unseen", Subnet), (Network, "203.0.113.0/24") })
        {
            var missing = row.GetHistorySummary(network, subnet);
            Assert.Empty(missing.History);
            Assert.Null(missing.FirstSeen);
            Assert.Null(missing.LastSeen);
            Assert.Null(missing.Since);
            Assert.Contains("Unavailable", DeviceDetailsPresentation.ObservedSince(missing));
        }
        var virtualRow = new ScanResultRow(data.VirtualDevices[0], data, 24);
        Assert.Null(virtualRow.GetHistorySummary("other-network", Subnet).FirstSeen);
        Assert.Null(virtualRow.GetHistorySummary(Network, "198.51.100.0/24").LastSeen);
        Assert.Contains("identity or subnet unavailable", DeviceDetailsPresentation.EmptyScanHistory(row, null, Subnet));
    }

    [Fact]
    public void LegacyAggregatesPreserveProvenanceButNeverInventSinceOrScanEntries()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Normal, Private);
        data = data with
        {
            Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with { ScanHistory = [] }),
            VirtualDevices = data.VirtualDevices.Select(slot => slot with { ScanHistory = [] }).ToArray()
        };
        foreach (var row in ScanResultRow.CreateInventoryRows(data))
        {
            var summary = row.GetHistorySummary(Network, Subnet);
            Assert.Empty(summary.History);
            Assert.Equal(Start, summary.FirstSeen);
            Assert.Equal(Start, summary.LastSeen);
            Assert.True(summary.FirstSeenIsAggregate);
            Assert.True(summary.LastSeenIsAggregate);
            Assert.Null(summary.Since);
            Assert.Null(summary.Latest);
            Assert.Contains("historical aggregate", DeviceDetailsPresentation.HistoryTimestamp(summary.FirstSeen, summary.FirstSeenIsAggregate));
        }
        data = Scan(data, 10);
        foreach (var row in ScanResultRow.CreateInventoryRows(data))
        {
            var summary = row.GetHistorySummary(Network, Subnet);
            Assert.False(Assert.Single(summary.History).Present);
            Assert.Equal(Start, summary.FirstSeen);
            Assert.Equal(Start, summary.LastSeen);
            Assert.Equal(Start.AddMinutes(10), summary.Since);
        }
        data = Scan(data, 20, Normal, Rotated);
        foreach (var row in ScanResultRow.CreateInventoryRows(data))
        {
            var summary = row.GetHistorySummary(Network, Subnet);
            Assert.Equal(Start, summary.FirstSeen);
            Assert.True(summary.FirstSeenIsAggregate);
            Assert.Equal(Start.AddMinutes(20), summary.LastSeen);
            Assert.False(summary.LastSeenIsAggregate);
            Assert.Equal(Start.AddMinutes(20), summary.Since);
        }
    }

    [Fact]
    public void MultipleAddressesAndOutOfOrderScansUseChronologicalPresenceAndStateRuns()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Normal);
        var firstAddress = data.Devices[Normal].LatestObservation!;
        var secondAddress = firstAddress with { Address = "192.0.2.2", FirstSeen = Start.AddDays(-2) };
        var device = data.Devices[Normal] with
        {
            Observations = [firstAddress, secondAddress],
            ScanHistory =
            [
                new(Start.AddDays(5), Network, Subnet, true),
                new(Start.AddDays(2), Network, Subnet, false),
                new(Start, Network, Subnet, true),
                new(Start.AddDays(4), Network, Subnet, true)
            ]
        };
        var summary = new ScanResultRow(device, 24).GetHistorySummary(Network, Subnet);
        Assert.Equal(Start.AddDays(-2), summary.FirstSeen);
        Assert.Equal(Start.AddDays(5), summary.LastSeen);
        Assert.Equal(Start.AddDays(4), summary.Since);
        Assert.True(summary.FirstSeenIsAggregate);
        Assert.Equal([5, 4, 2, 0], summary.History.Select(item => (item.CompletedAt - Start).Days));
    }

    [Fact]
    public void ImportedUnkeyedAndAbsenceOnlyEvidenceCannotManufacturePresenceDates()
    {
        var imported = new InventoryDevice(Normal, new(Name: "Imported", Address: "192.0.2.1"), []);
        var absenceOnly = imported with { ScanHistory = [new(Start, Network, Subnet, false)] };
        foreach (var row in new[] { new ScanResultRow(imported, 24),
                     new ScanResultRow(Result(Normal) with { MacAddress = null }, 24),
                     new ScanResultRow(absenceOnly, 24) })
        {
            var summary = row.GetHistorySummary(Network, Subnet);
            Assert.Null(summary.FirstSeen);
            Assert.Null(summary.LastSeen);
            Assert.Contains("Unavailable", DeviceDetailsPresentation.HistoryTimestamp(summary.FirstSeen));
        }
        Assert.Null(new ScanResultRow(imported, 24).GetHistorySummary(Network, Subnet).Since);
        Assert.Equal(Start, new ScanResultRow(absenceOnly, 24).GetHistorySummary(Network, Subnet).Since);
    }

    [Fact]
    public async Task RestartAndHistoricalRestorationPreserveSummaryWithoutLivePresence()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-summary-{Guid.NewGuid():N}");
        try
        {
            var store = new DeviceInventoryStore(Path.Combine(directory, "inventory.json"));
            var data = Scan(Scan(DeviceInventoryData.Empty, 0, Normal, Private), 1, Normal, Rotated);
            await store.SaveAsync(data, Guid.Empty);
            var restored = (await store.LoadAsync())!;
            restored = restored.ObserveCompletedScan(null, new(Subnet, Start.AddDays(1), [Result(Normal)]), historical: true);
            restored = restored.ObserveCompletedScan("other-network", new(Subnet, Start.AddDays(2), []));
            foreach (var row in ScanResultRow.CreateInventoryRows(restored))
            {
                var summary = row.GetHistorySummary(Network, Subnet);
                Assert.Equal(Start, summary.FirstSeen);
                Assert.Equal(Start.AddMinutes(1), summary.LastSeen);
                Assert.Equal(Start, summary.Since);
                Assert.Equal(2, summary.History.Count);
                Assert.True(row.IsOnline);
                Assert.False(row.IsCurrentScanResponse);
            }
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }
}
