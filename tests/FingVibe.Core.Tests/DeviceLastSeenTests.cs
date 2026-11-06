using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceLastSeenTests
{
    private const string Network = "current-network";
    private const string Subnet = "192.0.2.0/24";
    private const string Normal = "001122334455";
    private const string Private = "D0C907000001";
    private const string Rotated = "D0C907000002";
    private static readonly DateTimeOffset Start = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
    private static readonly TimeZoneInfo PlusTwo =
        TimeZoneInfo.CreateCustomTimeZone("test-plus-two", TimeSpan.FromHours(2), "Test +02", "Test +02");

    private static ScanResult Result(string mac) =>
        new(IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
            null, PhysicalAddress.Parse(mac), mac.StartsWith("D0C907") ? "Private" : "Example");

    private static DeviceInventoryData Scan(DeviceInventoryData data, int minute, params string[] macs) =>
        data.ObserveCompletedScan(Network, new(Subnet, Start.AddMinutes(minute), macs.Select(Result).ToArray()));

    // Mirrors a restart: saved evidence remains but no device is a response in the displayed scan.
    private static DeviceInventoryData Restarted(DeviceInventoryData data) => data with
    {
        Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with { CurrentCompletedAt = null }),
        VirtualDevices = data.VirtualDevices.Select(slot => slot with { CurrentCompletedAt = null }).ToArray()
    };

    private static DeviceLastSeen LastSeen(ScanResultRow row, string? network = Network, string? subnet = Subnet,
        DateTimeOffset? displayed = null, TimeZoneInfo? zone = null) =>
        DeviceDetailsPresentation.LastSeen(row, network, subnet, displayed, zone ?? TimeZoneInfo.Utc);

    [Fact]
    public void CurrentResponsesShowThisScanAndAbsenceNeverAdvancesNormalOrVirtualLastSeen()
    {
        var data = DeviceInventoryData.Empty;
        var states = new[] { true, true, false, false, true };
        var lastSeen = new[] { 0, 1, 1, 1, 4 };
        for (var i = 0; i < states.Length; i++)
        {
            data = Scan(data, i, states[i] ? [Normal, i == 0 ? Private : Rotated] : []);
            var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
            Assert.Equal(2, rows.Length);
            Assert.Single(rows, row => row.IsVirtualIdentity);
            foreach (var row in rows)
            {
                var value = LastSeen(row);
                if (states[i])
                {
                    Assert.Equal(DeviceLastSeenKind.SeenThisScan, value.Kind);
                    Assert.Equal(Start.AddMinutes(i), value.Timestamp);
                    Assert.Equal("Seen this scan", value.Text);
                    Assert.Equal($"Last seen: Seen this scan (2026-11-01 12:0{i}:00 +00:00)", value.Description);
                    Assert.True(value.IsMuted);
                }
                else
                {
                    Assert.Equal(DeviceLastSeenKind.Timestamp, value.Kind);
                    Assert.Equal(Start.AddMinutes(lastSeen[i]), value.Timestamp);
                    Assert.Equal($"2026-11-01 12:0{lastSeen[i]}", value.Text);
                    Assert.Equal($"Last seen: 2026-11-01 12:0{lastSeen[i]}:00 +00:00", value.Description);
                    Assert.False(value.IsMuted);
                }
            }
            foreach (var row in ScanResultRow.CreateInventoryRows(Restarted(data)))
            {
                var restored = LastSeen(row, zone: PlusTwo);
                Assert.Equal(DeviceLastSeenKind.Timestamp, restored.Kind);
                Assert.Equal(Start.AddMinutes(lastSeen[i]), restored.Timestamp);
                Assert.Equal($"2026-11-01 14:0{lastSeen[i]}", restored.Text);
                Assert.Equal($"Last seen: 2026-11-01 14:0{lastSeen[i]}:00 +02:00", restored.Description);
            }
        }
    }

    [Fact]
    public void ScopeIsExactAndAnotherNetworksNewerEvidenceIsNeverUsed()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Normal, Private);
        data = data.ObserveCompletedScan("other-network", new(Subnet, Start.AddDays(10), [Result(Normal), Result(Private)]));
        data = data.ObserveCompletedScan(Network, new("198.51.100.0/24", Start.AddDays(20), [Result(Normal)]));
        data = Restarted(data);
        var normal = new ScanResultRow(data.Devices[Normal], 24);
        Assert.Equal(Start, LastSeen(normal).Timestamp);
        Assert.Equal(Start.AddDays(10), LastSeen(normal, "other-network").Timestamp);
        Assert.Equal(Start.AddDays(20), LastSeen(normal, subnet: "198.51.100.0/24").Timestamp);
        var original = ScanResultRow.CreateInventoryRows(data)
            .Single(row => row.IsVirtualIdentity && row.VirtualDevice!.NetworkId == Network);
        Assert.Equal(Start, LastSeen(original).Timestamp);
        foreach (var (network, subnet) in new (string?, string?)[] { ("unseen", Subnet), (Network, "203.0.113.0/24") })
        {
            var missing = LastSeen(normal, network, subnet);
            Assert.Equal(DeviceLastSeenKind.Unavailable, missing.Kind);
            Assert.Null(missing.Timestamp);
            Assert.Equal("Unavailable", missing.Text);
            Assert.Equal("Last seen: Unavailable - no matching local presence evidence for the current network/subnet.",
                missing.Description);
            Assert.Null(LastSeen(original, network, subnet).Timestamp);
        }
        foreach (var (network, subnet) in new (string?, string?)[] { (null, Subnet), (" ", Subnet), (Network, null) })
        {
            var unscoped = LastSeen(normal, network, subnet);
            Assert.Equal(DeviceLastSeenKind.Unavailable, unscoped.Kind);
            Assert.Contains("current network identity or subnet unavailable", unscoped.Description);
            Assert.Contains("Another network's evidence is not used", unscoped.Description);
        }
    }

    [Fact]
    public void CurrentResponsesStayExplicitWhenNetworkIdentityIsUnavailable()
    {
        var data = DeviceInventoryData.Empty.ObserveCompletedScan(null, new(Subnet, Start, [Result(Normal), Result(Private)]));
        var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
        Assert.NotEmpty(rows);
        foreach (var row in rows)
        {
            var value = LastSeen(row, network: null, subnet: null);
            Assert.Equal(DeviceLastSeenKind.SeenThisScan, value.Kind);
            Assert.Equal(Start, value.Timestamp);
        }
    }

    [Fact]
    public void LegacyAggregatesKeepProvenanceAndAbsenceOnlyEvidenceIsUnavailable()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Normal, Private);
        data = Restarted(data with
        {
            Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with { ScanHistory = [] }),
            VirtualDevices = data.VirtualDevices.Select(slot => slot with { ScanHistory = [] }).ToArray()
        });
        foreach (var row in ScanResultRow.CreateInventoryRows(data))
        {
            var value = LastSeen(row);
            Assert.Equal(DeviceLastSeenKind.Timestamp, value.Kind);
            Assert.Equal(Start, value.Timestamp);
            Assert.Equal("2026-11-01 12:00 (aggregate)", value.Text);
            Assert.Equal("Last seen: 2026-11-01 12:00:00 +00:00 (historical aggregate; individual scan unavailable)",
                value.Description);
        }
        var absenceOnly = new InventoryDevice(Normal, new(Name: "Observed elsewhere", Address: "192.0.2.1"),
            [data.Devices[Normal].Observations[0] with { Present = false, NetworkId = "other-network" }])
        {
            ScanHistory = [new(Start, Network, Subnet, false)]
        };
        var unavailable = LastSeen(new ScanResultRow(absenceOnly, 24));
        Assert.Equal(DeviceLastSeenKind.Unavailable, unavailable.Kind);
        Assert.Contains("no matching local presence evidence", unavailable.Description);
    }

    [Fact]
    public void ImportedAndUnkeyedRowsAreExplicitAndNeverCurrentTime()
    {
        var imported = new InventoryDevice(Normal, new(Name: "Imported", Address: "192.0.2.1"), []);
        var never = LastSeen(new ScanResultRow(imported, 24));
        Assert.Equal(DeviceLastSeenKind.NeverLocally, never.Kind);
        Assert.Null(never.Timestamp);
        Assert.Equal("Never locally", never.Text);
        Assert.Equal("Last seen: Never locally - imported Fing data is not a local scan observation.", never.Description);
        Assert.True(never.IsMuted);

        var unkeyed = Result(Normal) with { MacAddress = null };
        var responding = LastSeen(new ScanResultRow(unkeyed, 24), displayed: Start);
        Assert.Equal(DeviceLastSeenKind.SeenThisScan, responding.Kind);
        Assert.Equal(Start, responding.Timestamp);
        foreach (var row in new[] { new ScanResultRow(unkeyed, 24), new ScanResultRow(unkeyed, 24, historical: true) })
        {
            var value = LastSeen(row);
            Assert.Equal(DeviceLastSeenKind.Unavailable, value.Kind);
            Assert.Null(value.Timestamp);
            Assert.Contains("MAC-based device identity", value.Description);
        }
        Assert.Equal(DeviceLastSeenKind.Unavailable,
            LastSeen(new ScanResultRow(unkeyed, 24, historical: true), displayed: Start).Kind);
    }

    [Fact]
    public void RowPublishesLastSeenChangesForBindingsAndDefaultsToNotCalculated()
    {
        var row = new ScanResultRow(Result(Normal), 24);
        Assert.Same(DeviceLastSeen.NotCalculated, row.LastSeen);
        Assert.Equal("Unavailable", row.LastSeenText);
        Assert.Equal(0.65, row.LastSeenOpacity);
        var changed = new List<string?>();
        row.PropertyChanged += (_, args) => changed.Add(args.PropertyName);
        var value = new DeviceLastSeen(DeviceLastSeenKind.Timestamp, Start, "2026-11-01 12:00", "Last seen: exact");
        row.SetLastSeen(value);
        Assert.Equal(["LastSeen", "LastSeenText", "LastSeenDescription", "LastSeenOpacity"], changed);
        Assert.Equal("2026-11-01 12:00", row.LastSeenText);
        Assert.Equal("Last seen: exact", row.LastSeenDescription);
        Assert.Equal(1, row.LastSeenOpacity);
        changed.Clear();
        row.SetLastSeen(value with { });
        Assert.Empty(changed);
    }
}
