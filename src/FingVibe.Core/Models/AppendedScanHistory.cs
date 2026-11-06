using System.Collections;
using System.Collections.Immutable;

namespace FingVibe.Core.Models;

internal sealed class AppendedScanHistory : IReadOnlyList<DeviceScanObservation>, IDeviceHistoryQuery
{
    private readonly ImmutableList<DeviceScanObservation> _items;
    private readonly IReadOnlyList<DeviceScanObservation> _base;
    internal IReadOnlyList<DeviceScanObservation> Previous { get; }
    internal DeviceScanObservation Added { get; }
    internal IReadOnlyList<DeviceScanObservation> Committed => _base.Count == 0 ? _items : this;

    internal AppendedScanHistory(IReadOnlyList<DeviceScanObservation> previous, DeviceScanObservation added)
    {
        Previous = previous;
        Added = added;
        _base = previous is AppendedScanHistory history ? history._base
            : previous is IDeviceHistoryQuery ? previous : [];
        _items = (previous is AppendedScanHistory appended ? appended._items
            : previous is IDeviceHistoryQuery ? ImmutableList<DeviceScanObservation>.Empty
            : previous.ToImmutableList()).Add(added);
    }

    public int Count => checked(_base.Count + _items.Count);
    public DeviceScanObservation this[int index] => index < _base.Count ? _base[index] : _items[index - _base.Count];
    public IEnumerator<DeviceScanObservation> GetEnumerator() => _base.Concat(_items).GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    private IReadOnlyList<DeviceScanObservation> QueryHistory =>
        _base is Storage.SqliteScanHistory saved ? saved.WithPending(_items) : this.ToArray();

    public DeviceHistorySummary Summarize(IEnumerable<DeviceObservation> aggregates, string networkId, string subnet) =>
        DeviceHistorySummary.Create(QueryHistory, aggregates, networkId, subnet);

    public bool HasPresence(string networkId, string subnet) =>
        _items.Any(item => item.NetworkId == networkId && item.Subnet == subnet && item.Present)
        || (_base is IDeviceHistoryQuery query ? query.HasPresence(networkId, subnet)
            : _base.Any(item => item.NetworkId == networkId && item.Subnet == subnet && item.Present));

    public DeviceHistoryPage ReadPage(string networkId, string subnet, DeviceHistoryCursor? cursor = null,
        bool newer = false, int pageSize = DeviceHistoryQuery.DefaultPageSize) =>
        DeviceHistoryQuery.ReadPage(QueryHistory, networkId, subnet, cursor, newer, pageSize);
}
