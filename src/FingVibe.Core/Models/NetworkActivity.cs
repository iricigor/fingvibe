namespace FingVibe.Core.Models;

public sealed record ActivityContributor(
    LogicalDeviceId Identity, Guid? RoomId, DeviceType Type, DeviceUsageCategory Category);

public sealed record ActivityCountFilter(
    Guid? RoomId = null, bool UnassignedRoomOnly = false,
    DeviceType? Type = null, DeviceUsageCategory? Category = null)
{
    public bool Matches(ActivityContributor device) =>
        (RoomId is null || device.RoomId == RoomId)
        && (!UnassignedRoomOnly || device.RoomId is null)
        && (Type is null || device.Type == Type)
        && (Category is null || device.Category == Category);
}

public sealed record ActivityCountDay(
    DateOnly Date, int StartHour, int Hours, bool IsApplicable, bool IsPartialDate,
    int Count, AnalyticsCoverage Coverage, int CompletedScans, int LegacySamples);

public sealed record ActivityCountWeekday(
    DayOfWeek Day, int StartHour, int Hours, int IncludedDates, int ApplicableDates,
    long Numerator, int ExactDates, int PartialDates, int UnknownDates, int CurrentDates,
    IReadOnlyList<int> ExactDailyCounts)
{
    public decimal? Mean => ExactDates == 0 ? null : (decimal)Numerator / ExactDates;
}

public static class NetworkActivity
{
    public static IReadOnlyList<ActivityCountDay> Count(ActivityBuckets buckets,
        IReadOnlyList<ActivityContributor> contributors, ActivityCountFilter filter,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(buckets);
        ArgumentNullException.ThrowIfNull(contributors);
        ArgumentNullException.ThrowIfNull(filter);
        if (contributors.Count != buckets.Devices.Count
            || contributors.Where((device, index) => device.Identity != buckets.Devices[index].Identity).Any())
            throw new ArgumentException("Contributors must align with the activity identities.", nameof(contributors));
        var selected = contributors.Select((device, index) => (device, index))
            .Where(item => filter.Matches(item.device)).Select(item => item.index).ToArray();
        var days = new ActivityCountDay[buckets.Days.Count];
        for (var index = 0; index < days.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var bucket = buckets.Days[index];
            var count = 0;
            var coverage = bucket.Scans.Count == 0 ? AnalyticsCoverage.Unknown
                : bucket.Scans.Any(scan => !scan.HasCompletedLedger || scan.UnidentifiedResponses != 0)
                    ? AnalyticsCoverage.Partial : AnalyticsCoverage.Exact;
            foreach (var device in selected)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var response = bucket.Devices[device];
                if (response.Responded > 0) count++;
                if (coverage != AnalyticsCoverage.Unknown && response.Unknown > 0)
                    coverage = AnalyticsCoverage.Partial;
            }
            days[index] = new(bucket.Date, bucket.StartHour, bucket.Hours, bucket.IsApplicable,
                bucket.IsPartialDate, count, coverage, bucket.CompletedScanCount, bucket.LegacySampleCount);
        }
        return Array.AsReadOnly(days);
    }

    public static IReadOnlyList<ActivityCountWeekday> ByWeekday(IReadOnlyList<ActivityCountDay> days,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(days);
        var results = new List<ActivityCountWeekday>();
        foreach (var group in days.GroupBy(day => (day.Date.DayOfWeek, day.StartHour, day.Hours))
                     .OrderBy(group => ((int)group.Key.DayOfWeek + 6) % 7).ThenBy(group => group.Key.StartHour))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var applicable = group.Where(day => day.IsApplicable).ToArray();
            var exact = applicable.Where(day => day.Coverage == AnalyticsCoverage.Exact).ToArray();
            results.Add(new(group.Key.DayOfWeek, group.Key.StartHour, group.Key.Hours, group.Count(),
                applicable.Length, exact.Sum(day => (long)day.Count), exact.Length,
                applicable.Count(day => day.Coverage == AnalyticsCoverage.Partial),
                applicable.Count(day => day.Coverage == AnalyticsCoverage.Unknown),
                applicable.Count(day => day.IsPartialDate), Array.AsReadOnly(exact.Select(day => day.Count).ToArray())));
        }
        return results.AsReadOnly();
    }
}
