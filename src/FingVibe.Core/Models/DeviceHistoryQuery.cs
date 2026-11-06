namespace FingVibe.Core.Models;

public sealed record DeviceHistoryCursor(DateTimeOffset CompletedAt, int Sequence);

public sealed record DeviceHistoryPage(
    IReadOnlyList<DeviceScanObservation> Items, DeviceHistoryCursor? First,
    DeviceHistoryCursor? Last, int TotalCount);

public interface IDeviceHistoryQuery
{
    DeviceHistorySummary Summarize(IEnumerable<DeviceObservation> aggregates, string networkId, string subnet);
    bool HasPresence(string networkId, string subnet);
    DeviceHistoryPage ReadPage(string networkId, string subnet, DeviceHistoryCursor? cursor = null,
        bool newer = false, int pageSize = DeviceHistoryQuery.DefaultPageSize);
}

public static class DeviceHistoryQuery
{
    public const int DefaultPageSize = 100;
    public const int MaximumPageSize = 200;

    public static DeviceHistoryPage ReadPage(IReadOnlyList<DeviceScanObservation> history,
        string? networkId, string? subnet, DeviceHistoryCursor? cursor = null,
        bool newer = false, int pageSize = DefaultPageSize)
    {
        if (pageSize is < 1 or > MaximumPageSize) throw new ArgumentOutOfRangeException(nameof(pageSize));
        if (string.IsNullOrWhiteSpace(networkId) || string.IsNullOrWhiteSpace(subnet))
            return new([], null, null, 0);
        if (history is IDeviceHistoryQuery query)
            return query.ReadPage(networkId, subnet, cursor, newer, pageSize);
        var scoped = history.Select((item, sequence) => (Item: item, Sequence: sequence))
            .Where(row => row.Item.NetworkId == networkId && row.Item.Subnet == subnet)
            .OrderByDescending(row => row.Item.CompletedAt).ThenBy(row => row.Sequence).ToArray();
        var matching = scoped.Where(row => cursor is null || (newer
            ? row.Item.CompletedAt > cursor.CompletedAt || row.Item.CompletedAt == cursor.CompletedAt && row.Sequence < cursor.Sequence
            : row.Item.CompletedAt < cursor.CompletedAt || row.Item.CompletedAt == cursor.CompletedAt && row.Sequence > cursor.Sequence));
        var rows = (newer ? matching.Reverse().Take(pageSize).Reverse() : matching.Take(pageSize)).ToArray();
        return new(rows.Select(row => row.Item).ToArray(),
            rows.Length == 0 ? null : new(rows[0].Item.CompletedAt, rows[0].Sequence),
            rows.Length == 0 ? null : new(rows[^1].Item.CompletedAt, rows[^1].Sequence), scoped.Length);
    }
}
