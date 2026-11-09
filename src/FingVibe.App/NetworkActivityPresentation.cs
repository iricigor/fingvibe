using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed record NetworkActivityDisplay(
    ActivityBuckets Buckets, IReadOnlyList<DeviceActivityCell> Cells, string Legend,
    int Contributors, int UnavailableContributors, int EvidenceCells, decimal? Maximum);

public static class NetworkActivityPresentation
{
    public static IReadOnlyList<ActivityContributor> Contributors(DeviceInventoryData data,
        AnalyticsEvidence evidence, CancellationToken cancellationToken = default)
    {
        if (data.Revision != evidence.Revision)
            throw new InvalidOperationException("Current metadata and activity evidence have different saved revisions.");
        var categories = DeviceUsageClassifier.Classify(
            evidence with { FirstDate = evidence.LastDate.AddDays(-6) }, cancellationToken);
        var slots = data.VirtualDevices.ToDictionary(slot => LogicalDeviceId.Virtual(slot.Id));
        var result = new ActivityContributor[evidence.Devices.Count];
        for (var index = 0; index < result.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var id = evidence.Devices[index].Identity;
            ScanResultRow row;
            Guid? room;
            if (id.Kind == "virtual")
            {
                var slot = slots[id];
                row = new(slot, data, 0);
                room = slot.Assignment?.RoomId;
            }
            else
            {
                row = new(data.Devices[id.Id], 0, classificationOverride: data.Classifications.GetValueOrDefault(id.Id));
                room = data.PeopleRooms.Assignments.GetValueOrDefault(id.Id)?.RoomId;
            }
            result[index] = new(id, room, row.Type, data.GetUsageCategoryOverride(id) ?? categories[id].Category);
        }
        return Array.AsReadOnly(result);
    }

    public static NetworkActivityDisplay Create(AnalyticsEvidence evidence, DeviceInventoryData data,
        int hours, bool weekdays, ActivityCountFilter filter, CancellationToken cancellationToken = default)
    {
        var contributors = Contributors(data, evidence, cancellationToken);
        var buckets = DeviceActivity.Group(evidence, hours, cancellationToken);
        var days = NetworkActivity.Count(buckets, contributors, filter, cancellationToken);
        var weekly = weekdays ? NetworkActivity.ByWeekday(days, cancellationToken) : [];
        var maximum = weekdays ? weekly.Max(day => day.Mean) : days
            .Where(day => day.IsApplicable && day.Coverage != AnalyticsCoverage.Unknown)
            .Select(day => (decimal?)day.Count).DefaultIfEmpty().Max();
        var cells = weekdays ? weekly.Select(day =>
        {
            var known = day.Mean is not null;
            var detail = $"{day.Day} {DeviceActivityPresentation.Interval(day.StartHour, day.Hours)}: " +
                (known ? $"Average {Format(day.Mean!.Value)} devices; exact sum {day.Numerator} / {day.ExactDates} exact dates. " +
                    $"Exact daily counts: {string.Join(", ", day.ExactDailyCounts)}. "
                    : "Unavailable - no exact daily counts. ") +
                $"{day.ExactDates} / {day.ApplicableDates} applicable dates observed; " +
                $"{day.PartialDates} partial dates excluded; {day.UnknownDates} unknown dates excluded; " +
                $"{day.IncludedDates - day.ApplicableDates} not applicable (skipped DST hour)." +
                (day.CurrentDates > 0 ? " Today is partial; only evidence collected so far is included." : "");
            return Cell(day.Day.ToString()[..3], $"{day.IncludedDates} days", day.StartHour, day.Hours,
                day.ApplicableDates > 0, day.Mean, maximum, day.PartialDates + day.UnknownDates > 0,
                day.ApplicableDates == 0 ? "-" : known ? Format(day.Mean!.Value) : "", detail);
        }).ToArray() : days.Select(day =>
        {
            var known = day.Coverage != AnalyticsCoverage.Unknown;
            var lowerBound = day.Coverage == AnalyticsCoverage.Partial;
            var description = !day.IsApplicable ? "Not applicable - skipped DST hour."
                : !known ? "Unknown - no eligible scan evidence."
                : lowerBound ? $"At least {day.Count} devices; incomplete evidence, excluded from exact weekday averages."
                : $"{day.Count} distinct devices; exact daily count.";
            var detail = $"{day.Date:ddd d MMM yyyy} {DeviceActivityPresentation.Interval(day.StartHour, day.Hours)}: " +
                $"{description} {day.CompletedScans} completed ledger scans; {day.LegacySamples} explicit legacy samples." +
                (day.IsPartialDate ? " Today is partial; later hours are unknown." : "");
            return Cell(day.Date.ToString("ddd d MMM", CultureInfo.CurrentCulture), "", day.StartHour, day.Hours,
                day.IsApplicable, known ? day.Count : null, maximum, lowerBound || !known,
                !day.IsApplicable ? "-" : !known ? "" : lowerBound ? $"{day.Count}+" : day.Count.ToString(CultureInfo.CurrentCulture), detail);
        }).ToArray();
        var selected = contributors.Select((device, index) => (device, index)).Where(item => filter.Matches(item.device)).ToArray();
        var unavailable = selected.Count(item => evidence.Devices[item.index].FirstReliableSighting is null
            || evidence.Devices[item.index].AmbiguousMapping);
        var unit = weekdays ? "Average devices" : "Distinct devices";
        var legend = maximum is null ? $"{unit}: unavailable (no exact values)."
            : !weekdays && maximum == 0 && days.All(day => day.Coverage != AnalyticsCoverage.Exact)
                ? $"{unit}: lower bound 0+ only; exact counts unavailable." : maximum == 0
            ? $"{unit}: 0 only; no positive range."
            : $"{unit}: 0 (slate) to {Format(maximum.Value)} (strongest green).";
        return new(buckets, cells, legend + " Hatching: missing/partial evidence. N+: at least N, not an exact count. -: not applicable.",
            selected.Length, unavailable, days.Count(day => day.Coverage != AnalyticsCoverage.Unknown), maximum);
    }

    private static DeviceActivityCell Cell(string row, string total, int hour, int hours, bool applicable,
        decimal? count, decimal? maximum, bool hatched, string value, string details) =>
        new(row, total, hour, hours, applicable,
            count is null ? AnalyticsResponse.Unknown : count == 0 ? AnalyticsResponse.DidNotRespond : AnalyticsResponse.Responded,
            count is null ? null : maximum > 0 ? count / maximum : 0, applicable && hatched, value, details);

    private static string Format(decimal value) => value.ToString("0.#", CultureInfo.CurrentCulture);
}
