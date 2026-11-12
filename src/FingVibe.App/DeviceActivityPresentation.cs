using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed record DeviceActivityCell(
    string RowLabel, string RowTotal, int StartHour, int Hours, bool IsApplicable,
    AnalyticsResponse Response, decimal? Fraction, bool Hatched, string Value, string Details)
{
    public bool IsFuture { get; init; }
}

public static class DeviceActivityPresentation
{
    public static IReadOnlyList<DeviceActivityCell> Cells(ActivityBuckets buckets, bool weekdays)
    {
        if (buckets.Devices.Count != 1)
            throw new ArgumentException("Device Activity displays exactly one logical identity.", nameof(buckets));
        if (weekdays)
            return DeviceActivity.ByWeekday(buckets, 0).Select(bucket =>
            {
                var known = bucket.RespondingDates + bucket.NonrespondingDates > 0;
                var state = bucket.RespondingDates > 0 ? AnalyticsResponse.Responded
                    : known ? AnalyticsResponse.DidNotRespond : AnalyticsResponse.Unknown;
                var detail = $"{bucket.Day} {Interval(bucket.StartHour, bucket.Hours)}: " +
                    $"{bucket.RespondingDates} responding days / {bucket.ApplicableDates} applicable dates; " +
                    $"{bucket.NonrespondingDates} nonresponding dates; {bucket.UnknownDates} dates without eligible evidence. " +
                    $"{bucket.IncludedDates - bucket.ApplicableDates} not applicable (skipped DST hour). " +
                    Counts(bucket.Scans) + (bucket.PartialDates > 0 ? " Today is partial; later hours are unknown." : string.Empty);
                return new DeviceActivityCell(bucket.Day.ToString()[..3], $"{bucket.IncludedDates} days",
                    bucket.StartHour, bucket.Hours, bucket.ApplicableDates > 0, state, bucket.RespondingFraction,
                    bucket.UnknownDates > 0, bucket.ApplicableDates == 0 ? "-" : known ? bucket.RespondingDates.ToString(CultureInfo.CurrentCulture) : "",
                    detail);
            }).ToArray();
        return buckets.Days.Select(bucket =>
        {
            var count = bucket.Devices[0];
            var state = count.Response;
            var localNow = TimeZoneInfo.ConvertTimeBySystemTimeZoneId(buckets.QueryTime, buckets.TimeZoneId);
            var future = bucket.Date == DateOnly.FromDateTime(localNow.DateTime) && bucket.StartHour > localNow.Hour;
            var detail = $"{bucket.Date:ddd d MMM yyyy} {Interval(bucket.StartHour, bucket.Hours)}: " +
                (!bucket.IsApplicable ? "Not applicable - skipped DST hour. "
                    : future ? "Later today - no scan data yet. "
                    : state == AnalyticsResponse.Unknown ? "Unknown - no eligible scans. "
                    : state == AnalyticsResponse.Responded ? "At least one response. " : "Scanned, no response. ") +
                Counts(count) + $" {bucket.CompletedScanCount} completed ledger scans; {bucket.LegacySampleCount} explicit legacy samples." +
                (bucket.IsPartialDate ? " Today is partial; later hours are unknown." : string.Empty);
            return new DeviceActivityCell(bucket.Date.ToString("ddd d MMM", CultureInfo.CurrentCulture), "",
                bucket.StartHour, bucket.Hours, bucket.IsApplicable, state,
                state == AnalyticsResponse.Unknown ? null : state == AnalyticsResponse.Responded ? 1m : 0m,
                bucket.IsApplicable && state == AnalyticsResponse.Unknown && !future, bucket.IsApplicable ? "" : "-", detail)
                { IsFuture = future && bucket.IsApplicable };
        }).ToArray();
    }

    public static int CoveredDates(ActivityBuckets buckets) =>
        buckets.Days.Where(bucket => bucket.IsApplicable && bucket.Devices[0].Eligible > 0)
            .Select(bucket => bucket.Date).Distinct().Count();

    public static int PopulatedSquares(IReadOnlyList<DeviceActivityCell> cells) =>
        cells.Count(cell => cell.IsApplicable && cell.Response != AnalyticsResponse.Unknown);

    public static string Interval(int startHour, int hours) => $"{startHour:00}:00-{startHour + hours:00}:00";
    private static string Counts(ActivityResponseCounts counts) =>
        $"{counts.Responded} responses, {counts.DidNotRespond} nonresponses, {counts.Unknown} unknown scan samples.";
}
