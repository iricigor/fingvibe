namespace FingVibe.Core.Models;

public sealed record DeviceHistorySummary(
    IReadOnlyList<DeviceScanObservation> History,
    DateTimeOffset? FirstSeen,
    DateTimeOffset? LastSeen,
    DateTimeOffset? Since,
    bool FirstSeenIsAggregate,
    bool LastSeenIsAggregate)
{
    public DeviceScanObservation? Latest => History.FirstOrDefault();

    public static DeviceHistorySummary Create(
        IEnumerable<DeviceScanObservation> history,
        IEnumerable<DeviceObservation> aggregates,
        string? networkId,
        string? subnet)
    {
        if (string.IsNullOrWhiteSpace(networkId) || string.IsNullOrWhiteSpace(subnet))
            return new([], null, null, null, false, false);

        var scoped = history.Where(item => item.NetworkId == networkId && item.Subnet == subnet)
            .OrderByDescending(item => item.CompletedAt).ToArray();
        var presence = scoped.Where(item => item.Present).Select(item => (DateTimeOffset?)item.CompletedAt).ToArray();
        var recordedFirst = presence.Min();
        var recordedLast = presence.Max();
        var matching = aggregates.Where(item => item.NetworkId == networkId && item.Subnet == subnet).ToArray();
        var first = matching.Select(item => (DateTimeOffset?)item.FirstSeen).Append(recordedFirst).Min();
        var last = matching.Select(item => (DateTimeOffset?)item.LastSeen).Append(recordedLast).Max();
        // Aggregate timestamps cannot establish the intervening scan-state sequence.
        var since = scoped.Length == 0 ? (DateTimeOffset?)null
            : scoped.TakeWhile(item => item.Present == scoped[0].Present).Last().CompletedAt;
        return new(scoped, first, last, since,
            first is not null && first != recordedFirst, last is not null && last != recordedLast);
    }
}
