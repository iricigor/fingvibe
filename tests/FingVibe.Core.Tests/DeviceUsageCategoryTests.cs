using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Nodes;
using FingVibe.App;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceUsageCategoryTests : IDisposable
{
    private const string Mac = "001122334455";
    private static readonly LogicalDeviceId Id = LogicalDeviceId.Mac(Mac);
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-02T00:00:00Z");
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-usage-{Guid.NewGuid():N}");
    private string Database => Path.Combine(_directory, "inventory.sqlite");

    [Theory]
    [InlineData(12, 14, 0, 0, DeviceUsageCategory.Permanent)]
    [InlineData(1, 20, 0, 0, DeviceUsageCategory.Guest)]
    [InlineData(8, 10, 3, 10, DeviceUsageCategory.Personal)]
    [InlineData(6, 10, 5, 10, DeviceUsageCategory.Unclassified)]
    [InlineData(79, 100, 0, 0, DeviceUsageCategory.Unclassified)]
    [InlineData(80, 100, 0, 0, DeviceUsageCategory.Permanent)]
    [InlineData(81, 100, 0, 0, DeviceUsageCategory.Permanent)]
    [InlineData(9, 100, 0, 0, DeviceUsageCategory.Guest)]
    [InlineData(10, 100, 0, 0, DeviceUsageCategory.Guest)]
    [InlineData(11, 100, 0, 0, DeviceUsageCategory.Unclassified)]
    [InlineData(59, 100, 30, 100, DeviceUsageCategory.Unclassified)]
    [InlineData(60, 100, 30, 100, DeviceUsageCategory.Personal)]
    [InlineData(61, 100, 30, 100, DeviceUsageCategory.Personal)]
    [InlineData(70, 100, 51, 100, DeviceUsageCategory.Unclassified)]
    [InlineData(70, 100, 50, 100, DeviceUsageCategory.Personal)]
    [InlineData(70, 100, 49, 100, DeviceUsageCategory.Personal)]
    [InlineData(2, 3, 7, 15, DeviceUsageCategory.Personal)]
    [InlineData(10, 10, 6, 10, DeviceUsageCategory.Permanent)]
    [InlineData(1, 1, 0, 19, DeviceUsageCategory.Guest)]
    [InlineData(0, 0, 0, 0, DeviceUsageCategory.Unclassified)]
    [InlineData(0, 0, 6, 10, DeviceUsageCategory.Unclassified)]
    public void ExactThresholdsPrecedenceAndMissingComparators(int preferredResponses, int preferred,
        int daytimeResponses, int daytime, DeviceUsageCategory expected)
    {
        var result = Infer(Evidence(preferredResponses, preferred, daytimeResponses, daytime));
        Assert.Equal(expected, result.Category);
        Assert.Equal(preferred + daytime, result.Total.Eligible);
        Assert.Equal(preferredResponses + daytimeResponses, result.Total.Responded);
        Assert.Equal(preferred, result.OvernightWeekend.Eligible);
        Assert.Equal(daytime, result.WeekdayDaytime.Eligible);
        Assert.Equal(preferred == 0, result.OvernightWeekend.Percentage is null);
        Assert.Equal(daytime == 0, result.WeekdayDaytime.Percentage is null);
    }

    [Fact]
    public void ExactRatesAreUsedBeforeRoundingAndOneScanCanClassify()
    {
        var rounded = Infer(Evidence(799, 1000, 0, 0));
        Assert.Equal(DeviceUsageCategory.Unclassified, rounded.Category);
        Assert.Contains("(80%)", UsageCategoryPresentation.Counts(rounded.Total));
        Assert.Equal(DeviceUsageCategory.Permanent, Infer(Evidence(1, 1, 0, 0)).Category);
        Assert.Equal(DeviceUsageCategory.Guest, Infer(Evidence(0, 1, 0, 0)).Category);
        var permanent = Infer(Evidence(12, 14, 0, 0));
        Assert.True(permanent.LimitedEvidence);
        Assert.Contains("(86%)", UsageCategoryPresentation.Counts(permanent.Total));
        Assert.Contains("(5%)", UsageCategoryPresentation.Counts(Infer(Evidence(1, 20, 0, 0)).Total));
        Assert.DoesNotContain("%", UsageCategoryPresentation.Counts(new(0, 0)));
    }

    [Theory]
    [InlineData(6, 30, true)]
    [InlineData(7, 29, true)]
    [InlineData(7, 30, false)]
    public void LimitedEvidenceUsesObservedDatesAndEligibleCounts(int dates, int scans, bool limited)
    {
        var evidence = Evidence(0, 0, 0, 0);
        var rows = Enumerable.Range(0, scans).Select(i => Scan(Start.AddDays(i % dates).AddHours(18).AddSeconds(i), true)).ToArray();
        var result = Infer(evidence with { Scans = rows });
        Assert.Equal(DeviceUsageCategory.Permanent, result.Category);
        Assert.Equal(dates, result.ObservedDates);
        Assert.Equal(limited, result.LimitedEvidence);
    }

    [Theory]
    [InlineData(6, 9, 3, 21, true)]
    [InlineData(14, 21, 1, 9, true)]
    [InlineData(7, 10, 4, 20, false)]
    public void PersonalNeedsTenPerComparatorOnlyForConfidence(int pr, int pe, int dr, int de, bool limited)
    {
        var scans = Enumerable.Range(0, pe).Select(i => Scan(Start.AddDays(i % 7).AddHours(18).AddSeconds(i), i < pr))
            .Concat(Enumerable.Range(0, de).Select(i => Scan(Start.AddDays(i % 5).AddHours(9).AddSeconds(i), i < dr))).ToArray();
        var result = Infer(Evidence(0, 0, 0, 0) with { Scans = scans });
        Assert.Equal(7, result.ObservedDates);
        Assert.Equal(DeviceUsageCategory.Personal, result.Category);
        Assert.Equal(limited, result.LimitedEvidence);
    }

    [Fact]
    public void OvernightWeekendUnionBoundariesNeverDoubleCount()
    {
        var times = new[] { Start.AddHours(6).AddTicks(-1), Start.AddHours(6),
            Start.AddHours(18).AddTicks(-1), Start.AddHours(18), Start.AddDays(5).AddHours(9),
            Start.AddDays(5).AddHours(20), Start.AddDays(6).AddHours(9) };
        var result = Infer(Evidence(0, 0, 0, 0) with { Scans = times.Select(time => Scan(time, true)).ToArray() });
        Assert.Equal(7, result.Total.Eligible);
        Assert.Equal(5, result.OvernightWeekend.Eligible);
        Assert.Equal(2, result.WeekdayDaytime.Eligible);
    }

    [Fact]
    public void WindowFirstSightingUnknownPendingDuplicatesAndExpiryAreRespected()
    {
        var first = Start.AddDays(1);
        var known = Scan(first, true);
        var evidence = Evidence(0, 0, 0, 0) with
        {
            Devices = [new(Id, first, false)],
            Scans = [Scan(Start.AddTicks(-1), true), Scan(first.AddTicks(-1), false),
                known, known, Scan(first.AddHours(1), false) with { Responses = [AnalyticsResponse.Unknown] },
                Scan(first.AddHours(2), true) with { State = ScanCheckpointState.Pending },
                Scan(first.AddHours(3), true) with { State = ScanCheckpointState.Incomplete },
                Scan(Start.AddDays(8), true)]
        };
        var result = Infer(evidence);
        Assert.Equal(1, result.Total.Eligible);
        Assert.Equal(DateOnly.FromDateTime(first.DateTime), result.FirstDate);
        Assert.Equal(0, Infer(evidence with { Devices = [new(Id, null, true)] }).Total.Eligible);
        var expired = Infer(evidence with
        {
            QueryTime = Start.AddDays(15), FirstDate = new(2026, 11, 11), LastDate = new(2026, 11, 17),
            WindowStart = Start.AddDays(9)
        });
        Assert.Equal(DeviceUsageCategory.Unclassified, expired.Category);
        Assert.Null(expired.Total.Percentage);
    }

    [Theory]
    [InlineData("2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z")]
    [InlineData("2026-03-29T00:30:00Z", "2026-03-29T01:30:00Z")]
    public void RepeatedAndSkippedDstHoursKeepBothRealInstants(string a, string b)
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin");
        var times = new[] { DateTimeOffset.Parse(a), DateTimeOffset.Parse(b) };
        var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(times[1], zone).DateTime);
        var evidence = Evidence(0, 0, 0, 0) with
        {
            Devices = [new(Id, times[0], false)], TimeZoneId = zone.Id,
            QueryTime = times[1], FirstDate = date.AddDays(-6), LastDate = date, WindowStart = times[0].AddDays(-6),
            Scans = times.Select(time => Scan(time, true) with { LocalCompletedAt = TimeZoneInfo.ConvertTime(time, zone) }).ToArray()
        };
        var result = Infer(evidence);
        Assert.Equal(2, result.Total.Eligible);
        Assert.Equal(2, result.OvernightWeekend.Eligible);
        Assert.Equal(1, result.ObservedDates);
    }

    [Fact]
    public void CancellationAndInvalidEvidenceAreExplicit()
    {
        Assert.Throws<OperationCanceledException>(() => DeviceUsageClassifier.Classify(Evidence(1, 1, 0, 0), new(true)));
        Assert.Throws<ArgumentException>(() => DeviceUsageClassifier.Classify(Evidence(1, 1, 0, 0) with { FirstDate = new(2026, 10, 10) }));
        Assert.Throws<ArgumentException>(() => DeviceUsageClassifier.Classify(Evidence(0, 0, 0, 0) with
            { Scans = [Scan(Start, true) with { Responses = [] }] }));
    }

    [Fact]
    public async Task OverrideSurvivesImportScanRestartAndAutomaticPreservesAllOtherData()
    {
        var store = new DeviceInventoryStore(Database);
        var person = new ManagedPerson(Guid.NewGuid(), "Alice", "A");
        var data = Observed(DeviceInventoryData.Empty, Mac, Start) with
        {
            Names = new Dictionary<string, string> { [Mac] = "Saved name" },
            Classifications = new Dictionary<string, DeviceClassificationOverride> { [Mac] = new(Type: DeviceType.Computer) },
            PeopleRooms = new PeopleRoomsData([person]).AssignPerson(Mac, person.Id)
        };
        data = await store.SaveAsync(data.SetUsageCategoryOverride(Id, DeviceUsageCategory.Personal), Guid.Empty);
        var imported = FingImportAnalyzer.Analyze(new FingExport([new(2, Mac, new(Brand: "Imported brand"), null, null)], [], 1), data).Updated;
        data = await store.SaveAsync(Observed(imported, Mac, Start.AddHours(1)), data.Revision);
        var restarted = new DeviceInventoryStore(Database);
        var loaded = (await restarted.LoadMetadataAsync())!;
        Assert.Equal(DeviceUsageCategory.Personal, loaded.GetUsageCategoryOverride(Id));
        Assert.Equal(2, loaded.Devices[Mac].ScanHistory.Count);
        var cleared = await restarted.SaveAsync(loaded.SetUsageCategoryOverride(Id, null), loaded.Revision);
        Assert.Null(cleared.GetUsageCategoryOverride(Id));
        Assert.Equal("Saved name", cleared.Names[Mac]);
        Assert.Equal(DeviceType.Computer, cleared.Classifications[Mac].Type);
        Assert.Equal(person.Id, cleared.PeopleRooms.Assignments[Mac].PersonId);
        Assert.Equal("Imported brand", cleared.Devices[Mac].Imported.Brand);
        Assert.Equal(2, cleared.Devices[Mac].ScanHistory.Count);
        var evidence = await restarted.QueryAnalyticsAsync(new("network", "192.0.2.0/24", Start.AddDays(6), 7, TimeZoneInfo.Utc, cleared.Revision));
        Assert.Equal(DeviceUsageCategory.Permanent, Infer(evidence).Category);
    }

    [Fact]
    public async Task VirtualOverrideFollowsStableIdentityAndDoesNotChangeMacOverride()
    {
        const string firstMac = "D0C907000001", nextMac = "D0C907000002";
        var store = new DeviceInventoryStore(Database);
        var data = Observed(DeviceInventoryData.Empty, firstMac, Start, "Private");
        var slot = Assert.Single(data.VirtualDevices);
        data = data.SetUsageCategoryOverride(LogicalDeviceId.Mac(firstMac), DeviceUsageCategory.Guest)
            .SetUsageCategoryOverride(LogicalDeviceId.Virtual(slot.Id), DeviceUsageCategory.Personal);
        data = await store.SaveAsync(data, Guid.Empty);
        data = await store.SaveAsync(Observed(data, nextMac, Start.AddHours(1), "Private"), data.Revision);
        var loaded = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Equal(nextMac, Assert.Single(loaded.VirtualDevices).LastActiveMac);
        Assert.Equal(DeviceUsageCategory.Personal, loaded.GetUsageCategoryOverride(LogicalDeviceId.Virtual(slot.Id)));
        Assert.Equal(DeviceUsageCategory.Guest, loaded.GetUsageCategoryOverride(LogicalDeviceId.Mac(firstMac)));
        Assert.Null(loaded.GetUsageCategoryOverride(LogicalDeviceId.Mac(nextMac)));
        var evidence = await store.QueryAnalyticsAsync(new("network", "192.0.2.0/24", Start.AddDays(6), 7, TimeZoneInfo.Utc, data.Revision));
        Assert.Equal(slot.Id.ToString("D"), Assert.Single(DeviceUsageClassifier.Classify(evidence)).Key.Id);
    }

    [Fact]
    public async Task ConcurrentCategorySaveAndDiskFailureNeverOverwriteOtherMetadata()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await store.SaveAsync(Observed(DeviceInventoryData.Empty, Mac, Start), Guid.Empty);
        var other = new DeviceInventoryStore(Database);
        var concurrent = (await other.LoadMetadataAsync())!;
        await other.SaveAsync(concurrent with { Names = new Dictionary<string, string> { [Mac] = "Other edit" } }, concurrent.Revision);
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.SaveAsync(data.SetUsageCategoryOverride(Id, DeviceUsageCategory.Guest), data.Revision));
        data = (await store.LoadMetadataAsync())!;
        Assert.Equal("Other edit", data.Names[Mac]);
        Sql("CREATE TRIGGER fail_usage BEFORE UPDATE ON devices BEGIN SELECT RAISE(ABORT,'synthetic save failure'); END");
        await Assert.ThrowsAsync<IOException>(() => store.SaveAsync(data.SetUsageCategoryOverride(Id, DeviceUsageCategory.Guest), data.Revision));
        Assert.Null((await new DeviceInventoryStore(Database).LoadMetadataAsync())!.GetUsageCategoryOverride(Id));
        Sql("DROP TRIGGER fail_usage");
        data = await store.SaveAsync(data.SetUsageCategoryOverride(Id, DeviceUsageCategory.Guest), data.Revision);
        Assert.Equal("Other edit", data.Names[Mac]);
        Assert.Single(data.Devices[Mac].ScanHistory);
    }

    [Fact]
    public async Task OlderPayloadDefaultsToAutomaticAndInvalidSavedValuesAreRejected()
    {
        var path = Path.ChangeExtension(Database, ".json");
        await InventoryJsonFixture.WriteAsync(path, Observed(DeviceInventoryData.Empty, Mac, Start));
        var json = JsonNode.Parse(await File.ReadAllTextAsync(path))!;
        json["data"]!["devices"]![Mac]!.AsObject().Remove("usageCategoryOverride");
        foreach (var scan in json["data"]!["devices"]![Mac]!["scanHistory"]!.AsArray())
            scan!.AsObject().Remove("scanId");
        await File.WriteAllTextAsync(path, json.ToJsonString());
        var store = new DeviceInventoryStore(Database);
        var loaded = (await store.LoadMetadataAsync())!;
        Assert.Null(loaded.GetUsageCategoryOverride(Id));
        Assert.Throws<ArgumentOutOfRangeException>(() => loaded.SetUsageCategoryOverride(Id, (DeviceUsageCategory)99));
        Sql("UPDATE devices SET data=json_set(data,'$.usageCategoryOverride',99)");
        await Assert.ThrowsAsync<InvalidDataException>(() => new DeviceInventoryStore(Database).LoadMetadataAsync());
    }

    [Fact]
    public void EditorRetainsFailedDraftCancelAndReloadDoNotPretendToSave()
    {
        var edit = new UsageCategoryEditState();
        edit.Load(Id, DeviceUsageCategory.Permanent);
        var token = edit.Token;
        edit.Choose(DeviceUsageCategory.Personal);
        edit.BeginSave();
        edit.Failed("Disk full", false);
        Assert.Equal(DeviceUsageCategory.Personal, edit.Draft);
        Assert.Equal(DeviceUsageCategory.Permanent, edit.Saved);
        Assert.True(edit.HasChanges);
        edit.Cancel();
        Assert.False(edit.HasChanges);
        edit.Choose(null);
        edit.BeginSave();
        edit.Failed("Concurrent edit", true);
        Assert.Null(edit.Draft);
        Assert.Throws<InvalidOperationException>(edit.BeginSave);
        edit.Cancel();
        Assert.True(edit.NeedsReload);
        edit.BeginReload();
        Assert.True(edit.IsBusy);
        Assert.True(edit.IsReloading);
        Assert.Throws<InvalidOperationException>(edit.BeginReload);
        Assert.Throws<InvalidOperationException>(() => edit.Choose(DeviceUsageCategory.Guest));
        Assert.Throws<InvalidOperationException>(edit.Cancel);
        edit.Failed("Reload failed", true);
        Assert.False(edit.IsBusy);
        Assert.Equal(DeviceUsageCategory.Permanent, edit.Draft);
        edit.Load(Id, DeviceUsageCategory.Guest);
        Assert.NotEqual(token, edit.Token);
        Assert.False(edit.NeedsReload);
        Assert.Equal(DeviceUsageCategory.Guest, edit.Draft);
        Assert.False(edit.IsBusy);
    }

    [Fact]
    public void LoadingAndFailedEvidenceNeverInventAZeroRateOrHideAnOverride()
    {
        var row = new ScanResultRow(Observed(DeviceInventoryData.Empty, Mac, Start).Devices[Mac], 24);
        var filter = new DeviceResultFilter(false, false, "")
        {
            UsageCategories = new HashSet<DeviceUsageCategory> { DeviceUsageCategory.Unclassified }
        };
        foreach (var status in new[] { "Loading completed usage evidence...", "Usage evidence could not be loaded." })
        {
            row.SetUsageCategory(null, null, status);
            Assert.Null(row.EffectiveUsageCategory);
            Assert.Equal("Unavailable", row.UsageCategoryText);
            Assert.Contains(status, row.UsageCategoryDescription);
            Assert.DoesNotContain("%", row.UsageCategoryDescription);
            Assert.False(filter.Matches(row));
            row.SetUsageCategory(DeviceUsageCategory.Guest, null, status);
            Assert.Equal("Guest", row.UsageCategoryText);
            Assert.Equal("Manual override", row.UsageCategorySource);
            Assert.Contains(status, row.UsageCategoryDescription);
        }
    }

    [Fact]
    public void TableUsesEffectiveCategoryForSearchFilterSortAndPersistence()
    {
        var data = Observed(DeviceInventoryData.Empty, Mac, Start);
        var manual = new ScanResultRow(data.Devices[Mac], 24);
        manual.SetUsageCategory(DeviceUsageCategory.Personal, Infer(Evidence(12, 14, 0, 0)), "");
        var automatic = new ScanResultRow(data.Devices[Mac], 24);
        automatic.SetUsageCategory(null, Infer(Evidence(12, 14, 0, 0)), "");
        var filter = new DeviceResultFilter(false, false, "") { UsageCategories = new HashSet<DeviceUsageCategory> { DeviceUsageCategory.Personal } };
        Assert.True(filter.Matches(manual));
        Assert.False(filter.Matches(automatic));
        Assert.True(manual.MatchesFilter("personal"));
        Assert.Equal(1, filter.ActiveSecondaryCategoryCount);
        Assert.True(DeviceResultSort.Compare(automatic, manual, ResultSortColumn.UsageCategory, true) < 0);
        Assert.Contains("Manual", manual.UsageCategoryDescription);
        Assert.Contains("(86%)", automatic.UsageCategoryDescription);
        var layout = new DeviceColumnLayout();
        layout.UsageCategory.Width = 240;
        layout.UsageCategory.IsVisible = false;
        var restored = new DeviceColumnLayout();
        restored.Restore(layout.Capture());
        Assert.False(restored.UsageCategory.IsVisible);
        Assert.Equal(240, restored.UsageCategory.Width);
        restored.Reset();
        Assert.True(restored.UsageCategory.IsVisible);
        Assert.Equal(120, restored.UsageCategory.Width);
    }

    private static DeviceInventoryData Observed(DeviceInventoryData data, string mac, DateTimeOffset time, string vendor = "Example") =>
        data.ObserveCompletedScan("network", new("192.0.2.0/24", time,
            [new(IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1, TimeSpan.Zero, MacAddress: PhysicalAddress.Parse(mac), VendorName: vendor)])
            { ScanId = Guid.NewGuid(), NetworkId = "network" });

    private static AnalyticsScanEvidence Scan(DateTimeOffset time, bool responded) =>
        new(Guid.NewGuid(), time, time, ScanCheckpointState.Complete, 0,
            [responded ? AnalyticsResponse.Responded : AnalyticsResponse.DidNotRespond]);

    private static AnalyticsEvidence Evidence(int pr, int pe, int dr, int de) => new(
        Guid.NewGuid(), "network", "192.0.2.0/24", Start.AddDays(7).AddTicks(-1), TimeZoneInfo.Utc.Id,
        new(2026, 11, 2), new(2026, 11, 8), Start, [new(Id, Start.AddDays(-1), false)],
        Enumerable.Range(0, pe).Select(i => Scan(Start.AddHours(18).AddSeconds(i), i < pr))
            .Concat(Enumerable.Range(0, de).Select(i => Scan(Start.AddHours(9).AddSeconds(i), i < dr))).ToArray(), null);

    private static DeviceUsageInference Infer(AnalyticsEvidence evidence) => DeviceUsageClassifier.Classify(evidence)[evidence.Devices[0].Identity];
    private void Sql(string sql)
    {
        using var connection = new SqliteConnection($"Data Source={Database};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
