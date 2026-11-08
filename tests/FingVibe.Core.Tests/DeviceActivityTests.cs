using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceActivityTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-11-07T18:00:00Z");
    private static readonly LogicalDeviceId A = LogicalDeviceId.Mac("001122334455");
    private static readonly LogicalDeviceId B = LogicalDeviceId.Virtual(Guid.Parse("00000000-0000-0000-0000-000000000001"));
    private static AnalyticsScanEvidence Scan(string time, params AnalyticsResponse[] responses)
    {
        var instant = DateTimeOffset.Parse(time);
        return new(Guid.NewGuid(), instant, instant, ScanCheckpointState.Complete, 0, responses);
    }

    private static AnalyticsEvidence Evidence(IReadOnlyList<AnalyticsScanEvidence> scans, int days = 7,
        DateTimeOffset? now = null, TimeZoneInfo? zone = null, IReadOnlyList<AnalyticsDevice>? devices = null)
    {
        var time = now ?? Now;
        zone ??= TimeZoneInfo.Utc;
        var last = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(time, zone).DateTime);
        var first = last.AddDays(1 - days);
        var local = first.ToDateTime(TimeOnly.MinValue, DateTimeKind.Unspecified);
        return new(Guid.NewGuid(), "network-a", "192.0.2.0/24", time, zone.Id, first, last,
            new DateTimeOffset(local, zone.GetUtcOffset(local)),
            devices ?? [new(A, time.AddDays(-40), false)], scans, null);
    }

    [Theory]
    [InlineData(1, 24)]
    [InlineData(2, 12)]
    [InlineData(3, 8)]
    [InlineData(4, 6)]
    public void EveryStopIsMidnightAlignedAndStartInclusiveEndExclusive(int hours, int columns)
    {
        var scans = new[]
        {
            Scan("2026-11-06T00:00:00Z", AnalyticsResponse.Responded),
            Scan($"2026-11-06T{hours:00}:00:00Z", AnalyticsResponse.DidNotRespond),
            Scan("2026-11-07T00:00:00Z", AnalyticsResponse.Responded),
            Scan("2026-11-07T18:00:00Z", AnalyticsResponse.DidNotRespond),
            Scan("2026-11-07T18:00:00.0000001Z", AnalyticsResponse.Responded)
        };
        var buckets = DeviceActivity.Group(Evidence(scans), hours);
        Assert.Equal(7 * columns, buckets.Days.Count);
        var previous = buckets.Days.Where(bucket => bucket.Date == new DateOnly(2026, 11, 6)).ToArray();
        Assert.Equal(Enumerable.Range(0, columns).Select(i => i * hours), previous.Select(bucket => bucket.StartHour));
        Assert.Equal(1, previous[0].Devices[0].Responded);
        Assert.Equal(1, previous[1].Devices[0].DidNotRespond);
        Assert.Equal(24, previous[^1].StartHour + previous[^1].Hours);
        Assert.Equal(4, buckets.Days.Sum(bucket => bucket.Scans.Count));
        Assert.Equal(1, buckets.Days.Last(bucket => bucket.StartHour == 0).Devices[0].Responded);
        Assert.All(buckets.Days.Where(bucket => bucket.Date == buckets.LastDate), bucket => Assert.True(bucket.IsPartialDate));
    }

    [Fact]
    public void DailyResponseWinsWithoutInterpolationAndPreservesExactSampleCounts()
    {
        var evidence = Evidence([
            Scan("2026-11-02T09:00:00Z", AnalyticsResponse.Responded),
            Scan("2026-11-02T09:20:00Z", AnalyticsResponse.DidNotRespond),
            Scan("2026-11-02T09:40:00Z", AnalyticsResponse.DidNotRespond),
            Scan("2026-11-02T10:00:00Z", AnalyticsResponse.DidNotRespond)
        ]);
        var buckets = DeviceActivity.Group(evidence, 1);
        var morning = buckets.Days.Single(bucket => bucket.Date.Day == 2 && bucket.StartHour == 9);
        Assert.Equal(new ActivityResponseCounts(1, 2, 0), morning.Devices[0]);
        Assert.Equal(AnalyticsResponse.Responded, morning.Devices[0].Response);
        Assert.Equal(AnalyticsCoverage.Exact, morning.Coverage);
        Assert.Equal(3, morning.CompletedScanCount);
        Assert.Equal(new[] { A }, morning.RespondingIdentities);
        var cells = DeviceActivityPresentation.Cells(buckets, false);
        var positive = cells.Single(cell => cell.RowLabel.StartsWith("Mon") && cell.StartHour == 9);
        Assert.Equal(1m, positive.Fraction);
        Assert.Equal("", positive.Value);
        Assert.Contains("1 responses, 2 nonresponses", positive.Details);
        var negative = cells.Single(cell => cell.RowLabel.StartsWith("Mon") && cell.StartHour == 10);
        Assert.Equal(AnalyticsResponse.DidNotRespond, negative.Response);
        Assert.False(negative.Hatched);
        Assert.True(cells.Single(cell => cell.RowLabel.StartsWith("Mon") && cell.StartHour == 11).Hatched);
    }

    [Fact]
    public void ThreeRespondingWednesdaysAndOneUnknownAreThreeOfFourNotThreeOfThree()
    {
        var evidence = Evidence([
            Scan("2026-10-14T12:00:00Z", AnalyticsResponse.Responded),
            Scan("2026-10-21T12:00:00Z", AnalyticsResponse.Responded),
            Scan("2026-10-28T12:00:00Z", AnalyticsResponse.Responded)
        ], days: 30);
        var buckets = DeviceActivity.Group(evidence, 1);
        var wednesday = DeviceActivity.ByWeekday(buckets, 0).Single(bucket => bucket.Day == DayOfWeek.Wednesday && bucket.StartHour == 12);
        Assert.Equal((4, 4, 3, 0, 1, .75m), (wednesday.IncludedDates, wednesday.ApplicableDates,
            wednesday.RespondingDates, wednesday.NonrespondingDates, wednesday.UnknownDates, wednesday.RespondingFraction));
        var cell = DeviceActivityPresentation.Cells(buckets, true).Single(cell => cell.RowLabel == "Wed" && cell.StartHour == 12);
        Assert.Equal("3", cell.Value);
        Assert.Equal("4 days", cell.RowTotal);
        Assert.True(cell.Hatched);
        Assert.Equal(.75m, cell.Fraction);
        Assert.Contains("3 responding days / 4 applicable dates", cell.Details);
    }

    [Fact]
    public void KnownZeroUnknownAndFullGreenRemainDistinct()
    {
        var scans = Enumerable.Range(0, 4).Select(index =>
            Scan($"2026-10-{9 + index * 7:00}T09:00:00Z", AnalyticsResponse.Responded)).ToList();
        scans.Add(Scan("2026-11-06T09:00:00Z", AnalyticsResponse.Responded));
        scans.Add(Scan("2026-11-06T10:00:00Z", AnalyticsResponse.DidNotRespond));
        var cells = DeviceActivityPresentation.Cells(DeviceActivity.Group(Evidence(scans, 30), 1), true);
        var full = cells.Single(cell => cell.RowLabel == "Fri" && cell.StartHour == 9);
        Assert.Equal("5", full.Value);
        Assert.Equal(1m, full.Fraction);
        Assert.False(full.Hatched);
        var negative = cells.Single(cell => cell.RowLabel == "Fri" && cell.StartHour == 10);
        Assert.Equal("0", negative.Value);
        Assert.Equal(0m, negative.Fraction);
        Assert.True(negative.Hatched);
        var unknown = cells.Single(cell => cell.RowLabel == "Fri" && cell.StartHour == 11);
        Assert.Equal("", unknown.Value);
        Assert.Null(unknown.Fraction);
        Assert.True(unknown.Hatched);
    }

    [Fact]
    public void SharedBucketsRetainIdentityUnionPartialEligibilityAndAlignedScans()
    {
        var first = Scan("2026-11-02T09:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Unknown);
        var second = Scan("2026-11-02T09:30:00Z", AnalyticsResponse.DidNotRespond, AnalyticsResponse.Responded);
        var evidence = Evidence([first, first, second],
            devices: [new(A, Now.AddDays(-40), false), new(B, second.CompletedAt, false)]);
        var buckets = DeviceActivity.Group(evidence, 3);
        var bucket = buckets.Days.Single(bucket => bucket.Date.Day == 2 && bucket.StartHour == 9);
        Assert.Equal(new[] { A, B }, bucket.RespondingIdentities);
        Assert.Equal(2, bucket.CompletedScanCount);
        Assert.Equal(new ActivityResponseCounts(1, 1, 0), bucket.Devices[0]);
        Assert.Equal(new ActivityResponseCounts(1, 0, 1), bucket.Devices[1]);
        Assert.Equal(AnalyticsCoverage.Partial, bucket.Coverage);
        Assert.Same(first, bucket.Scans[0]);
        Assert.Equal(evidence.Devices, buckets.Devices);
        Assert.Equal(evidence.NetworkId, buckets.NetworkId);
        Assert.Equal(evidence.Subnet, buckets.Subnet);
    }

    [Fact]
    public void FirstSightingImportedAmbiguousAndIncompleteEvidenceNeverManufactureAbsence()
    {
        var first = DateTimeOffset.Parse("2026-11-02T10:00:00Z");
        var evidence = Evidence([
            Scan("2026-11-02T09:00:00Z", AnalyticsResponse.DidNotRespond, AnalyticsResponse.Unknown),
            Scan("2026-11-02T10:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Unknown),
            Scan("2026-11-02T11:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded) with { State = ScanCheckpointState.Incomplete }
        ], devices: [new(A, first, false), new(B, null, true)]);
        var buckets = DeviceActivity.Group(evidence, 1);
        Assert.All(buckets.Days.Where(bucket => bucket.StartHour == 9),
            bucket => Assert.Equal(AnalyticsResponse.Unknown, bucket.Devices[0].Response));
        Assert.All(buckets.Days, bucket => Assert.Equal(AnalyticsResponse.Unknown, bucket.Devices[1].Response));
        Assert.All(buckets.Days.Where(bucket => bucket.StartHour == 11), bucket => Assert.Empty(bucket.Scans));
    }

    [Fact]
    public void ExplicitLegacyEvidenceIsNotACompletedLedgerOrAWholeHistoryLoad()
    {
        var legacy = Scan("2026-11-02T09:00:00Z", AnalyticsResponse.Responded) with { ScanId = null, State = null };
        var buckets = DeviceActivity.Group(Evidence([
            legacy, legacy,
            Scan("2026-10-30T09:00:00Z", AnalyticsResponse.Responded),
            Scan("2026-11-08T09:00:00Z", AnalyticsResponse.Responded)
        ]), 1);
        var bucket = Assert.Single(buckets.Days, bucket => bucket.Scans.Count > 0);
        Assert.Equal(0, bucket.CompletedScanCount);
        Assert.Equal(1, bucket.LegacySampleCount);
        Assert.Equal(AnalyticsCoverage.Partial, bucket.Coverage);
        Assert.Equal(1, bucket.Devices[0].Responded);
    }

    [Fact]
    public void SkippedHourIsNotApplicableAndExcludedOnlyFromItsWeekdayDenominator()
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin");
        var evidence = Evidence([], 30, DateTimeOffset.Parse("2026-03-29T12:00:00Z"), zone);
        var hourly = DeviceActivity.Group(evidence, 1);
        var skipped = hourly.Days.Single(bucket => bucket.Date.Day == 29 && bucket.StartHour == 2);
        Assert.False(skipped.IsApplicable);
        var weekday = DeviceActivity.ByWeekday(hourly, 0).Single(bucket => bucket.Day == DayOfWeek.Sunday && bucket.StartHour == 2);
        Assert.Equal(5, weekday.IncludedDates);
        Assert.Equal(4, weekday.ApplicableDates);
        Assert.Equal(4, weekday.UnknownDates);
        Assert.Null(weekday.RespondingFraction);
        var daily = DeviceActivityPresentation.Cells(hourly, false).Single(cell => cell.RowLabel == "Sun 29 Mar" && cell.StartHour == 2);
        Assert.Equal("-", daily.Value);
        Assert.False(daily.Hatched);
        var mixed = DeviceActivity.Group(evidence, 3).Days.Single(bucket => bucket.Date.Day == 29 && bucket.StartHour == 0);
        Assert.True(mixed.IsApplicable);
    }

    [Fact]
    public void RepeatedHourCombinesBothInstantsAndCountsDeviceOnce()
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin");
        var evidence = Evidence([
            Scan("2026-10-25T02:30:00+02:00", AnalyticsResponse.Responded),
            Scan("2026-10-25T02:30:00+01:00", AnalyticsResponse.Responded)
        ], now: DateTimeOffset.Parse("2026-10-25T12:00:00Z"), zone: zone);
        var buckets = DeviceActivity.Group(evidence, 1);
        var bucket = buckets.Days.Single(bucket => bucket.Date.Day == 25 && bucket.StartHour == 2);
        Assert.Equal(2, bucket.Devices[0].Responded);
        Assert.Single(bucket.RespondingIdentities);
        var weekday = DeviceActivity.ByWeekday(buckets, 0).Single(bucket => bucket.Day == DayOfWeek.Sunday && bucket.StartHour == 2);
        Assert.Equal(1, weekday.RespondingDates);
    }

    [Fact]
    public void EmptySelectionRetainsKnownZeroForFutureAggregateConsumers()
    {
        var buckets = DeviceActivity.Group(Evidence([Scan("2026-11-02T09:00:00Z")], devices: []), 1);
        var known = Assert.Single(buckets.Days, bucket => bucket.Scans.Count > 0);
        Assert.Empty(known.RespondingIdentities);
        Assert.Equal(AnalyticsCoverage.Exact, known.Coverage);
        Assert.Equal(AnalyticsCoverage.Unknown, buckets.Days[0].Coverage);
    }

    [Fact]
    public void CancellationAndInvalidAlignmentFailExplicitly()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => DeviceActivity.Group(Evidence([]), 1, cancellation.Token));
        var grouped = DeviceActivity.Group(Evidence([]), 1);
        Assert.Throws<OperationCanceledException>(() => DeviceActivity.ByWeekday(grouped, 0, cancellation.Token));
        Assert.Throws<ArgumentOutOfRangeException>(() => DeviceActivity.Group(Evidence([]), 5));
        Assert.Throws<ArgumentException>(() => DeviceActivity.Group(Evidence([Scan("2026-11-02T09:00:00Z")]), 1));
        Assert.Throws<ArgumentException>(() => DeviceActivity.Group(Evidence([], devices: [new(A, Now, false), new(A, Now, false)]), 1));
    }
}
