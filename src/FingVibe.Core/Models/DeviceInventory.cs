using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Serialization;

namespace FingVibe.Core.Models;

public enum InventoryDeviceStatus
{
    Online,
    Offline,
    FingOnly,
    Unknown
}

public sealed record ImportedDeviceMetadata(
    string? Name = null,
    string? Hostname = null,
    string? Type = null,
    string? Brand = null,
    string? Family = null,
    string? Model = null,
    string? OperatingSystem = null,
    string? OperatingSystemVersion = null,
    string? Address = null);

public sealed record DeviceScanObservation(
    DateTimeOffset CompletedAt, string? NetworkId, string Subnet, bool Present)
{
    public Guid? ScanId { get; init; }
    public Guid? VirtualDeviceId { get; init; }
}

public sealed record DeviceDiscoveryBaseline(string NetworkId, string Subnet);

public sealed record DeviceObservation(
    string? NetworkId,
    string Subnet,
    string Address,
    string? Hostname,
    string Vendor,
    DeviceClassification Classification,
    IReadOnlyList<OpenPort> Ports,
    long? Latency,
    TimeSpan ProbeDuration,
    DateTimeOffset FirstSeen,
    DateTimeOffset LastSeen,
    DateTimeOffset LastChecked,
    bool Present,
    IReadOnlyList<UdpServiceObservation>? UdpObservations = null)
{
    public IReadOnlyList<ObservedDeviceValue> ReportedValues { get; init; } = [];
    // Advertisements received with this observation's latest response; absent in older saved data.
    public IReadOnlyList<ServiceAdvertisement> ServiceAdvertisements { get; init; } = [];

    public ScanResult ToScanResult(string mac) => new(
        IPAddress.Parse(Address), Present ? HostStatus.Alive : HostStatus.Unreachable,
        Latency, ProbeDuration, Hostname, PhysicalAddress.Parse(mac), Vendor, Ports, Classification, UdpObservations)
    {
        ServiceAdvertisements = ServiceAdvertisements
    };
}

public sealed record InventoryDevice(
    string Mac,
    ImportedDeviceMetadata Imported,
    IReadOnlyList<DeviceObservation> Observations)
{
    public IReadOnlyList<DeviceScanObservation> ScanHistory { get; init; } = [];
    public DeviceUsageCategory? UsageCategoryOverride { get; init; }

    [JsonIgnore]
    public DeviceObservation? LatestObservation => Observations.OrderByDescending(item =>
            item.LastChecked == CurrentCompletedAt && item.NetworkId == CurrentNetworkId && item.Subnet == CurrentSubnet)
        .ThenByDescending(item => item.LastChecked)
        .ThenByDescending(item => item.Present).ThenByDescending(item => item.LastSeen)
        .ThenBy(item => item.Address, StringComparer.Ordinal).FirstOrDefault();
    [JsonIgnore]
    public DateTimeOffset? CurrentCompletedAt { get; init; }
    [JsonIgnore]
    public string? CurrentNetworkId { get; init; }
    [JsonIgnore]
    public string? CurrentSubnet { get; init; }
    [JsonIgnore]
    public InventoryDeviceStatus Status => Observations.Count == 0
        ? InventoryDeviceStatus.FingOnly
        : LatestObservation!.Present ? InventoryDeviceStatus.Online : InventoryDeviceStatus.Offline;
}

public sealed record DeviceInventoryData(
    Guid Revision,
    IReadOnlyDictionary<string, InventoryDevice> Devices,
    IReadOnlyDictionary<string, string> Names,
    IReadOnlyDictionary<string, DeviceClassificationOverride> Classifications,
    PeopleRoomsData PeopleRooms)
{
    public IReadOnlyList<PrivateVirtualDevice> VirtualDevices { get; init; } = [];
    public IReadOnlyList<DeviceDiscoveryBaseline> DiscoveryBaselines { get; init; } = [];
    public IReadOnlyList<DeclinedDeviceMatch> DeclinedMatches { get; init; } = [];
    public IReadOnlyList<LinkedDevice> LinkedDevices { get; init; } = [];
    [JsonIgnore]
    public ScanSnapshot? LatestScan { get; init; }
    internal IReadOnlyList<ScanEvidenceWrite> PendingScanEvidence { get; init; } = [];

    public static DeviceInventoryData Empty { get; } = new(Guid.Empty,
        new Dictionary<string, InventoryDevice>(), new Dictionary<string, string>(),
        new Dictionary<string, DeviceClassificationOverride>(), new PeopleRoomsData());

    public LinkedDevice? FindLinkedDevice(string mac) => LinkedDevices.FirstOrDefault(device => device.HasMember(mac));

    /// <summary>The Person/Room shown for a MAC: the linked device's shared assignment, or the MAC's own.</summary>
    public DeviceAssignment? GetAssignment(string mac) => FindLinkedDevice(mac) is { } linked
        ? linked.Assignment : PeopleRooms.Assignments.GetValueOrDefault(mac);

    /// <summary>MAC records grouped by a virtual device; they can't be linked.</summary>
    public IReadOnlySet<string> VirtualGroupedMacs() =>
        VirtualDevices.SelectMany(slot => slot.History.Select(item => item.Mac)).ToHashSet(StringComparer.Ordinal);

    public DeviceInventoryData LinkDevices(string mac, string otherMac, LinkedDeviceChoices choices, DateTimeOffset linkedAt)
    {
        ArgumentNullException.ThrowIfNull(choices);
        var first = PeopleRoomsData.NormalizeMacAddress(mac);
        var second = PeopleRoomsData.NormalizeMacAddress(otherMac);
        if (first == second) throw new ArgumentException("A device cannot be linked to itself.", nameof(otherMac));
        if (!Devices.ContainsKey(first) || !Devices.ContainsKey(second))
            throw new ArgumentException("Both linked MAC addresses must be saved devices.");
        if (FindLinkedDevice(first) is not null || FindLinkedDevice(second) is not null)
            throw new InvalidOperationException("One of these MAC addresses is already linked to another device.");
        var grouped = VirtualGroupedMacs();
        if (grouped.Contains(first) || grouped.Contains(second))
            throw new InvalidOperationException("Virtual devices, and the MAC addresses they group, can't be linked.");
        var name = choices.Name?.Trim();
        if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("A linked device needs a name.", nameof(choices));
        var assignment = choices.Assignment is { PersonId: null, RoomId: null } ? null : choices.Assignment;
        var linked = new LinkedDevice(Guid.NewGuid(), [new(first, linkedAt), new(second, linkedAt)], name,
            choices.Identification, new(name, choices.Identification), assignment, choices.UsageCategoryOverride);
        if (!linked.IsValid(this)) throw new ArgumentException("The linked device values are invalid.", nameof(choices));
        return this with { LinkedDevices = [.. LinkedDevices, linked] };
    }

    public DeviceInventoryData UpdateLinkedDevice(Guid id, Func<LinkedDevice, LinkedDevice> update)
    {
        var current = LinkedDevices.FirstOrDefault(device => device.Id == id)
            ?? throw new ArgumentException("The linked device no longer exists.", nameof(id));
        var updated = update(current);
        if (updated.Id != id || !updated.Members.SequenceEqual(current.Members) || updated.Confirmed != current.Confirmed)
            throw new InvalidOperationException("Shared edits cannot change linked members or confirmed values.");
        if (!updated.IsValid(this)) throw new ArgumentException("The linked device values are invalid.");
        return this with { LinkedDevices = LinkedDevices.Select(device => device.Id == id ? updated : device).ToArray() };
    }

    /// <summary>Detaches one of two linked members, preserving both records and transferring shared values to the other.</summary>
    public DeviceInventoryData UnlinkDevice(string mac)
    {
        var detached = PeopleRoomsData.NormalizeMacAddress(mac);
        var linked = FindLinkedDevice(detached)
            ?? throw new ArgumentException("The MAC address is not linked to another device.", nameof(mac));
        if (linked.Members.Count != 2)
            throw new InvalidOperationException("Only a two-MAC linked device can be unlinked here.");

        var remaining = linked.Members.Single(member => member.Mac != detached).Mac;
        var devices = Devices.ToDictionary(pair => pair.Key, pair => pair.Value);
        devices[remaining] = devices[remaining] with { UsageCategoryOverride = linked.UsageCategoryOverride };

        var names = Names.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        names[remaining] = linked.Name;
        var classifications = Classifications.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        classifications[remaining] = linked.Identification;

        var assignments = PeopleRooms.Assignments.ToDictionary(pair => pair.Key, pair => pair.Value,
            StringComparer.OrdinalIgnoreCase);
        assignments.Remove(remaining);
        if (linked.Assignment is { } assignment && (assignment.PersonId is not null || assignment.RoomId is not null))
            assignments[remaining] = assignment;
        var peopleRooms = new PeopleRoomsData(PeopleRooms.People, PeopleRooms.Rooms, assignments);

        var declined = DeclinedDeviceMatch.Create(detached, remaining);
        var declinedMatches = DeclinedMatches.Any(item => item.Key == declined.Key)
            ? DeclinedMatches
            : [.. DeclinedMatches, declined];

        return this with
        {
            Devices = devices,
            Names = names,
            Classifications = classifications,
            PeopleRooms = peopleRooms,
            DeclinedMatches = declinedMatches,
            LinkedDevices = LinkedDevices.Where(device => device.Id != linked.Id).ToArray()
        };
    }

    /// <summary>Linked members share one override; each member's own saved override stays preserved for Unlink.</summary>
    public DeviceUsageCategory? GetUsageCategoryOverride(LogicalDeviceId identity) => identity.Kind switch
    {
        "linked" when LinkedDevices.FirstOrDefault(device => device.Id.ToString("D") == identity.Id) is { } linked
            => linked.UsageCategoryOverride,
        "mac" when FindLinkedDevice(identity.Id) is { } linked && Devices.ContainsKey(identity.Id) => linked.UsageCategoryOverride,
        "mac" when Devices.TryGetValue(identity.Id, out var device) => device.UsageCategoryOverride,
        "virtual" when VirtualDevices.FirstOrDefault(slot => slot.Id.ToString("D") == identity.Id) is { } slot
            => slot.UsageCategoryOverride,
        _ => throw new ArgumentException("The usage category requires an existing device identity.", nameof(identity))
    };

    public DeviceInventoryData SetUsageCategoryOverride(LogicalDeviceId identity, DeviceUsageCategory? category)
    {
        if (category is { } value && !Enum.IsDefined(value))
            throw new ArgumentOutOfRangeException(nameof(category));
        _ = GetUsageCategoryOverride(identity);
        if (identity.Kind == "linked"
            && LinkedDevices.FirstOrDefault(device => device.Id.ToString("D") == identity.Id) is { } linkedIdentity)
            return UpdateLinkedDevice(linkedIdentity.Id, device => device with { UsageCategoryOverride = category });
        if (identity.Kind == "mac" && FindLinkedDevice(identity.Id) is { } linked)
            return UpdateLinkedDevice(linked.Id, device => device with { UsageCategoryOverride = category });
        if (identity.Kind == "virtual")
            return this with
            {
                VirtualDevices = VirtualDevices.Select(slot => slot.Id.ToString("D") == identity.Id
                    ? slot with { UsageCategoryOverride = category } : slot).ToArray()
            };
        var devices = Devices.ToDictionary(pair => pair.Key, pair => pair.Value);
        devices[identity.Id] = devices[identity.Id] with { UsageCategoryOverride = category };
        return this with { Devices = devices };
    }

    public DeviceInventoryData DeclineMatch(string mac, string otherMac)
    {
        var declined = DeclinedDeviceMatch.Create(mac, otherMac);
        if (!Devices.ContainsKey(declined.FirstMac) || !Devices.ContainsKey(declined.SecondMac))
            throw new ArgumentException("Both declined MAC addresses must be saved devices.");
        return DeclinedMatches.Any(item => item.Key == declined.Key) ? this
            : this with { DeclinedMatches = [.. DeclinedMatches, declined] };
    }

    public DeviceInventoryData UpdateProbeResults(ScanResult result)
    {
        var mac = result.MacAddress?.ToString()
            ?? throw new ArgumentException("A MAC identity is required.", nameof(result));
        if (!Devices.TryGetValue(mac, out var device)
            || !device.Observations.Any(item => item.Present && item.LastChecked == device.CurrentCompletedAt
                && item.NetworkId == device.CurrentNetworkId && item.Subnet == device.CurrentSubnet
                && item.Address == result.AddressText))
            throw new InvalidOperationException("The selected address has no current inventory response.");
        DeviceObservation Update(DeviceObservation item) => item with
        {
            Ports = result.OpenPortItems, UdpObservations = result.UdpObservationItems
        };
        var devices = Devices.ToDictionary(pair => pair.Key, pair => pair.Value);
        devices[mac] = device with
        {
            Observations = device.Observations.Select(item =>
                item.Present && item.LastChecked == device.CurrentCompletedAt
                    && item.NetworkId == device.CurrentNetworkId && item.Subnet == device.CurrentSubnet && item.Address == result.AddressText
                    ? Update(item) : item).ToArray()
        };
        return this with
        {
            Devices = devices,
            VirtualDevices = VirtualDevices.Select(slot => slot with
            {
                History = slot.History.Select(item => item.Mac == mac && item.Observation.Address == result.AddressText
                    && item.Observation.Present && item.Observation.LastChecked == slot.CurrentCompletedAt
                        ? item with { Observation = Update(item.Observation) } : item).ToArray()
            }).ToArray()
        };
    }

    public DeviceInventoryData ObserveCompletedScan(
        string? networkId, ScanSnapshot snapshot, bool historical = false)
    {
        if (!historical && snapshot.ScanId != Guid.Empty && LatestScan is { State: ScanCheckpointState.Complete } saved
            && saved.ScanId == snapshot.ScanId)
            return this;
        var complete = snapshot.State == ScanCheckpointState.Complete;
        var devices = Devices.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var responses = snapshot.Results.Where(result => result.Status == HostStatus.Alive
            && result.MacAddress?.GetAddressBytes().Length == 6).ToArray();
        var seen = responses.Select(result => (result.MacAddress!.ToString(), result.AddressText)).ToHashSet();
        var presentMacs = responses.Select(result => result.MacAddress!.ToString()).ToHashSet();
        foreach (var result in responses)
        {
            var mac = result.MacAddress!.ToString();
            var device = devices.GetValueOrDefault(mac) ?? new InventoryDevice(mac, new(), []);
            var observations = device.Observations.ToList();
            var previous = observations.FirstOrDefault(item => item.NetworkId == networkId
                && item.Subnet == snapshot.Subnet && item.Address == result.AddressText);
            if (previous is not null) observations.Remove(previous);
            observations.Add(new DeviceObservation(networkId, snapshot.Subnet, result.AddressText,
                result.DeviceName, result.VendorName, result.DetectedClassification, result.OpenPortItems,
                result.RoundtripTimeMilliseconds, result.ProbeDuration,
                previous?.FirstSeen ?? snapshot.CompletedAt, snapshot.CompletedAt, snapshot.CompletedAt, true,
                result.UdpObservations)
            {
                ReportedValues = complete
                    ? DeviceReportedValues.Retain(previous?.ReportedValues ?? [], result.ReportedValues, snapshot.CompletedAt)
                    : previous?.ReportedValues ?? [],
                ServiceAdvertisements = result.ServiceAdvertisements
            });
            devices[mac] = device with { Observations = observations };
        }

        // A CIDR alone cannot identify a network, including when migrating an old snapshot.
        if (!historical && complete && networkId is not null)
        {
            foreach (var (mac, device) in devices.ToArray())
            {
                devices[mac] = device with
                {
                    Observations = device.Observations.Select(item =>
                        item.NetworkId == networkId && item.Subnet == snapshot.Subnet
                            && !seen.Contains((mac, item.Address))
                            ? item with { Present = false, LastChecked = snapshot.CompletedAt }
                            : item).ToArray()
                };
            }
        }
        foreach (var (mac, device) in devices.ToArray())
        {
            var present = presentMacs.Contains(mac);
            var relevant = present || networkId is not null && device.Observations.Any(item =>
                item.NetworkId == networkId && item.Subnet == snapshot.Subnet);
            devices[mac] = device with
            {
                ScanHistory = !historical && complete && relevant
                    ? new AppendedScanHistory(device.ScanHistory, new(snapshot.CompletedAt, networkId, snapshot.Subnet, present)
                        { ScanId = snapshot.ScanId == Guid.Empty ? null : snapshot.ScanId })
                    : device.ScanHistory,
                CurrentCompletedAt = historical ? null : snapshot.CompletedAt,
                CurrentNetworkId = historical ? null : networkId,
                CurrentSubnet = historical ? null : snapshot.Subnet
            };
        }
        var observed = this with
        {
            Devices = devices,
            LatestScan = historical ? LatestScan : snapshot with { NetworkId = networkId },
            PendingScanEvidence = !historical && snapshot.ScanId != Guid.Empty
                ? [.. PendingScanEvidence.Where(item => item.ScanId != snapshot.ScanId),
                    ScanEvidenceWrite.From(snapshot with { NetworkId = networkId })]
                : PendingScanEvidence
        };
        var virtualDevices = PrivateVirtualDeviceAllocator.Observe(observed, networkId, snapshot, historical);
        if (!historical && complete && snapshot.ScanId != Guid.Empty)
        {
            foreach (var slot in virtualDevices.Where(slot => slot.NetworkId == networkId && slot.Subnet == snapshot.Subnet
                         && slot.Present && slot.LastChecked == snapshot.CompletedAt))
            {
                var device = devices[slot.LastActiveMac];
                if (device.ScanHistory is AppendedScanHistory appended && appended.Added.ScanId == snapshot.ScanId)
                    devices[device.Mac] = device with
                    {
                        ScanHistory = new AppendedScanHistory(appended.Previous,
                            appended.Added with { VirtualDeviceId = slot.Id })
                    };
            }
        }
        return observed with
        {
            VirtualDevices = virtualDevices,
            LinkedDevices = !historical && complete && networkId is not null
                ? LinkedDeviceRepresentatives.Observe(observed, networkId, snapshot.Subnet, snapshot.CompletedAt)
                : observed.LinkedDevices,
            DiscoveryBaselines = !historical && complete && networkId is not null
                ? DiscoveryBaselines.Append(new(networkId, snapshot.Subnet)).Distinct().ToArray()
                : DiscoveryBaselines
        };
    }
}
