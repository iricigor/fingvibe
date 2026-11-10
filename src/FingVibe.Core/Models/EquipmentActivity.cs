namespace FingVibe.Core.Models;

public sealed record EquipmentSelection(
    IReadOnlyList<LogicalDeviceId> QueryDevices, IReadOnlyList<LogicalDeviceId> UnavailableDevices);

public enum EquipmentScanState { Unknown, Online, NoResponse, NoEquipment }

public sealed record EquipmentScanStatus(
    EquipmentScanState State, int Responded, int Total, DateTimeOffset? CompletedAt)
{
    public bool IsOlder(DateTimeOffset now) => CompletedAt is { } time && now - time > TimeSpan.FromHours(2);
}

public static class EquipmentActivity
{
    public static EquipmentSelection Select(DeviceInventoryData data, Guid personId, string networkId, string subnet)
    {
        if (!data.PeopleRooms.People.Any(person => person.Id == personId))
            return new([], []);
        var assigned = data.PeopleRooms.Assignments.Where(pair => pair.Value.PersonId == personId)
            .Select(pair => LogicalDeviceId.Mac(pair.Key))
            .Concat(data.VirtualDevices.Where(slot => slot.Assignment?.PersonId == personId)
                .Select(slot => LogicalDeviceId.Virtual(slot.Id))).Distinct().ToArray();
        var slots = data.VirtualDevices.Where(slot => slot.NetworkId == networkId && slot.Subnet == subnet)
            .Select(slot => LogicalDeviceId.Virtual(slot.Id)).ToHashSet();
        bool Queryable(LogicalDeviceId id) => id.Kind == "mac" ? data.Devices.ContainsKey(id.Id) : slots.Contains(id);
        return new(assigned.Where(Queryable).ToArray(), assigned.Where(id => !Queryable(id)).ToArray());
    }

    // The store resolves existing MAC/virtual associations. Out-of-network assignments stay
    // in the roster with unknown evidence instead of disappearing or becoming nonresponses.
    public static AnalyticsEvidence IncludeUnavailable(AnalyticsEvidence evidence, EquipmentSelection selection)
    {
        if (selection.UnavailableDevices.Count == 0) return evidence;
        var missing = selection.UnavailableDevices.Where(id => !evidence.Devices.Any(device => device.Identity == id))
            .Select(id => new AnalyticsDevice(id, null, false)).ToArray();
        AnalyticsScanEvidence Extend(AnalyticsScanEvidence scan) => scan with
        {
            Responses = scan.Responses.Concat(Enumerable.Repeat(AnalyticsResponse.Unknown, missing.Length)).ToArray()
        };
        return evidence with
        {
            Devices = evidence.Devices.Concat(missing).ToArray(),
            Scans = evidence.Scans.Select(Extend).ToArray(),
            LatestScan = evidence.LatestScan is { } latest ? Extend(latest) : null
        };
    }

    public static EquipmentScanStatus Latest(AnalyticsEvidence evidence)
    {
        var scan = evidence.LatestScan;
        var total = evidence.Devices.Count;
        if (total == 0) return new(EquipmentScanState.NoEquipment, 0, 0, scan?.CompletedAt);
        if (scan is null) return new(EquipmentScanState.Unknown, 0, total, null);
        if (scan.Responses.Count != total)
            throw new ArgumentException("Latest scan responses must align with equipment identities.", nameof(evidence));
        var responded = 0;
        var complete = scan.HasCompletedLedger && scan.UnidentifiedResponses == 0 && scan.CompletedAt <= evidence.QueryTime;
        for (var index = 0; index < total; index++)
        {
            var device = evidence.Devices[index];
            var eligible = !device.AmbiguousMapping && device.FirstReliableSighting is { } first && first <= scan.CompletedAt;
            if (eligible && scan.Responses[index] == AnalyticsResponse.Responded) responded++;
            if (!eligible || scan.Responses[index] == AnalyticsResponse.Unknown) complete = false;
        }
        return new(!complete ? EquipmentScanState.Unknown
            : responded > 0 ? EquipmentScanState.Online : EquipmentScanState.NoResponse, responded, total, scan.CompletedAt);
    }
}
