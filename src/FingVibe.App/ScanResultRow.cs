using System.ComponentModel;
using System.Globalization;
using System.Net.NetworkInformation;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.App;

public sealed record DeviceMacExpansionLine(
    string Label,
    string Address,
    string Mac,
    string Vendor,
    string Status,
    DateTimeOffset LastSeenAt,
    string AccessibleText)
{
    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public string LastSeen => LastSeenAt == default ? "Never seen locally" : DeviceDetailsPresentation.FriendlyTimestamp(
        LastSeenAt, DateTimeOffset.UtcNow);
    /// <summary>Every address this MAC was seen at, so search can find a linked member by any of its IPs.</summary>
    public IReadOnlyList<string> SearchAddresses { get; init; } = [];
    public string AddressPrefix => string.Join(".", Address.Split('.').Take(3)) is { Length: > 0 } prefix
        ? prefix + "." : string.Empty;
    public string AddressHost => Address.Split('.').LastOrDefault() ?? Address;
    public bool Matches(string search) =>
        !string.IsNullOrWhiteSpace(search)
        && (Address.Contains(search, StringComparison.OrdinalIgnoreCase)
            || SearchAddresses.Any(address => address.Contains(search, StringComparison.OrdinalIgnoreCase))
            || Mac.Contains(search, StringComparison.OrdinalIgnoreCase)
            || Mac.Replace("-", string.Empty).Contains(search.Replace("-", string.Empty), StringComparison.OrdinalIgnoreCase)
            || Vendor.Contains(search, StringComparison.OrdinalIgnoreCase));
}

public sealed class ScanResultRow : INotifyPropertyChanged
{
    private string? _customName;
    private DeviceClassificationOverride? _classificationOverride;
    private Guid? _personId;
    private string? _personShortName;
    private string? _personName;
    private Guid? _roomId;
    private string? _roomShortName;
    private string? _roomName;
    private bool _isAlternateRow;
    private bool _isSelected;
    private bool _isPointerOver;
    private InventoryDevice? _inventoryDevice;
    private bool _historical;
    private bool _showLatency = true;
    private DeviceInventoryData? _sourceData;
    private readonly Dictionary<string, ScanResult> _connectionOverrides = new();
    private bool _macsExpanded;
    private string _macSearch = string.Empty;
    private IReadOnlyList<DeviceMacExpansionLine> _earlierMacLines = [];
    private IReadOnlyList<InventoryDevice> _linkedMembers = [];
    private int _prefixLength;
    public PrivateVirtualDevice? VirtualDevice { get; private set; }
    public string IdentityKey => VirtualDevice?.Id.ToString("D") ?? LinkedDevice?.Id.ToString("D")
        ?? MacAddress?.ToString() ?? AddressText;
    public string? CustomName => _customName;
    public LogicalDeviceId? UsageIdentity => LinkedDevice is { } linked ? LogicalDeviceId.Linked(linked.Id)
        : VirtualDevice is { } slot ? LogicalDeviceId.Virtual(slot.Id)
        : MacAddress?.GetAddressBytes().Length == 6 ? LogicalDeviceId.Mac(MacAddress.ToString()) : null;
    public DeviceUsageCategory? UsageCategoryOverride { get; private set; }
    public DeviceUsageInference? UsageInference { get; private set; }
    public string UsageStatus { get; private set; } = "Usage evidence has not been loaded.";
    public bool UsageLoading { get; private set; }
    public DeviceUsageCategory? EffectiveUsageCategory => UsageCategoryOverride ?? UsageInference?.Category;
    public string UsageCategoryText => EffectiveUsageCategory?.ToString() ?? "Unavailable";
    public string UsageCategorySource => UsageCategoryOverride is not null ? "Manual override"
        : UsageInference is null ? UsageStatus
        : UsageInference.Total.Eligible == 0 ? "Auto - no eligible scans"
        : UsageInference.LimitedEvidence ? "Auto - limited evidence" : "Automatic";
    public string UsageCategoryDescription => UsageCategoryPresentation.Description(UsageCategoryOverride, UsageInference, UsageStatus);
    public string UsageCategoryCellText => EffectiveUsageCategory is null && UsageLoading ? "Loading" : UsageCategoryText;
    public double UsageCategoryOpacity => EffectiveUsageCategory == DeviceUsageCategory.Unclassified ? 0.65 : 1;
    public string UsageCategoryCellName => $"Usage category: {UsageCategoryCellText}. {UsageCategorySource}";
    public bool HasClassifiedUsageCategory => EffectiveUsageCategory is
        DeviceUsageCategory.Permanent or DeviceUsageCategory.Personal or DeviceUsageCategory.Guest;
    public bool IsPermanentUsageCategory => EffectiveUsageCategory == DeviceUsageCategory.Permanent;
    public bool IsPersonalUsageCategory => EffectiveUsageCategory == DeviceUsageCategory.Personal;
    public bool IsGuestUsageCategory => EffectiveUsageCategory == DeviceUsageCategory.Guest;
    public bool HasUsageCategoryIndicator => UsageCategoryOverride is not null
        || (HasClassifiedUsageCategory && UsageInference?.LimitedEvidence == true);
    public string UsageCategoryIndicatorGlyph => UsageCategoryOverride is not null ? "\uE718" : "\uE946";

    public void SetUsageCategory(DeviceUsageCategory? manual, DeviceUsageInference? inference, string status, bool loading = false)
    {
        UsageCategoryOverride = manual;
        UsageInference = inference;
        UsageStatus = status;
        UsageLoading = loading;
        foreach (var property in new[] { nameof(UsageCategoryOverride), nameof(UsageInference), nameof(UsageStatus),
                     nameof(EffectiveUsageCategory), nameof(UsageCategoryText), nameof(UsageCategorySource), nameof(UsageCategoryDescription),
                     nameof(UsageLoading), nameof(UsageCategoryCellText), nameof(UsageCategoryOpacity), nameof(UsageCategoryCellName),
                     nameof(HasClassifiedUsageCategory), nameof(IsPermanentUsageCategory), nameof(IsPersonalUsageCategory),
                     nameof(IsGuestUsageCategory), nameof(HasUsageCategoryIndicator), nameof(UsageCategoryIndicatorGlyph) })
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }
    private LanNetwork? _selectedNetwork;
    private bool EmphasizeAddress => _selectedNetwork is { PrefixLength: >= 0 and <= 32 } network
        && AddressText.Split('.').Length == 4
        && System.Net.IPAddress.TryParse(AddressText, out var address)
        && address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
        && network.NetworkAddress.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
        && SubnetCalculator.GetNetworkAddress(address, network.PrefixLength)
            .Equals(SubnetCalculator.GetNetworkAddress(network.NetworkAddress, network.PrefixLength));
    public double AddressHostFontSize => EmphasizeAddress ? 13.2 : 12;
    public string DisplayAddressPrefix => !EmphasizeAddress ? AddressPrefix
        : _selectedNetwork!.PrefixLength < 8 ? string.Empty
        : string.Join(".", AddressText.Split('.').Take(Math.Min(_selectedNetwork.PrefixLength / 8, 3))) + ".";
    public string DisplayAddressHost => EmphasizeAddress
        ? AddressText[DisplayAddressPrefix.Length..] : AddressHost;

    public void SetSelectedNetwork(LanNetwork? network)
    {
        if (_selectedNetwork == network) return;
        _selectedNetwork = network;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AddressHostFontSize)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayAddressPrefix)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayAddressHost)));
    }

    public bool IsVirtualIdentity => VirtualDevice is not null;
    public IReadOnlyList<DeviceScanObservation> ScanHistory => _linkedMembers.Count > 0
        ? new LinkedScanHistory(_linkedMembers.Select(member => member.ScanHistory))
        : VirtualDevice?.ScanHistory ?? _inventoryDevice?.ScanHistory ?? [];
    public DeviceHistorySummary GetHistorySummary(string? networkId, string? subnet)
    {
        if (_linkedMembers.Count == 0)
            return DeviceHistorySummary.Create(ScanHistory,
                VirtualDevice is { } device ? device.History.Select(item => item.Observation)
                    : _inventoryDevice?.Observations ?? [], networkId, subnet);
        // A linked device was last seen when any member was; members never seen on this network add nothing.
        var summaries = _linkedMembers.Select(member =>
            DeviceHistorySummary.Create(member.ScanHistory, member.Observations, networkId, subnet)).ToArray();
        var latest = summaries.Where(item => item.LastSeen is not null).MaxBy(item => item.LastSeen)
            ?? summaries[_linkedMembers.ToList().FindIndex(member => member.Mac == _inventoryDevice?.Mac) is var index and >= 0 ? index : 0];
        var first = summaries.Where(item => item.FirstSeen is not null).MinBy(item => item.FirstSeen);
        return first is null ? latest : latest with { FirstSeen = first.FirstSeen, FirstSeenIsAggregate = first.FirstSeenIsAggregate };
    }
    public string VirtualIdentityDescription => IsVirtualIdentity
        ? "Virtual device - inferred identity across changing MAC addresses." : string.Empty;
    public DateTimeOffset? CurrentScanCompletedAt => VirtualDevice?.CurrentCompletedAt ?? _inventoryDevice?.CurrentCompletedAt;
    public DeviceLastSeen LastSeen { get; private set; } = DeviceLastSeen.NotCalculated;
    public string LastSeenText => LastSeen.Text;
    public string LastSeenDescription => LastSeen.Description;
    public double LastSeenOpacity => LastSeen.IsMuted ? 0.65 : 1;

    public void SetLastSeen(DeviceLastSeen lastSeen)
    {
        if (LastSeen == lastSeen) return;
        var previous = LastSeen;
        LastSeen = lastSeen;
        // Age refreshes change only the text; leaving other bindings untouched keeps open previews and accessibility stable.
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LastSeen)));
        if (previous.Text != lastSeen.Text)
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LastSeenText)));
        if (previous.Description != lastSeen.Description)
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LastSeenDescription)));
        if (previous.IsMuted != lastSeen.IsMuted)
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LastSeenOpacity)));
    }

    public void RefreshLastSeenAge(DateTimeOffset now)
    {
        SetLastSeen(LastSeen.At(now));
        if (_earlierMacLines.Count > 0) NotifyMacExpansionChanged();
    }

    public ScanResultRow(ScanResult? result, int prefixLength, string? customName = null,
        DeviceClassificationOverride? classificationOverride = null, bool historical = false)
    {
        if (prefixLength is < 0 or > 32)
        {
            throw new ArgumentOutOfRangeException(nameof(prefixLength));
        }

        Result = result;
        _prefixLength = prefixLength;
        _historical = historical;
        _customName = string.IsNullOrWhiteSpace(customName) ? null : customName.Trim();
        _classificationOverride = classificationOverride;
        var octets = (result?.AddressText ?? "-").Split('.');
        // Only dim complete network octets; a partially masked octet also identifies hosts.
        var prefixOctets = octets.Length == 4 ? Math.Min(prefixLength / 8, 3) : 0;
        AddressPrefix = prefixOctets == 0
            ? string.Empty
            : string.Join(".", octets.Take(prefixOctets)) + ".";
        AddressHost = string.Join(".", octets.Skip(prefixOctets));
        var mac = result?.MacAddressText ?? "-";
        MacOui = result?.MacAddress?.GetAddressBytes().Length == 6 ? mac[..8] : mac;
        MacNic = result?.MacAddress?.GetAddressBytes().Length == 6 ? mac[8..] : string.Empty;
    }

    public ScanResultRow(InventoryDevice device, int prefixLength, string? customName = null,
        DeviceClassificationOverride? classificationOverride = null, bool historical = true, bool showLatency = true)
        : this(device.LatestObservation?.ToScanResult(device.Mac), prefixLength, customName, classificationOverride, historical)
    {
        _inventoryDevice = device;
        UsageCategoryOverride = device.UsageCategoryOverride;
        _showLatency = showLatency;
        var octets = AddressText.Split('.');
        var count = octets.Length == 4 ? Math.Min(prefixLength / 8, 3) : 0;
        AddressPrefix = count == 0 ? string.Empty : string.Join(".", octets.Take(count)) + ".";
        AddressHost = string.Join(".", octets.Skip(count));
        var mac = MacAddressText;
        MacOui = mac[..8];
        MacNic = mac[8..];
    }

    public ScanResult? Result { get; private set; }
    public IReadOnlyList<ObservedDeviceValue> ReportedValues =>
        TargetDevice is { LatestObservation: { } scope } device
            ? device.Observations.FirstOrDefault(item => item.Address == AddressText
                && item.NetworkId == scope.NetworkId && item.Subnet == scope.Subnet)?.ReportedValues ?? []
            : [];
    public ScanResultRow(PrivateVirtualDevice device, DeviceInventoryData data, int prefixLength)
        : this(new InventoryDevice(device.LastActiveMac, data.Devices[device.LastActiveMac].Imported,
            device.History.Where(item => item.Mac == device.LastActiveMac).Select(item => item.Observation).ToArray())
        {
            CurrentCompletedAt = device.CurrentCompletedAt,
            CurrentNetworkId = device.NetworkId,
            CurrentSubnet = device.Subnet
        }, prefixLength, device.Name, device.Classification,
            historical: device.LastChecked != device.CurrentCompletedAt)
    {
        VirtualDevice = device;
        UsageCategoryOverride = device.UsageCategoryOverride;
        _sourceData = data;
        Result = device.LatestConnection.Observation.ToScanResult(device.LastActiveMac);
        RefreshMacExpansionLines();
    }

    public bool HasEarlierMacAddresses => _earlierMacLines.Count > 0;
    public int EarlierMacAddressCount => _earlierMacLines.Count;
    public bool SearchExpandsMacAddresses =>
        !string.IsNullOrWhiteSpace(_macSearch) && _earlierMacLines.Any(line => line.Matches(_macSearch));
    public bool AreMacAddressesExpanded => _macsExpanded || SearchExpandsMacAddresses;
    public bool CanToggleMacAddresses => HasEarlierMacAddresses && !SearchExpandsMacAddresses;
    public string MacExpansionGlyph => AreMacAddressesExpanded ? "\uE70D" : "\uE76C";
    public string MacExpansionState =>
        HasEarlierMacAddresses
            ? $"{EarlierMacAddressCount} more MAC {(EarlierMacAddressCount == 1 ? "address" : "addresses")}, "
                + (AreMacAddressesExpanded ? "expanded" : "collapsed")
                + (SearchExpandsMacAddresses ? " by search" : string.Empty)
            : "No earlier MAC addresses";
    public string MacExpansionName => AreMacAddressesExpanded
        ? SearchExpandsMacAddresses && !_macsExpanded
            ? $"{MacExpansionState}"
            : $"Hide {EarlierMacAddressCount} more MAC {(EarlierMacAddressCount == 1 ? "address" : "addresses")}"
        : $"Show {EarlierMacAddressCount} more MAC {(EarlierMacAddressCount == 1 ? "address" : "addresses")}";
    public IReadOnlyList<DeviceMacExpansionLine> VisibleMacExpansionLines =>
        !AreMacAddressesExpanded
            ? []
            : _earlierMacLines
                .Where((line, index) => index < 3 || line.Matches(_macSearch))
                .ToArray();
    public string MoreMacAddressesText
    {
        get
        {
            if (!AreMacAddressesExpanded) return string.Empty;
            var remaining = EarlierMacAddressCount - VisibleMacExpansionLines.Count;
            return remaining <= 0 ? string.Empty
                : $"+{remaining} more MAC {(remaining == 1 ? "address" : "addresses")} · "
                    + (IsLinked ? "full list in Device Details" : "full list in Device Details › History");
        }
    }

    public void SetMacExpansionState(bool expanded, string? search = null)
    {
        _macsExpanded = expanded;
        _macSearch = search?.Trim() ?? string.Empty;
        NotifyMacExpansionChanged();
    }

    public void SetMacExpansionSearch(string? search)
    {
        var next = search?.Trim() ?? string.Empty;
        if (_macSearch == next) return;
        _macSearch = next;
        NotifyMacExpansionChanged();
    }

    public IReadOnlyList<ScanResult> CurrentConnections => !IsCurrentScanResponse ? []
        : _inventoryDevice is { } device
            ? device.Observations.Where(item => item.Present && item.LastChecked == device.CurrentCompletedAt
                && item.NetworkId == device.CurrentNetworkId && item.Subnet == device.CurrentSubnet)
                .OrderBy(item => item.Address, StringComparer.Ordinal)
                .Select(item => _connectionOverrides.GetValueOrDefault(ConnectionKey(device.Mac, item.Address))
                    ?? item.ToScanResult(device.Mac)).ToArray()
            : Result is { } result ? [result] : [];

    /// <summary>
    /// The real addresses Device Details can inspect and probe: for a linked device every member MAC/IP responding in
    /// the current scan (the Devices representative first), otherwise this record's current addresses.
    /// </summary>
    public IReadOnlyList<ScanResult> CurrentTargets => !IsLinkedDeviceRow ? CurrentConnections
        : !IsCurrentScanResponse || _inventoryDevice is not { } shown ? []
        : _linkedMembers.SelectMany(member => member.Observations.Where(item => item.Present
                && item.LastChecked == shown.CurrentCompletedAt
                && item.NetworkId == shown.CurrentNetworkId && item.Subnet == shown.CurrentSubnet)
                .Select(item => (member.Mac, Observation: item)))
            .OrderBy(item => item.Mac != shown.Mac).ThenBy(item => item.Mac, StringComparer.Ordinal)
            .ThenBy(item => item.Observation.Address, StringComparer.Ordinal)
            .Select(item => _connectionOverrides.GetValueOrDefault(ConnectionKey(item.Mac, item.Observation.Address))
                ?? item.Observation.ToScanResult(item.Mac)).ToArray();

    /// <summary>Picker text for a target: "MAC · IP" for a linked device, otherwise the IP address.</summary>
    public string TargetChoice(ScanResult target) => IsLinkedDeviceRow && target.MacAddress is { } mac
        ? $"{FormatMac(mac.ToString())} · {target.AddressText}" : target.AddressText;
    public IReadOnlyList<string> CurrentTargetChoices => CurrentTargets.Select(TargetChoice).ToArray();
    public string SelectedTargetChoice => Result is { } result ? TargetChoice(result) : AddressText;

    /// <summary>The network of the address being inspected; a probe needs the matching Windows network profile.</summary>
    public string? TargetNetworkId => TargetDevice?.CurrentNetworkId;

    // The member whose address Device Details is inspecting; never changes which member Devices shows.
    private InventoryDevice? TargetDevice => IsLinkedDeviceRow && Result?.MacAddress?.ToString() is { } mac
        ? _linkedMembers.FirstOrDefault(member => member.Mac == mac) ?? _inventoryDevice : _inventoryDevice;

    private static string ConnectionKey(string? mac, string address) => $"{mac}|{address}";

    public string ConnectionHistoryText => _linkedMembers.Count > 0 ? LinkedHistoryText()
        : VirtualDevice is not { } device ? string.Empty
        : string.Join("\n\n", device.History.OrderByDescending(item => item.Observation.LastSeen)
            .ThenBy(item => item.Mac, StringComparer.Ordinal).Select(item =>
            {
                var observation = item.Observation;
                var raw = _sourceData?.Devices.GetValueOrDefault(item.Mac);
                var savedName = _sourceData?.Names.GetValueOrDefault(item.Mac);
                var assignment = _sourceData?.PeopleRooms.Assignments.GetValueOrDefault(item.Mac);
                var classification = _sourceData?.Classifications.GetValueOrDefault(item.Mac);
                return $"{FormatMac(item.Mac)} · {observation.Address}\n"
                    + $"{(IsCurrentScanResponse && item.Mac == device.LastActiveMac && observation.Present && observation.LastChecked == device.CurrentCompletedAt ? "Current response" : "Previous connection")}"
                    + $" · first seen {observation.FirstSeen:g} · last seen {observation.LastSeen:g}\n"
                    + $"Network {observation.NetworkId} · {observation.Subnet}"
                    + (item.Inferred ? "\nInferred association by private prefix and available virtual-device number." : string.Empty)
                    + $"\nHostname: {observation.Hostname ?? "-"} · Vendor: {observation.Vendor}"
                    + $"\nType: {observation.Classification.Type.Label()} · OS: {observation.Classification.OperatingSystem.Label()}"
                    + $"\nEndpoints: {string.Join(", ", observation.Ports.Select(port => port.AccessibleLabel))}"
                    + (savedName is null && raw?.Imported == new ImportedDeviceMetadata() && assignment is null && classification is null
                        ? string.Empty
                        : $"\nPreserved MAC-specific data: name {savedName ?? raw?.Imported.Name ?? "-"}, "
                            + $"hostname {raw?.Imported.Hostname ?? "-"}, type {classification?.Type?.Label() ?? raw?.Imported.Type ?? "-"}, "
                            + $"OS {classification?.OperatingSystem?.Label() ?? raw?.Imported.OperatingSystem ?? "-"}, "
                            + $"family {raw?.Imported.Family ?? "-"}, model {raw?.Imported.Model ?? "-"}, "
                            + $"person {_sourceData?.PeopleRooms.People.FirstOrDefault(person => person.Id == assignment?.PersonId)?.Name ?? "-"}, "
                            + $"room {_sourceData?.PeopleRooms.Rooms.FirstOrDefault(room => room.Id == assignment?.RoomId)?.Name ?? "-"}");
            }));

    private static string FormatMac(string mac) =>
        string.Join("-", Enumerable.Range(0, 6).Select(i => mac.Substring(i * 2, 2)));

    /// <summary>Each member MAC with its own connections, confirmation date and the saved values Unlink restores.</summary>
    private string LinkedHistoryText()
    {
        var shownMac = _inventoryDevice?.Mac;
        var dates = LinkedDevice?.Members.ToDictionary(member => member.Mac, member => member.LinkedAt) ?? [];
        var data = _sourceData;
        return string.Join("\n\n", _linkedMembers
            .OrderBy(member => member.Mac != shownMac)
            .ThenByDescending(member => member.Observations.Select(item => (DateTimeOffset?)item.LastSeen).Max())
            .ThenBy(member => member.Mac, StringComparer.Ordinal)
            .Select(member =>
            {
                var header = FormatMac(member.Mac)
                    + (dates.TryGetValue(member.Mac, out var linkedAt)
                        ? $" · Confirmed by you on {linkedAt.ToLocalTime().ToString("d", CultureInfo.CurrentCulture)}" : string.Empty)
                    + (member.Mac == shownMac ? " · Shown in Devices" : string.Empty);
                var connections = member.Observations.Count == 0
                    ? ["No local connections; imported from Fing only."]
                    : member.Observations.OrderByDescending(item => item.LastSeen)
                        .ThenBy(item => item.Address, StringComparer.Ordinal)
                        .Select(item => $"{item.Address} · "
                            + (item.Present && item.LastChecked == member.CurrentCompletedAt
                                && item.NetworkId == member.CurrentNetworkId && item.Subnet == member.CurrentSubnet
                                    ? "Current response" : "Previous connection")
                            + $" · first seen {item.FirstSeen:g} · last seen {item.LastSeen:g}"
                            + $" · network {item.NetworkId ?? "unidentified"} · {item.Subnet}");
                var name = data?.Names.GetValueOrDefault(member.Mac) ?? member.Imported.Name;
                var identification = data?.Classifications.GetValueOrDefault(member.Mac);
                var assignment = data?.PeopleRooms.Assignments.GetValueOrDefault(member.Mac);
                // Assignments are kept by ID: a renamed Person/Room shows its current name; a deleted one restores as unassigned.
                var person = data?.PeopleRooms.People.FirstOrDefault(item => item.Id == assignment?.PersonId)?.Name;
                var room = data?.PeopleRooms.Rooms.FirstOrDefault(item => item.Id == assignment?.RoomId)?.Name;
                var restored = $"Saved values Unlink restores: name {name ?? "automatic"}, "
                    + $"type {identification?.Type?.Label() ?? member.Imported.Type ?? "automatic"}, "
                    + $"OS {identification?.OperatingSystem?.Label() ?? member.Imported.OperatingSystem ?? "automatic"}, "
                    + $"brand {identification?.Brand ?? member.Imported.Brand ?? "-"}, "
                    + $"family {identification?.Family ?? member.Imported.Family ?? "-"}, "
                    + $"model {identification?.Model ?? member.Imported.Model ?? "-"}, "
                    + $"person {person ?? "unassigned"}, room {room ?? "unassigned"}, "
                    + $"usage category {member.UsageCategoryOverride?.ToString() ?? "automatic"}";
                return string.Join("\n", [header, .. connections, restored]);
            }));
    }

    public static IEnumerable<ScanResultRow> CreateInventoryRows(DeviceInventoryData data)
    {
        foreach (var device in data.Devices.Values)
        {
            var observation = device.LatestObservation;
            if (PrivateVirtualDeviceAllocator.IsEligible(data, device)
                && data.VirtualDevices.Any(slot => slot.History.Any(item => item.Mac == device.Mac)
                    && observation?.NetworkId == slot.NetworkId && observation.Subnet == slot.Subnet))
                continue;
            if (data.FindLinkedDevice(device.Mac) is not null) continue;
            yield return ForDevice(device, data, observation is null ? 0 : int.Parse(observation.Subnet.Split('/')[1]),
                historical: IsHistoricalDevice(device));
        }
        foreach (var device in data.VirtualDevices)
            yield return new(device, data, int.Parse(device.Subnet.Split('/')[1]));
        foreach (var linked in data.LinkedDevices)
            yield return ForLinkedDevice(linked, data);
    }

    private static bool IsHistoricalDevice(InventoryDevice device) => device.LatestObservation is not { } observation
        || observation.LastChecked != device.CurrentCompletedAt
        || observation.NetworkId != device.CurrentNetworkId || observation.Subnet != device.CurrentSubnet;

    /// <summary>
    /// One row for a linked device. Every network value (IP, MAC, adapter vendor, response time, ports) comes from
    /// one representative member; the other members are its expandable "Linked MAC address" lines.
    /// </summary>
    public static ScanResultRow ForLinkedDevice(LinkedDevice linked, DeviceInventoryData data)
    {
        var members = linked.Members.Select(member => data.Devices[member.Mac]).ToArray();
        var scope = members.FirstOrDefault(member => member.CurrentSubnet is not null);
        var mac = scope is null ? null : LinkedDeviceRepresentatives.Select(linked, data,
            scope.CurrentNetworkId, scope.CurrentSubnet!, scope.CurrentCompletedAt);
        if (mac is null)
        {
            // Not seen on the current network: show the network where a member was most recently seen.
            var latest = members.SelectMany(member => member.Observations.Select(observation => (member.Mac, observation)))
                .OrderByDescending(item => item.observation.LastSeen).ThenBy(item => item.Mac, StringComparer.Ordinal)
                .FirstOrDefault();
            mac = latest.observation is null ? members.Select(member => member.Mac).Order(StringComparer.Ordinal).First()
                : LinkedDeviceRepresentatives.Select(linked, data, latest.observation.NetworkId, latest.observation.Subnet, null)
                    ?? latest.Mac;
        }
        var device = data.Devices[mac];
        var row = ForDevice(device, data, device.LatestObservation is { } observation
            ? int.Parse(observation.Subnet.Split('/')[1]) : 0, IsHistoricalDevice(device));
        row._linkedMembers = members;
        row._sourceData = data;
        row.RefreshMacExpansionLines();
        return row;
    }

    /// <summary>Whether this row stands for the whole linked device rather than one member record.</summary>
    public bool IsLinkedDeviceRow => _linkedMembers.Count > 0;

    /// <summary>The member MAC shown in Devices for a linked device row.</summary>
    public string? RepresentativeMac => IsLinkedDeviceRow ? _inventoryDevice?.Mac : null;

    /// <summary>A MAC record's row; a linked member shows its linked device's shared values.</summary>
    public static ScanResultRow ForDevice(InventoryDevice device, DeviceInventoryData data, int prefixLength = 0, bool historical = true)
    {
        var linked = data.FindLinkedDevice(device.Mac);
        var row = new ScanResultRow(device, prefixLength, linked?.Name ?? data.Names.GetValueOrDefault(device.Mac),
            linked?.Identification ?? data.Classifications.GetValueOrDefault(device.Mac), historical);
        if (linked is not null)
        {
            row.LinkedDevice = linked;
            row.UsageCategoryOverride = linked.UsageCategoryOverride;
        }
        return row;
    }

    public LinkedDevice? LinkedDevice { get; private set; }
    public bool IsLinked => LinkedDevice is not null;

    public void UpdateLinkedDevice(LinkedDevice device)
    {
        if (LinkedDevice is { } current && current.Id != device.Id)
            throw new ArgumentException("The linked identity must not change.", nameof(device));
        if (VirtualDevice is not null || MacAddress?.ToString() is not { } mac || !device.HasMember(mac))
            throw new ArgumentException("Only a member MAC record can show a linked device.", nameof(device));
        LinkedDevice = device;
        if (_linkedMembers.Count > 0) RefreshMacExpansionLines();
        SetCustomName(device.Name);
        SetClassificationOverride(device.Identification);
        SetUsageCategory(device.UsageCategoryOverride, UsageInference, UsageStatus);
    }

    public void UpdateVirtualDevice(PrivateVirtualDevice device)
    {
        if (VirtualDevice?.Id != device.Id) throw new ArgumentException("The virtual identity must not change.", nameof(device));
        VirtualDevice = device;
        RefreshMacExpansionLines();
        SetCustomName(device.Name);
        SetClassificationOverride(device.Classification);
        SetUsageCategory(device.UsageCategoryOverride, UsageInference, UsageStatus);
    }

    internal void UpdateObservation(ScanResultRow updated)
    {
        if (IdentityKey != updated.IdentityKey)
            throw new ArgumentException("The device identity must not change.", nameof(updated));
        var choice = SelectedTargetChoice;
        _inventoryDevice = updated._inventoryDevice;
        _historical = updated._historical;
        _showLatency = updated._showLatency;
        _sourceData = updated._sourceData;
        _prefixLength = updated._prefixLength;
        VirtualDevice = updated.VirtualDevice;
        LinkedDevice = updated.LinkedDevice;
        _linkedMembers = updated._linkedMembers;
        RefreshMacExpansionLines();
        Result = updated.Result;
        _customName = updated._customName;
        _classificationOverride = updated._classificationOverride;
        UsageCategoryOverride = updated.UsageCategoryOverride;
        _connectionOverrides.Clear();
        AddressPrefix = updated.AddressPrefix;
        AddressHost = updated.AddressHost;
        MacOui = updated.MacOui;
        MacNic = updated.MacNic;
        // A chosen address stays selected only while that member/address still responds; otherwise the default returns.
        if (CurrentTargets.FirstOrDefault(item => TargetChoice(item) == choice) is { } target) SetResult(target);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    private void RefreshMacExpansionLines()
    {
        if (_linkedMembers.Count > 0 && _inventoryDevice is { } shown)
        {
            _earlierMacLines = _linkedMembers.Where(member => member.Mac != shown.Mac)
                .Select(member => (Member: member, Observation: member.LatestObservation))
                .OrderByDescending(item => item.Member.Status == InventoryDeviceStatus.Online)
                .ThenByDescending(item => item.Observation?.LastSeen)
                .ThenBy(item => item.Member.Mac, StringComparer.Ordinal)
                .Select(item =>
                {
                    var address = item.Observation?.Address ?? item.Member.Imported.Address ?? "-";
                    var vendor = DeviceVendorPresentation.DisplayText(item.Observation?.Vendor ?? "Unknown");
                    var status = item.Member.Status switch
                    {
                        InventoryDeviceStatus.Online => "Online",
                        InventoryDeviceStatus.FingOnly => "Fing Only",
                        _ => "Offline"
                    };
                    return new DeviceMacExpansionLine("Linked MAC address", address, FormatMac(item.Member.Mac), vendor, status,
                        item.Observation?.LastSeen ?? default,
                        $"Linked MAC address: {FormatMac(item.Member.Mac)}, {address}, {vendor}, {status}, "
                            + (item.Observation is { } observation ? $"last seen {observation.LastSeen:g}" : "never seen locally"))
                    {
                        SearchAddresses = item.Member.Observations.Select(observation => observation.Address)
                            .Append(item.Member.Imported.Address).OfType<string>().Distinct(StringComparer.Ordinal).ToArray()
                    };
                }).ToArray();
            NotifyMacExpansionChanged();
            return;
        }
        if (VirtualDevice is not { } device)
        {
            _earlierMacLines = [];
            return;
        }

        _earlierMacLines = device.History
            .Where(item => !string.Equals(item.Mac, device.LastActiveMac, StringComparison.OrdinalIgnoreCase))
            .GroupBy(item => item.Mac, StringComparer.OrdinalIgnoreCase)
            .Select(group => group
                .OrderByDescending(item => item.Observation.LastSeen)
                .ThenByDescending(item => item.Observation.LastChecked)
                .ThenBy(item => item.Observation.Address, StringComparer.Ordinal)
                .First())
            .OrderByDescending(item => item.Observation.LastSeen)
            .ThenByDescending(item => item.Observation.LastChecked)
            .ThenBy(item => item.Mac, StringComparer.Ordinal)
            .Select(item => new DeviceMacExpansionLine(
                "Earlier MAC address",
                item.Observation.Address,
                FormatMac(item.Mac),
                DeviceVendorPresentation.DisplayText(item.Observation.Vendor),
                item.Observation.Present ? "Online" : "Offline",
                item.Observation.LastSeen,
                $"Earlier MAC address: {FormatMac(item.Mac)}, {item.Observation.Address}, "
                    + $"{DeviceVendorPresentation.DisplayText(item.Observation.Vendor)}, "
                    + $"{(item.Observation.Present ? "Online" : "Offline")}, "
                    + $"last seen {item.Observation.LastSeen:g}"))
            .ToArray();
        NotifyMacExpansionChanged();
    }

    private void NotifyMacExpansionChanged()
    {
        foreach (var property in new[]
        {
            nameof(HasEarlierMacAddresses), nameof(EarlierMacAddressCount), nameof(SearchExpandsMacAddresses),
            nameof(AreMacAddressesExpanded), nameof(CanToggleMacAddresses), nameof(MacExpansionGlyph),
            nameof(MacExpansionState), nameof(MacExpansionName), nameof(VisibleMacExpansionLines),
            nameof(MoreMacAddressesText)
        })
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }

    public void SelectAddress(string address)
    {
        var connection = CurrentConnections.FirstOrDefault(item => item.AddressText == address)
            ?? throw new ArgumentException("Select an address responding in the current scan.", nameof(address));
        SetResult(connection);
    }

    /// <summary>Selects a <see cref="CurrentTargetChoices"/> entry for Device Details to inspect and probe.</summary>
    public void SelectTarget(string choice)
    {
        var target = CurrentTargets.FirstOrDefault(item => TargetChoice(item) == choice)
            ?? throw new ArgumentException("Select an address responding in the current scan.", nameof(choice));
        SetResult(target);
    }

    /// <summary>
    /// Returns a linked device to the member shown in Devices after Device Details inspected another member.
    /// Returns whether anything changed.
    /// </summary>
    public bool ResetTarget()
    {
        if (!IsLinkedDeviceRow || _inventoryDevice is not { } shown || Result?.MacAddress?.ToString() is not { } mac
            || mac == shown.Mac)
            return false;
        var latest = shown.LatestObservation;
        var target = latest is null ? null
            : CurrentTargets.FirstOrDefault(item => item.MacAddress?.ToString() == shown.Mac && item.AddressText == latest.Address)
                ?? latest.ToScanResult(shown.Mac);
        if (target is null) return false;
        SetResult(target);
        return true;
    }

    private void SetResult(ScanResult connection)
    {
        Result = connection;
        var address = connection.AddressText;
        var octets = address.Split('.');
        var count = Math.Min(_prefixLength / 8, 3);
        AddressPrefix = count == 0 ? string.Empty : string.Join(".", octets.Take(count)) + ".";
        AddressHost = string.Join(".", octets.Skip(count));
        if (connection.MacAddress?.GetAddressBytes().Length == 6)
        {
            MacOui = MacAddressText[..8];
            MacNic = MacAddressText[8..];
        }
        foreach (var property in new[] { nameof(Result), nameof(AddressText), nameof(OpenPortItems),
                     nameof(LatencyLabel), nameof(LatencyMilliseconds), nameof(MacAddressText), nameof(MacOui), nameof(MacNic),
                     nameof(AddressPrefix), nameof(AddressHost), nameof(AddressHostFontSize),
                     nameof(DisplayAddressPrefix), nameof(DisplayAddressHost), nameof(ReportedValues),
                     nameof(ServiceAdvertisements), nameof(HasLatestServiceDiscovery), nameof(ServiceDiscoveryName),
                     nameof(ServiceDiscoveryText) })
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }
    public PhysicalAddress? MacAddress => Result?.MacAddress
        ?? (_inventoryDevice is null ? null : PhysicalAddress.Parse(_inventoryDevice.Mac));
    public string AddressText => Result?.AddressText ?? _inventoryDevice?.Imported.Address ?? "-";
    public string MacAddressText => MacAddress is { } mac
        ? string.Join("-", mac.GetAddressBytes().Select(value => value.ToString("X2"))) : Result?.MacAddressText ?? "-";
    public string HostnameText => !string.IsNullOrWhiteSpace(Result?.DeviceName)
        ? Result.DeviceName : _inventoryDevice?.Imported.Hostname ?? "-";
    public string AutomaticName => VirtualDevice?.AutomaticName ?? _inventoryDevice?.Imported.Name
        ?? (HostnameText != "-" ? HostnameText : AddressText);
    // A linked member shows only the linked device's shared identification, never another member's imported values.
    private ImportedDeviceMetadata? SharedImported => IsLinked ? null : ImportedMetadata;
    private string SavedSource => IsLinked ? "Linked device value" : "Saved correction";
    public string IdentificationSourceLabel => SavedSource;
    public string VendorText => _classificationOverride?.Brand ?? SharedImported?.Brand ?? Result?.VendorName ?? "Unknown";
    public string BrandText => _classificationOverride?.Brand ?? (IsLinked ? "-" : ImportedMetadata?.Brand
        ?? (VendorText is "Unknown" or "Private" or "Private/Randomized" ? "-" : VendorText));
    public string FamilyText => _classificationOverride?.Family ?? SharedImported?.Family ?? "-";
    public string ModelText => _classificationOverride?.Model ?? SharedImported?.Model ?? "-";
    public string BrandSource => _classificationOverride?.Brand is not null ? SavedSource
        : IsLinked ? string.Empty
        : ImportedMetadata?.Brand is not null ? "Imported from Fing" : "Manufacturer lookup";
    public string FamilySource => _classificationOverride?.Family is not null ? SavedSource
        : SharedImported?.Family is not null ? "Imported from Fing" : string.Empty;
    public string ModelSource => _classificationOverride?.Model is not null ? SavedSource
        : SharedImported?.Model is not null ? "Imported from Fing" : string.Empty;
    public string VendorDisplayText => DeviceVendorPresentation.DisplayText(VendorText);
    public string VendorDescription => DeviceVendorPresentation.Description(VendorText);
    public IReadOnlyList<OpenPort> OpenPortItems => IsCurrentScanResponse && _inventoryDevice is not null
        ? CurrentConnections.SelectMany(item => item.OpenPortItems).DistinctBy(port => port.Identity)
            .OrderBy(port => port.Port).ThenBy(port => port.Protocol).ToArray()
        : Result?.OpenPortItems ?? [];
    public ImportedDeviceMetadata? ImportedMetadata => _inventoryDevice?.Imported;
    public IReadOnlyList<ServiceAdvertisement> ServiceAdvertisements => Result?.ServiceAdvertisements ?? [];
    // The Devices icon reflects only advertisements received in the latest scan; Device Details keeps their time.
    public bool HasLatestServiceDiscovery => IsCurrentScanResponse && ServiceAdvertisements.Count > 0;
    public string ServiceDiscoveryName => ServiceAdvertisements.Count == 1
        ? "Service discovery: 1 advertised service" : $"Service discovery: {ServiceAdvertisements.Count} advertised services";
    public string ServiceDiscoveryText => ServiceDiscoveryPresentation.Tooltip(ServiceAdvertisements);
    private DeviceClassification Detected => Result?.DetectedClassification ?? DeviceClassification.Unknown;
    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public string NameText => _customName ?? AutomaticName;
    public DeviceClassificationOverride? ClassificationOverride => _classificationOverride;
    public DeviceOperatingSystem OperatingSystem =>
        _classificationOverride?.OperatingSystem ?? FingClassificationMapper.OperatingSystem(ImportedMetadata?.OperatingSystem)
        ?? Detected.OperatingSystem;
    public DeviceType Type => _classificationOverride?.Type ?? FingClassificationMapper.Type(ImportedMetadata?.Type)
        ?? Detected.Type;
    public DeviceType Icon => _classificationOverride?.Icon ?? Type;
    public string OperatingSystemText => OperatingSystem.Label()
        + (_classificationOverride?.OperatingSystem is null && FingClassificationMapper.OperatingSystem(ImportedMetadata?.OperatingSystem) is null && Detected.OperatingSystemIsInferred
            ? " (likely)" : string.Empty);
    public string DeviceTypeText => Type.Label()
        + (_classificationOverride?.Type is null && FingClassificationMapper.Type(ImportedMetadata?.Type) is null && Detected.TypeIsInferred
            ? " (likely)" : string.Empty);
    public string OperatingSystemSource => _classificationOverride?.OperatingSystem is not null
        ? $"{(IsLinked ? "Linked device value. This MAC's automatic value" : "User-selected. Automatic")}: {Detected.OperatingSystem.Label()}. {Detected.OperatingSystemEvidence}"
        : ImportedMetadata?.OperatingSystem is { } os
            ? $"Imported from Fing: {os}{(FingClassificationMapper.OperatingSystem(os) is null ? " (unmapped; using automatic category)" : string.Empty)}. Automatic: {Detected.OperatingSystemEvidence}" : Detected.OperatingSystemEvidence;
    public string DeviceTypeSource => _classificationOverride?.Type is not null
        ? $"{(IsLinked ? "Linked device value. This MAC's automatic value" : "User-selected. Automatic")}: {Detected.Type.Label()}. {Detected.TypeEvidence}"
        : ImportedMetadata?.Type is { } type
            ? $"Imported from Fing: {type}{(FingClassificationMapper.Type(type) is null ? " (unmapped; using automatic category)" : string.Empty)}. Automatic: {Detected.TypeEvidence}" : Detected.TypeEvidence;
    public bool UsesVirtualIcon => IsVirtualIdentity && _classificationOverride?.Icon is null;
    public string IconText => UsesVirtualIcon ? "Virtual device (multiple PCs)" : Icon.Label();
    public string IconSource => _classificationOverride?.Icon is not null
        ? $"{(IsLinked ? "Linked device icon" : "User-selected icon")}: {Icon.Label()}"
        : UsesVirtualIcon ? VirtualIdentityDescription : $"Icon follows device type: {Type.Label()}";
    public string IconGlyph => UsesVirtualIcon ? "\uE975" : GetIconGlyph(Icon);
    public static string GetIconGlyph(DeviceType icon) => icon switch
    {
        DeviceType.Computer => "\uE7F8",
        DeviceType.Phone => "\uE8EA",
        DeviceType.Tablet => "\uE70A",
        DeviceType.Router => "\uE968",
        DeviceType.Printer => "\uE749",
        DeviceType.MediaDevice => "\uE7F4",
        DeviceType.Storage => "\uEDA2",
        DeviceType.GameConsole => "\uE7FC",
        DeviceType.SmartDevice => "\uEA80",
        _ => "\uE9CE"
    };
    public string AddressPrefix { get; private set; }
    public string AddressHost { get; private set; }
    public string MacOui { get; private set; }
    public string MacNic { get; private set; }
    public Guid? PersonId => _personId;
    public Guid? RoomId => _roomId;
    public bool HasPersonAssignment => _personId is not null && !string.IsNullOrWhiteSpace(_personShortName);
    public bool HasRoomAssignment => _roomId is not null && !string.IsNullOrWhiteSpace(_roomShortName);
    public bool HasNoAssignments => !HasPersonAssignment && !HasRoomAssignment;
    public string PersonAssignmentDescription => $"Person: {PersonFullName}";
    public string RoomAssignmentDescription => $"Room: {RoomFullName}";
    public string PersonShortName => _personId is null || string.IsNullOrWhiteSpace(_personShortName) ? "-" : _personShortName;
    public string PersonFullName => _personId is null || string.IsNullOrWhiteSpace(_personName) ? "Unassigned" : _personName;
    public string RoomShortName => _roomId is null || string.IsNullOrWhiteSpace(_roomShortName) ? "-" : _roomShortName;
    public string RoomFullName => _roomId is null || string.IsNullOrWhiteSpace(_roomName) ? "Unassigned" : _roomName;
    public double PersonOpacity => _personId is null || string.IsNullOrWhiteSpace(_personShortName) ? 0.65 : 1;
    public double RoomOpacity => _roomId is null || string.IsNullOrWhiteSpace(_roomShortName) ? 0.65 : 1;
    public InventoryDeviceStatus Status => VirtualDevice?.Status
        ?? _inventoryDevice?.Status
        ?? (Result?.Status == HostStatus.Alive ? InventoryDeviceStatus.Online : InventoryDeviceStatus.Offline);
    public bool IsOnline => Status == InventoryDeviceStatus.Online;
    public bool IsOffline => Status == InventoryDeviceStatus.Offline;
    public bool IsFingOnly => Status == InventoryDeviceStatus.FingOnly;
    public bool IsHistorical => !IsFingOnly && _historical;
    public bool IsCurrentScanResponse => IsOnline && !IsHistorical;
    public bool CanProbe => IsCurrentScanResponse && Result is not null;
    public string StatusLabel => IsFingOnly ? "Fing Only" : IsOnline ? "Online" : IsOffline ? "Offline" : "Unknown";
    public string StatusContext => IsFingOnly ? "Imported from Fing; never observed locally."
        : _inventoryDevice?.LatestObservation is { } observation
            ? $"{StatusLabel} · {(IsCurrentScanResponse ? "response in latest scan" : "saved scan evidence")} · {observation.Subnet} · last seen {observation.LastSeen:g}"
            : StatusLabel + (IsHistorical ? " · saved scan evidence" : string.Empty);
    public double NameOpacity => NameText == AddressText || NameText == "-" ? 0.65 : 1;
    public double VendorOpacity => DeviceVendorPresentation.FilterValue(VendorText) == DeviceVendorPresentation.Unknown ? 0.65 : 1;
    public double OperatingSystemOpacity => OperatingSystem == DeviceOperatingSystem.Unknown ? 0.65 : 1;
    public double DeviceTypeOpacity => Type == DeviceType.Unknown ? 0.65 : 1;
    public bool HasLatency => _showLatency && IsCurrentScanResponse && Result?.RoundtripTimeMilliseconds is >= 0;
    public long? LatencyMilliseconds => HasLatency ? Result?.RoundtripTimeMilliseconds : null;
    public string LatencyLabel => HasLatency ? Result!.RoundtripText
        : IsCurrentScanResponse && Result?.RoundtripTimeMilliseconds is null && ServiceAdvertisements.Count > 0 ? "--" : "-";
    public double LatencyFraction { get; private set; }
    public double LatencyFill => HasLatency ? 20 + (80 * LatencyFraction) : 0;

    public bool IsAlternateRow
    {
        get => _isAlternateRow;
        set
        {
            if (_isAlternateRow == value)
            {
                return;
            }
            _isAlternateRow = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsAlternateRow)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasStripe)));
        }
    }

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (_isSelected == value)
            {
                return;
            }
            _isSelected = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasStripe)));
        }
    }

    public bool IsPointerOver
    {
        get => _isPointerOver;
        set
        {
            if (_isPointerOver == value)
            {
                return;
            }
            _isPointerOver = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasStripe)));
        }
    }

    public bool HasStripe => IsAlternateRow && !IsSelected && !IsPointerOver;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Whether a linked or virtual device's other MAC address lines match a search.</summary>
    public bool MatchesEarlierMac(string search) => _earlierMacLines.Any(line => line.Matches(search));

    public bool MatchesFilter(string? filter)
    {
        var search = filter?.Trim() ?? string.Empty;
        return NameText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || (_personShortName?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (_personName?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (_roomShortName?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (_roomName?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || OperatingSystemText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || DeviceTypeText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || (EffectiveUsageCategory?.ToString().Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || StatusLabel.Contains(search, StringComparison.OrdinalIgnoreCase)
            || HostnameText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || AddressText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || MacAddressText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || VendorText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || VendorDisplayText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || FamilyText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || ModelText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || (ImportedMetadata?.Type?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (ImportedMetadata?.OperatingSystem?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (ImportedMetadata?.Family?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (ImportedMetadata?.Model?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || _earlierMacLines.Any(line => line.Matches(search))
            || (search.Length > 0 && _linkedMembers.Any(member => member.Observations.Any(observation =>
                observation.Address.Contains(search, StringComparison.OrdinalIgnoreCase))))
            || (VirtualDevice is not null && ConnectionHistoryText.Contains(search, StringComparison.OrdinalIgnoreCase))
            || CurrentConnections.Any(item => item.MatchesFilter(filter))
            || (Result?.MatchesFilter(filter) ?? false);
    }

    public void SetClassificationOverride(DeviceClassificationOverride? value)
    {
        _classificationOverride = value;
        foreach (var property in new[]
        {
            nameof(ClassificationOverride), nameof(OperatingSystem), nameof(Type), nameof(Icon),
            nameof(OperatingSystemText), nameof(DeviceTypeText), nameof(OperatingSystemSource),
            nameof(DeviceTypeSource), nameof(IconGlyph), nameof(IconSource), nameof(IconText), nameof(UsesVirtualIcon),
            nameof(OperatingSystemOpacity), nameof(DeviceTypeOpacity),
            nameof(BrandText), nameof(FamilyText), nameof(ModelText),
            nameof(BrandSource), nameof(FamilySource), nameof(ModelSource),
            nameof(VendorText), nameof(VendorDisplayText), nameof(VendorDescription), nameof(VendorOpacity)
        })
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
        }
    }

    public void SetCustomName(string? customName)
    {
        _customName = string.IsNullOrWhiteSpace(customName) ? null : customName.Trim();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(NameText)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(NameOpacity)));
    }

    public IReadOnlyList<DeviceMatchSuggestion> MatchSuggestions { get; private set; } = [];
    public bool HasMatchSuggestions => MatchSuggestions.Count > 0;
    public string MatchSuggestionText { get; private set; } = string.Empty;
    public string MatchSuggestionName => MatchSuggestions.Count == 1
        ? "Review 1 possible matching MAC address" : $"Review {MatchSuggestions.Count} possible matching MAC addresses";

    public void SetMatchSuggestions(IReadOnlyList<DeviceMatchSuggestion> suggestions, string text)
    {
        MatchSuggestions = suggestions;
        MatchSuggestionText = text;
        foreach (var property in new[] { nameof(MatchSuggestions), nameof(HasMatchSuggestions),
                     nameof(MatchSuggestionText), nameof(MatchSuggestionName) })
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }

    public void SetPeopleRoomAssignments(
        Guid? personId,
        string? personShortName,
        string? personName,
        Guid? roomId,
        string? roomShortName,
        string? roomName)
    {
        _personId = personId;
        _personShortName = personShortName;
        _personName = personName;
        _roomId = roomId;
        _roomShortName = roomShortName;
        _roomName = roomName;
        foreach (var property in new[]
        {
            nameof(PersonId), nameof(PersonShortName), nameof(PersonFullName), nameof(PersonOpacity),
            nameof(RoomId), nameof(RoomShortName), nameof(RoomFullName), nameof(RoomOpacity),
            nameof(HasPersonAssignment), nameof(HasRoomAssignment), nameof(HasNoAssignments),
            nameof(PersonAssignmentDescription), nameof(RoomAssignmentDescription)
        })
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
        }
    }

    public void UpdateOpenPorts(IReadOnlyList<OpenPort> openPorts)
    {
        if (Result is null) throw new InvalidOperationException("Imported-only devices have no local probe result.");
        Result = Result with { OpenPorts = openPorts };
        _connectionOverrides[ConnectionKey(Result.MacAddress?.ToString(), Result.AddressText)] = Result;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Result)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(OpenPortItems)));
    }

    public void UpdateUdpObservations(IReadOnlyList<UdpServiceObservation> observations)
    {
        if (Result is null) throw new InvalidOperationException("Imported-only devices have no local probe result.");
        Result = Result with { UdpObservations = observations };
        _connectionOverrides[ConnectionKey(Result.MacAddress?.ToString(), Result.AddressText)] = Result;
    }

    public void UpdateLatencyRange(long minimum, long maximum)
    {
        if (minimum < 0 || maximum < minimum)
        {
            throw new ArgumentOutOfRangeException(nameof(minimum), "Latency bounds must be nonnegative and ordered.");
        }

        var fraction = HasLatency && Result?.RoundtripTimeMilliseconds is long latency && maximum > minimum
            ? Math.Clamp(((double)latency - minimum) / (maximum - minimum), 0, 1)
            : 0;
        if (fraction == LatencyFraction)
        {
            return;
        }

        LatencyFraction = fraction;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LatencyFraction)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LatencyFill)));
    }
}
