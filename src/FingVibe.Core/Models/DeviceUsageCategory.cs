namespace FingVibe.Core.Models;

public enum DeviceUsageCategory { Unclassified, Permanent, Personal, Guest }

public sealed record UsageResponseCounts(int Responded, int Eligible)
{
    public decimal? Percentage => Eligible == 0 ? null : 100m * Responded / Eligible;
}

public sealed record DeviceUsageInference(
    LogicalDeviceId Identity, DeviceUsageCategory Category,
    UsageResponseCounts Total, UsageResponseCounts OvernightWeekend, UsageResponseCounts WeekdayDaytime,
    int ObservedDates, bool LimitedEvidence, DateOnly FirstDate, DateOnly LastDate,
    string NetworkId, string Subnet, string TimeZoneId);

public static class DeviceUsageClassifier
{
    public static IReadOnlyDictionary<LogicalDeviceId, DeviceUsageInference> Classify(
        AnalyticsEvidence evidence, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(evidence);
        if (evidence.FirstDate != evidence.LastDate.AddDays(-6))
            throw new ArgumentException("Usage classification requires the seven-date evidence window.", nameof(evidence));
        var counts = evidence.Devices.Select(_ => new Counts()).ToArray();
        var seen = new HashSet<(Guid?, long)>();
        foreach (var scan in evidence.Scans)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (scan.Responses.Count != counts.Length)
                throw new ArgumentException("Scan responses must align with the selected devices.", nameof(evidence));
            var date = DateOnly.FromDateTime(scan.LocalCompletedAt.DateTime);
            if (scan.State is ScanCheckpointState.Pending or ScanCheckpointState.Incomplete
                || scan.CompletedAt < evidence.WindowStart || scan.CompletedAt > evidence.QueryTime
                || date < evidence.FirstDate || date > evidence.LastDate
                || !seen.Add((scan.ScanId, scan.ScanId is null ? scan.CompletedAt.UtcTicks : 0)))
                continue;
            var preferred = scan.LocalCompletedAt.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday
                || scan.LocalCompletedAt.Hour < 6 || scan.LocalCompletedAt.Hour >= 18;
            for (var index = 0; index < counts.Length; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (evidence.Devices[index].FirstReliableSighting is not { } first || scan.CompletedAt < first)
                    continue;
                var response = scan.Responses[index];
                if (response == AnalyticsResponse.Unknown) continue;
                if (response is not (AnalyticsResponse.Responded or AnalyticsResponse.DidNotRespond))
                    throw new ArgumentException("Unknown analytics response value.", nameof(evidence));
                var count = counts[index];
                count.Dates.Add(date);
                var group = preferred ? 0 : 1;
                count.Eligible[group]++;
                if (response == AnalyticsResponse.Responded) count.Responded[group]++;
            }
        }
        var results = new Dictionary<LogicalDeviceId, DeviceUsageInference>();
        var zone = TimeZoneInfo.FindSystemTimeZoneById(evidence.TimeZoneId);
        for (var index = 0; index < counts.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var device = evidence.Devices[index];
            var count = counts[index];
            var preferred = new UsageResponseCounts(count.Responded[0], count.Eligible[0]);
            var daytime = new UsageResponseCounts(count.Responded[1], count.Eligible[1]);
            var total = new UsageResponseCounts(preferred.Responded + daytime.Responded, preferred.Eligible + daytime.Eligible);
            var category = Category(total, preferred, daytime);
            var limited = count.Dates.Count < 7 || total.Eligible < 30
                || category == DeviceUsageCategory.Personal && (preferred.Eligible < 10 || daytime.Eligible < 10);
            var firstDate = device.FirstReliableSighting is { } first
                ? DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(first, zone).DateTime) : evidence.FirstDate;
            results.Add(device.Identity, new(device.Identity, category, total, preferred, daytime,
                count.Dates.Count, limited, firstDate > evidence.FirstDate ? firstDate : evidence.FirstDate,
                evidence.LastDate, evidence.NetworkId, evidence.Subnet, evidence.TimeZoneId));
        }
        return results;
    }

    private static DeviceUsageCategory Category(UsageResponseCounts total,
        UsageResponseCounts preferred, UsageResponseCounts daytime)
    {
        if (total.Eligible == 0) return DeviceUsageCategory.Unclassified;
        if (100L * total.Responded >= 80L * total.Eligible) return DeviceUsageCategory.Permanent;
        if (100L * total.Responded <= 10L * total.Eligible) return DeviceUsageCategory.Guest;
        // Cross-products preserve exact threshold equality, including repeating fractions.
        if (preferred.Eligible > 0 && daytime.Eligible > 0
            && 100L * preferred.Responded >= 60L * preferred.Eligible
            && 100m * preferred.Responded * daytime.Eligible
                >= 100m * daytime.Responded * preferred.Eligible + 20m * preferred.Eligible * daytime.Eligible)
            return DeviceUsageCategory.Personal;
        return DeviceUsageCategory.Unclassified;
    }

    private sealed class Counts
    {
        public int[] Eligible { get; } = new int[2];
        public int[] Responded { get; } = new int[2];
        public HashSet<DateOnly> Dates { get; } = [];
    }
}
