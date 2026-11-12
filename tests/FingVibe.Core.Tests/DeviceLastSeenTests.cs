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

    private static readonly DateTimeOffset Now = Start.AddMinutes(10);

    private static DeviceLastSeen LastSeen(ScanResultRow row, string? network = Network, string? subnet = Subnet,
        DateTimeOffset? displayed = null, TimeZoneInfo? zone = null, DateTimeOffset? now = null) =>
        DeviceDetailsPresentation.LastSeen(row, network, subnet, displayed, zone ?? TimeZoneInfo.Utc, now ?? Now);

    [Fact]
    public void CurrentResponsesShowOnlineAndAbsenceNeverAdvancesNormalOrVirtualLastSeen()
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
                    Assert.Equal("Online", value.Text);
                    Assert.Equal($"Last seen: Online - responded in the displayed scan (2026-11-01 12:0{i}:00 +00:00)",
                        value.Description);
                    Assert.True(value.IsMuted);
                }
                else
                {
                    Assert.Equal(DeviceLastSeenKind.Timestamp, value.Kind);
                    Assert.Equal(Start.AddMinutes(lastSeen[i]), value.Timestamp);
                    Assert.Equal($"{10 - lastSeen[i]} min. ago", value.Text);
                    Assert.Equal($"Last seen: 2026-11-01 12:0{lastSeen[i]}:00 +00:00", value.Description);
                    Assert.False(value.IsMuted);
                }
            }
            foreach (var row in ScanResultRow.CreateInventoryRows(Restarted(data)))
            {
                Assert.Equal(states[i], row.IsOnline);
                Assert.False(row.IsCurrentScanResponse);
                Assert.False(row.HasLatency);
                var restored = LastSeen(row, zone: PlusTwo);
                Assert.Equal(DeviceLastSeenKind.Timestamp, restored.Kind);
                Assert.Equal(Start.AddMinutes(lastSeen[i]), restored.Timestamp);
                Assert.Equal($"{10 - lastSeen[i]} min. ago", restored.Text);
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
            Assert.Equal("10 min. ago", value.Text);
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
        Assert.Equal("Never", never.Text);
        Assert.Equal("Last seen: Never - not observed by a local scan. Imported Fing data is not a local scan observation"
            + " and does not mean the device was never present on any network.", never.Description);
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

    [Theory]
    [InlineData(0, "< 1 min. ago")]
    [InlineData(59, "< 1 min. ago")]
    [InlineData(60, "1 min. ago")]
    [InlineData(119, "1 min. ago")]
    [InlineData(120, "2 min. ago")]
    [InlineData(3599, "59 min. ago")]
    [InlineData(3600, "1 h ago")]
    [InlineData(7200, "2 h ago")]
    [InlineData(86399, "23 h ago")]
    [InlineData(86400, "1 day ago")]
    [InlineData(2 * 86400, "2 days ago")]
    [InlineData(30 * 86400 - 1, "29 days ago")]
    [InlineData(30 * 86400, "1 month ago")]
    [InlineData(60 * 86400 - 1, "1 month ago")]
    [InlineData(60 * 86400, "2 months ago")]
    [InlineData(365 * 86400 - 1, "12 months ago")]
    [InlineData(365 * 86400, "1 year ago")]
    [InlineData(2 * 365 * 86400, "2 years ago")]
    [InlineData(-1, null)]
    public void RelativeAgesUseWholeUnitsWithSingularAndPluralBoundaries(long elapsedSeconds, string? expected) =>
        Assert.Equal(expected, DeviceDetailsPresentation.LastSeenAge(Start, Start.AddSeconds(elapsedSeconds)));

    [Fact]
    public void ClockChangesShowLocalTimeWithoutChangingEvidenceAndOnlyAgesRefresh()
    {
        var data = Restarted(Scan(DeviceInventoryData.Empty, 0, Normal));
        var row = new ScanResultRow(data.Devices[Normal], 24);
        var future = LastSeen(row, zone: PlusTwo, now: Start.AddHours(-3));
        Assert.Equal(DeviceLastSeenKind.Timestamp, future.Kind);
        Assert.Equal(Start, future.Timestamp);
        Assert.Equal("2026-11-01 14:00", future.Text);
        Assert.Equal("Last seen: 2026-11-01 14:00:00 +02:00", future.Description);
        Assert.False(future.IsMuted);

        foreach (var (now, text) in new[] { (Start.AddDays(3), "3 days ago"), (Start.AddSeconds(-1), "2026-11-01 14:00"),
                     (Start.AddDays(400), "1 year ago") })
        {
            var refreshed = future.At(now);
            Assert.Equal(text, refreshed.Text);
            Assert.Equal(future with { Text = text }, refreshed);
        }

        var online = LastSeen(ScanResultRow.CreateInventoryRows(Scan(DeviceInventoryData.Empty, 0, Normal)).Single());
        var never = LastSeen(new ScanResultRow(new InventoryDevice(Normal, new(Name: "Imported"), []), 24));
        var unavailable = LastSeen(row, network: "unseen");
        Assert.Equal(DeviceLastSeenKind.SeenThisScan, online.Kind);
        Assert.Equal(DeviceLastSeenKind.NeverLocally, never.Kind);
        foreach (var fixedValue in new[] { online, never, unavailable, DeviceLastSeen.NotCalculated })
            Assert.Same(fixedValue, fixedValue.At(Start.AddDays(90)));
    }

    [Fact]
    public void AgeRefreshPublishesOnlyTextAndLeavesOnlineStatusAndOrderingUnchanged()
    {
        var data = Scan(Scan(DeviceInventoryData.Empty, 0, Normal), 5, Private);
        var offline = new ScanResultRow(data.Devices[Normal], 24);
        var online = ScanResultRow.CreateInventoryRows(data).Single(row => row.IsVirtualIdentity);
        offline.SetLastSeen(LastSeen(offline));
        online.SetLastSeen(LastSeen(online));
        var status = (offline.Status, online.Status, offline.IsOnline, online.IsOnline);
        var changed = new List<string?>();
        offline.PropertyChanged += (_, args) => changed.Add(args.PropertyName);
        online.PropertyChanged += (_, args) => changed.Add(args.PropertyName);

        offline.RefreshLastSeenAge(Now.AddMinutes(50));
        online.RefreshLastSeenAge(Now.AddMinutes(50));
        Assert.Equal(["LastSeen", "LastSeenText"], changed);
        Assert.Equal("1 h ago", offline.LastSeenText);
        Assert.Equal("Online", online.LastSeenText);
        Assert.Equal(Start, offline.LastSeen.Timestamp);
        Assert.Equal("Last seen: 2026-11-01 12:00:00 +00:00", offline.LastSeenDescription);
        Assert.Equal(status, (offline.Status, online.Status, offline.IsOnline, online.IsOnline));
        Assert.Equal(1, DeviceResultSort.Compare(online, offline, ResultSortColumn.LastSeen, ascending: true));

        changed.Clear();
        offline.RefreshLastSeenAge(Now.AddMinutes(50).AddSeconds(59));
        Assert.Empty(changed);
    }

    [Fact]
    public void MinuteRefreshRunsOnlyWhileActiveAndRefreshesImmediatelyWhenShownOrGivenRows()
    {
        var time = new Microsoft.Extensions.Time.Testing.FakeTimeProvider(Now);
        var data = Scan(Scan(DeviceInventoryData.Empty, 0, Normal), 5, Private);
        var offline = new ScanResultRow(data.Devices[Normal], 24);
        var online = ScanResultRow.CreateInventoryRows(data).Single(row => row.IsVirtualIdentity);
        var imported = new ScanResultRow(new InventoryDevice("001122334466", new(Name: "Imported"), []), 24);
        var rows = new List<ScanResultRow> { offline, online, imported };
        foreach (var row in rows) row.SetLastSeen(LastSeen(row, now: time.GetUtcNow()));
        var before = rows.Select(row => row.LastSeen).ToArray();
        var posted = new Queue<Action>();
        var ticks = 0;
        var refresh = new FingVibe.App.Views.DeviceLastSeenAgeRefresh(() => rows, action =>
        {
            ticks++;
            posted.Enqueue(action);
        }, time);
        void Advance(TimeSpan by)
        {
            time.Advance(by);
            while (posted.TryDequeue(out var action)) action();
        }

        Assert.Equal(TimeSpan.FromSeconds(60), FingVibe.App.Views.DeviceLastSeenAgeRefresh.Interval);
        Advance(TimeSpan.FromMinutes(5));
        Assert.False(refresh.IsActive);
        Assert.Equal(0, ticks);
        Assert.Equal("10 min. ago", offline.LastSeenText);

        refresh.SetActive(true);
        Assert.Equal("15 min. ago", offline.LastSeenText);
        Advance(TimeSpan.FromSeconds(59));
        Assert.Equal("15 min. ago", offline.LastSeenText);
        Advance(TimeSpan.FromSeconds(1));
        Assert.Equal("16 min. ago", offline.LastSeenText);

        // A tick already posted to the UI thread is ignored once the page is no longer active.
        time.Advance(TimeSpan.FromMinutes(1));
        refresh.SetActive(false);
        while (posted.TryDequeue(out var stale)) stale();
        Assert.Equal("16 min. ago", offline.LastSeenText);
        var inactiveTicks = ticks;
        Advance(TimeSpan.FromHours(24));
        Assert.Equal(inactiveTicks, ticks);
        Assert.Equal("16 min. ago", offline.LastSeenText);
        var added = new ScanResultRow(data.Devices[Normal], 24);
        added.SetLastSeen(before[0]);
        refresh.RefreshIfActive([added]);
        Assert.Equal("10 min. ago", added.LastSeenText);

        refresh.SetActive(true);
        Assert.Equal("1 day ago", offline.LastSeenText);
        refresh.RefreshIfActive([added]);
        Assert.Equal("1 day ago", added.LastSeenText);
        refresh.SetActive(true);
        var activeTicks = ticks;
        Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(activeTicks + 1, ticks);

        for (var index = 0; index < rows.Count; index++)
        {
            Assert.Equal(before[index].Kind, rows[index].LastSeen.Kind);
            Assert.Equal(before[index].Timestamp, rows[index].LastSeen.Timestamp);
            Assert.Equal(before[index].Description, rows[index].LastSeenDescription);
        }
        Assert.Equal("Online", online.LastSeenText);
        Assert.Equal("Never", imported.LastSeenText);
        Assert.True(online.IsOnline);
    }
}
