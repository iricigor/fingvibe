namespace FingVibe.Core.Models;

public readonly record struct ActivityResponseCounts(int Responded, int DidNotRespond, int Unknown)
{
    public int Eligible => Responded + DidNotRespond;
    public AnalyticsResponse Response => Responded > 0 ? AnalyticsResponse.Responded
        : DidNotRespond > 0 ? AnalyticsResponse.DidNotRespond : AnalyticsResponse.Unknown;
}

// Device counts and scan responses retain the same alignment as ActivityBuckets.Devices.
public sealed record ActivityDayBucket(
    DateOnly Date, int StartHour, int Hours, bool IsApplicable, bool IsPartialDate,
    IReadOnlyList<ActivityResponseCounts> Devices, IReadOnlyList<AnalyticsScanEvidence> Scans,
    IReadOnlyList<LogicalDeviceId> RespondingIdentities, AnalyticsCoverage Coverage)
{
    public int CompletedScanCount => Scans.Count(scan => scan.HasCompletedLedger);
    public int LegacySampleCount => Scans.Count(scan => !scan.HasCompletedLedger);
}

public sealed record ActivityBuckets(
    string NetworkId, string Subnet, DateTimeOffset QueryTime, string TimeZoneId,
    DateOnly FirstDate, DateOnly LastDate, int Hours, IReadOnlyList<AnalyticsDevice> Devices,
    IReadOnlyList<ActivityDayBucket> Days);

public sealed record ActivityWeekdayBucket(
    DayOfWeek Day, int StartHour, int Hours, int IncludedDates, int ApplicableDates,
    int RespondingDates, int NonrespondingDates, int UnknownDates, int PartialDates,
    ActivityResponseCounts Scans)
{
    public decimal? RespondingFraction => ApplicableDates == 0 || RespondingDates + NonrespondingDates == 0
        ? null : (decimal)RespondingDates / ApplicableDates;
}

public static class DeviceActivity
{
    public static ActivityBuckets Group(AnalyticsEvidence evidence, int hours,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(evidence);
        if (hours is < 1 or > 4)
            throw new ArgumentOutOfRangeException(nameof(hours), "Activity groups must be 1, 2, 3 or 4 hours.");
        var dates = evidence.LastDate.DayNumber - evidence.FirstDate.DayNumber + 1;
        if (dates is not (7 or 30) || evidence.Devices.Select(device => device.Identity).Distinct().Count() != evidence.Devices.Count)
            throw new ArgumentException("Activity requires 7 or 30 dates and unique aligned identities.", nameof(evidence));
        var zone = TimeZoneInfo.FindSystemTimeZoneById(evidence.TimeZoneId);
        var columns = 24 / hours;
        var grouped = new List<AnalyticsScanEvidence>?[dates * columns];
        var seen = new HashSet<(Guid?, long)>();
        foreach (var scan in evidence.Scans)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (scan.Responses.Count != evidence.Devices.Count)
                throw new ArgumentException("Scan responses must align with selected identities.", nameof(evidence));
            if (scan.State is ScanCheckpointState.Pending or ScanCheckpointState.Incomplete
                || scan.CompletedAt < evidence.WindowStart || scan.CompletedAt > evidence.QueryTime)
                continue;
            var local = TimeZoneInfo.ConvertTime(scan.CompletedAt, zone);
            var date = DateOnly.FromDateTime(local.DateTime);
            if (date < evidence.FirstDate || date > evidence.LastDate
                || !seen.Add((scan.ScanId, scan.ScanId is null ? scan.CompletedAt.UtcTicks : 0)))
                continue;
            var index = (date.DayNumber - evidence.FirstDate.DayNumber) * columns + local.Hour / hours;
            (grouped[index] ??= []).Add(scan);
        }
        var buckets = new ActivityDayBucket[grouped.Length];
        for (var index = 0; index < buckets.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var date = evidence.FirstDate.AddDays(index / columns);
            var hour = index % columns * hours;
            var localStart = date.ToDateTime(new TimeOnly(hour, 0), DateTimeKind.Unspecified);
            var applicable = false;
            for (var minute = 0; minute < hours * 60 && !applicable; minute++)
                applicable = !zone.IsInvalidTime(localStart.AddMinutes(minute));
            var counts = new ActivityResponseCounts[evidence.Devices.Count];
            var scans = grouped[index]?.ToArray() ?? [];
            var coverage = scans.Length == 0 ? AnalyticsCoverage.Unknown : AnalyticsCoverage.Exact;
            foreach (var scan in scans)
            {
                if (!scan.HasCompletedLedger || scan.UnidentifiedResponses != 0)
                    coverage = AnalyticsCoverage.Partial;
                for (var deviceIndex = 0; deviceIndex < counts.Length; deviceIndex++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var response = evidence.Devices[deviceIndex].FirstReliableSighting is { } first
                        && scan.CompletedAt >= first ? scan.Responses[deviceIndex] : AnalyticsResponse.Unknown;
                    var count = counts[deviceIndex];
                    counts[deviceIndex] = response switch
                    {
                        AnalyticsResponse.Responded => count with { Responded = count.Responded + 1 },
                        AnalyticsResponse.DidNotRespond => count with { DidNotRespond = count.DidNotRespond + 1 },
                        AnalyticsResponse.Unknown => count with { Unknown = count.Unknown + 1 },
                        _ => throw new ArgumentException("Invalid analytics response.", nameof(evidence))
                    };
                    if (response == AnalyticsResponse.Unknown) coverage = AnalyticsCoverage.Partial;
                }
            }
            var contributors = evidence.Devices.Where((_, deviceIndex) => counts[deviceIndex].Responded > 0)
                .Select(device => device.Identity).ToArray();
            buckets[index] = new(date, hour, hours, applicable, date == evidence.LastDate,
                Array.AsReadOnly(counts), Array.AsReadOnly(scans), Array.AsReadOnly(contributors), coverage);
        }
        return new(evidence.NetworkId, evidence.Subnet, evidence.QueryTime, evidence.TimeZoneId,
            evidence.FirstDate, evidence.LastDate, hours, evidence.Devices, Array.AsReadOnly(buckets));
    }

    public static IReadOnlyList<ActivityWeekdayBucket> ByWeekday(ActivityBuckets buckets, int deviceIndex,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(buckets);
        if (deviceIndex < 0 || deviceIndex >= buckets.Devices.Count)
            throw new ArgumentOutOfRangeException(nameof(deviceIndex));
        var results = new List<ActivityWeekdayBucket>();
        foreach (var day in new[] { DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday,
                     DayOfWeek.Thursday, DayOfWeek.Friday, DayOfWeek.Saturday, DayOfWeek.Sunday })
        {
            for (var hour = 0; hour < 24; hour += buckets.Hours)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var matching = buckets.Days.Where(bucket => bucket.Date.DayOfWeek == day && bucket.StartHour == hour).ToArray();
                var applicable = matching.Where(bucket => bucket.IsApplicable).ToArray();
                var counts = applicable.Select(bucket => bucket.Devices[deviceIndex]).ToArray();
                var responding = counts.Count(count => count.Response == AnalyticsResponse.Responded);
                var negative = counts.Count(count => count.Response == AnalyticsResponse.DidNotRespond);
                results.Add(new(day, hour, buckets.Hours, matching.Length, applicable.Length, responding, negative,
                    applicable.Length - responding - negative, applicable.Count(bucket => bucket.IsPartialDate),
                    new(counts.Sum(count => count.Responded), counts.Sum(count => count.DidNotRespond),
                        counts.Sum(count => count.Unknown))));
            }
        }
        return results.AsReadOnly();
    }
}
