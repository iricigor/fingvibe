using System.Collections;
using FingVibe.Core.Storage;

namespace FingVibe.Core.Models;

/// <summary>
/// A linked device's completed scan observations: one entry per scan of its current members. A response from any
/// member counts as a response. Otherwise the scan is a nonresponse only when every member already seen on that
/// network (from its first response) recorded one; other scans are unknown and not listed. These are the same rules
/// activity evidence uses. Members' own histories are never rewritten.
/// </summary>
public sealed class LinkedScanHistory : IReadOnlyList<DeviceScanObservation>, IDeviceHistoryQuery
{
    private readonly IReadOnlyList<IReadOnlyList<DeviceScanObservation>> _members;
    private readonly Lazy<DeviceScanObservation[]> _all;

    public LinkedScanHistory(IEnumerable<IReadOnlyList<DeviceScanObservation>> members)
    {
        _members = members.ToArray();
        _all = new(() => _members.SelectMany(member => member)
            .Select(item => (item.NetworkId, item.Subnet)).Distinct()
            .SelectMany(scope => scope.NetworkId is null ? [] : Combine(scope.NetworkId, scope.Subnet).Select(row => row.Item))
            .ToArray());
    }

    public int Count => _all.Value.Length;
    public DeviceScanObservation this[int index] => _all.Value[index];
    public IEnumerator<DeviceScanObservation> GetEnumerator() => ((IEnumerable<DeviceScanObservation>)_all.Value).GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    public DeviceHistoryPage ReadPage(string networkId, string subnet, DeviceHistoryCursor? cursor = null,
        bool newer = false, int pageSize = DeviceHistoryQuery.DefaultPageSize)
    {
        if (pageSize is < 1 or > DeviceHistoryQuery.MaximumPageSize) throw new ArgumentOutOfRangeException(nameof(pageSize));
        if (SavedMembers() is { } saved) return SqliteScanHistory.ReadLinkedPage(saved, networkId, subnet, cursor, newer, pageSize);
        var combined = Combine(networkId, subnet);
        var matching = combined.Where(row => cursor is null || (newer
            ? row.Item.CompletedAt.UtcTicks > cursor.CompletedAt.UtcTicks
                || row.Item.CompletedAt.UtcTicks == cursor.CompletedAt.UtcTicks && row.Sequence < cursor.Sequence
            : row.Item.CompletedAt.UtcTicks < cursor.CompletedAt.UtcTicks
                || row.Item.CompletedAt.UtcTicks == cursor.CompletedAt.UtcTicks && row.Sequence > cursor.Sequence));
        var rows = (newer ? matching.Reverse().Take(pageSize).Reverse() : matching.Take(pageSize)).ToArray();
        return new(rows.Select(row => row.Item).ToArray(),
            rows.Length == 0 ? null : new(rows[0].Item.CompletedAt, rows[0].Sequence),
            rows.Length == 0 ? null : new(rows[^1].Item.CompletedAt, rows[^1].Sequence), combined.Count);
    }

    public bool HasPresence(string networkId, string subnet) => _members.Any(member => member is IDeviceHistoryQuery query
        ? query.HasPresence(networkId, subnet)
        : member.Any(item => item.NetworkId == networkId && item.Subnet == subnet && item.Present));

    public DeviceHistorySummary Summarize(IEnumerable<DeviceObservation> aggregates, string networkId, string subnet) =>
        DeviceHistorySummary.Create(Combine(networkId, subnet).Select(row => row.Item).ToArray(), aggregates, networkId, subnet);

    /// <summary>Every member stored in the same database, so one grouped query can page their combined scans.</summary>
    private IReadOnlyList<SqliteScanHistory>? SavedMembers()
    {
        var saved = new List<SqliteScanHistory>();
        foreach (var member in _members)
        {
            var query = member is AppendedScanHistory appended ? appended.QueryHistory : member;
            if (query is not SqliteScanHistory history || (saved.Count > 0 && history.DatabasePath != saved[0].DatabasePath))
                return null;
            saved.Add(history);
        }
        return saved.Count == 0 ? null : saved;
    }

    /// <summary>Combined scans, newest first; Sequence orders scans recorded at the same instant.</summary>
    private List<(DeviceScanObservation Item, int Sequence)> Combine(string networkId, string subnet)
    {
        var members = _members.Select(member => Scoped(member, networkId, subnet)
            .Where(item => item.VirtualDeviceId is null).ToArray()).ToArray();
        var firsts = members.Select(rows => rows.Where(item => item.Present)
            .Select(item => (long?)item.CompletedAt.UtcTicks).Min()).ToArray();
        var scans = members.SelectMany((rows, member) => rows.Select(item => (Member: member, Item: item)))
            .GroupBy(row => (row.Item.CompletedAt.UtcTicks, row.Item.ScanId))
            .Select(group =>
            {
                var ticks = group.Key.UtcTicks;
                var responded = group.Any(row => row.Item.Present);
                var eligible = firsts.Count(first => first <= ticks);
                var absent = group.Where(row => !row.Item.Present && firsts[row.Member] <= ticks)
                    .Select(row => row.Member).Distinct().Count();
                return (Group: group, Known: responded || (absent > 0 && absent == eligible), Responded: responded);
            })
            .Where(scan => scan.Known)
            .GroupBy(scan => scan.Group.Key.UtcTicks)
            .OrderByDescending(group => group.Key)
            .SelectMany(group => group.OrderBy(scan => scan.Group.Key.ScanId?.ToString("D"), StringComparer.Ordinal)
                .Select((scan, index) => (Item: new DeviceScanObservation(
                    scan.Group.Select(row => row.Item.CompletedAt).Min(), networkId, subnet, scan.Responded)
                {
                    ScanId = scan.Group.Key.ScanId
                }, Sequence: index)));
        return scans.ToList();
    }

    private static IEnumerable<DeviceScanObservation> Scoped(IReadOnlyList<DeviceScanObservation> history,
        string networkId, string subnet)
    {
        if (history is not IDeviceHistoryQuery)
        {
            foreach (var item in history.Where(item => item.NetworkId == networkId && item.Subnet == subnet)) yield return item;
            yield break;
        }
        DeviceHistoryCursor? cursor = null;
        while (true)
        {
            var page = DeviceHistoryQuery.ReadPage(history, networkId, subnet, cursor, pageSize: DeviceHistoryQuery.MaximumPageSize);
            foreach (var item in page.Items) yield return item;
            if (page.Items.Count < DeviceHistoryQuery.MaximumPageSize || page.Last is null) yield break;
            cursor = page.Last;
        }
    }
}
