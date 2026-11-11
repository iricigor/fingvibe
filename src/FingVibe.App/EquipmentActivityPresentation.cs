using System.Globalization;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;

namespace FingVibe.App;

public sealed record EquipmentActivityDisplay(
    NetworkActivityDisplay Grid, EquipmentScanStatus Latest, string Contributors,
    IReadOnlyDictionary<LogicalDeviceId, DeviceUsageInference> Categories);

public static class EquipmentActivityPresentation
{
    public static async Task<EquipmentActivityDisplay> LoadAsync(DeviceInventoryStore store, DeviceInventoryData data,
        Guid personId, AnalyticsEvidenceRequest request, int hours, bool weekdays, CancellationToken cancellationToken = default)
    {
        var selection = EquipmentActivity.Select(data, personId, request.NetworkId, request.Subnet);
        var evidence = await store.QueryAnalyticsAsync(request with { Devices = selection.QueryDevices }, cancellationToken);
        return Create(EquipmentActivity.IncludeUnavailable(evidence, selection), data, hours, weekdays, cancellationToken);
    }

    public static EquipmentActivityDisplay Create(AnalyticsEvidence evidence, DeviceInventoryData data,
        int hours, bool weekdays, CancellationToken cancellationToken = default)
    {
        if (evidence.Revision != data.Revision)
            throw new InvalidOperationException("Current assignments and activity evidence have different saved revisions.");
        var categories = DeviceUsageClassifier.Classify(
            evidence with { FirstDate = evidence.LastDate.AddDays(-6) }, cancellationToken);
        var slots = data.VirtualDevices.ToDictionary(slot => LogicalDeviceId.Virtual(slot.Id));
        var names = new string[evidence.Devices.Count];
        var contributors = new ActivityContributor[names.Length];
        for (var index = 0; index < names.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var id = evidence.Devices[index].Identity;
            var row = id.Kind == "virtual" ? new ScanResultRow(slots[id], data, 0)
                : data.Devices.TryGetValue(id.Id, out var device)
                    ? new ScanResultRow(device, 0, data.Names.GetValueOrDefault(id.Id),
                        data.Classifications.GetValueOrDefault(id.Id)) : null;
            names[index] = row?.NameText ?? id.Id;
            var category = (row is null ? null : data.GetUsageCategoryOverride(id)) ?? categories[id].Category;
            contributors[index] = new(id, null, row?.Type ?? DeviceType.Unknown, category);
        }
        var grid = NetworkActivityPresentation.Create(evidence, contributors, hours, weekdays, new(), cancellationToken);
        var roster = string.Join(", ", names);
        var cells = grid.Cells.Select((cell, index) =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            var detail = weekdays ? $" Current equipment: {roster}."
                : $" Responded: {List(grid.Buckets.Days[index], true)}. Unknown/ineligible: {List(grid.Buckets.Days[index], false)}.";
            return cell with { Details = cell.Details + detail };
        }).ToArray();
        if (names.Length == 0) cells = [];
        return new(grid with { Cells = cells }, EquipmentActivity.Latest(evidence),
            names.Length == 0 ? "No equipment assigned." : $"Includes currently assigned equipment: {roster}.", categories);

        string List(ActivityDayBucket bucket, bool responding)
        {
            var included = names.Where((_, index) => responding ? bucket.Devices[index].Responded > 0
                : bucket.Scans.Count == 0 || bucket.Devices[index].Unknown > 0).ToArray();
            return included.Length == 0 ? "none" : string.Join(", ", included);
        }
    }

    public static string StateText(EquipmentScanStatus status) => status.State switch
    {
        EquipmentScanState.Online => "Equipment online",
        EquipmentScanState.NoResponse => "No equipment responded",
        EquipmentScanState.NoEquipment => "No equipment assigned",
        _ => "Unknown"
    };

    public static string Context(EquipmentScanStatus status, string network, DateTimeOffset now)
    {
        var count = status.State == EquipmentScanState.Unknown
            ? $"{status.Responded} of {status.Total} known responses; incomplete or unavailable evidence"
            : $"{status.Responded} of {status.Total} devices responded";
        var age = status.CompletedAt is not { } time ? "Scan age unavailable"
            : $"Scanned {Math.Max(0, (now - time).TotalMinutes).ToString("0.#", CultureInfo.CurrentCulture)} min ago";
        return $"{count} | {network} | {age}" + (status.IsOlder(now) ? " | Older scan" : "");
    }
}
