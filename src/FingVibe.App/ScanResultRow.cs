using System.ComponentModel;
using System.Net.NetworkInformation;
using FingVibe.Core.Import;
using FingVibe.Core.Models;

namespace FingVibe.App;

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
    private readonly InventoryDevice? _inventoryDevice;
    private readonly bool _historical;
    private readonly bool _showLatency = true;
    private readonly DeviceInventoryData? _sourceData;
    private readonly Dictionary<string, ScanResult> _connectionOverrides = new();
    private readonly int _prefixLength;
    public PrivateVirtualDevice? VirtualDevice { get; private set; }
    public string IdentityKey => VirtualDevice?.Id.ToString("D") ?? MacAddress?.ToString() ?? AddressText;
    public string? CustomName => _customName;

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
    public ScanResultRow(PrivateVirtualDevice device, DeviceInventoryData data, int prefixLength)
        : this(new InventoryDevice(device.LastActiveMac, data.Devices[device.LastActiveMac].Imported,
            device.History.Where(item => item.Mac == device.LastActiveMac).Select(item => item.Observation).ToArray())
        {
            CurrentCompletedAt = device.CurrentCompletedAt,
            CurrentNetworkId = device.NetworkId,
            CurrentSubnet = device.Subnet
        }, prefixLength, device.Name, device.Classification,
            historical: device.Status == InventoryDeviceStatus.Unknown)
    {
        VirtualDevice = device;
        _sourceData = data;
        Result = device.LatestConnection.Observation.ToScanResult(device.LastActiveMac);
    }

    public IReadOnlyList<ScanResult> CurrentConnections => !IsCurrentScanResponse ? []
        : _inventoryDevice is { } device
            ? device.Observations.Where(item => item.Present && item.LastChecked == device.CurrentCompletedAt
                && item.NetworkId == device.CurrentNetworkId && item.Subnet == device.CurrentSubnet)
                .OrderBy(item => item.Address, StringComparer.Ordinal)
                .Select(item => _connectionOverrides.GetValueOrDefault(item.Address) ?? item.ToScanResult(device.Mac)).ToArray()
            : Result is { } result ? [result] : [];
    public string ConnectionHistoryText => VirtualDevice is not { } device ? string.Empty
        : string.Join("\n\n", device.History.OrderByDescending(item => item.Observation.LastSeen)
            .ThenBy(item => item.Mac, StringComparer.Ordinal).Select(item =>
            {
                var observation = item.Observation;
                var raw = _sourceData?.Devices.GetValueOrDefault(item.Mac);
                var savedName = _sourceData?.Names.GetValueOrDefault(item.Mac);
                var assignment = _sourceData?.PeopleRooms.Assignments.GetValueOrDefault(item.Mac);
                var classification = _sourceData?.Classifications.GetValueOrDefault(item.Mac);
                return $"{FormatMac(item.Mac)} · {observation.Address}\n"
                    + $"{(IsOnline && item.Mac == device.LastActiveMac && observation.Present && observation.LastChecked == device.CurrentCompletedAt ? "Current response" : "Previous connection")}"
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

    public static IEnumerable<ScanResultRow> CreateInventoryRows(DeviceInventoryData data)
    {
        foreach (var device in data.Devices.Values)
        {
            var observation = device.LatestObservation;
            if (PrivateVirtualDeviceAllocator.IsEligible(data, device)
                && data.VirtualDevices.Any(slot => slot.History.Any(item => item.Mac == device.Mac)
                    && observation?.NetworkId == slot.NetworkId && observation.Subnet == slot.Subnet))
                continue;
            yield return new(device, observation is null ? 0 : int.Parse(observation.Subnet.Split('/')[1]),
                data.Names.GetValueOrDefault(device.Mac), data.Classifications.GetValueOrDefault(device.Mac),
                historical: device.Status == InventoryDeviceStatus.Unknown);
        }
        foreach (var device in data.VirtualDevices)
            yield return new(device, data, int.Parse(device.Subnet.Split('/')[1]));
    }

    public void UpdateVirtualDevice(PrivateVirtualDevice device)
    {
        if (VirtualDevice?.Id != device.Id) throw new ArgumentException("The virtual identity must not change.", nameof(device));
        VirtualDevice = device;
        SetCustomName(device.Name);
        SetClassificationOverride(device.Classification);
    }

    public void SelectAddress(string address)
    {
        var connection = CurrentConnections.FirstOrDefault(item => item.AddressText == address)
            ?? throw new ArgumentException("Select an address responding in the current scan.", nameof(address));
        Result = connection;
        var octets = address.Split('.');
        var count = Math.Min(_prefixLength / 8, 3);
        AddressPrefix = count == 0 ? string.Empty : string.Join(".", octets.Take(count)) + ".";
        AddressHost = string.Join(".", octets.Skip(count));
        foreach (var property in new[] { nameof(Result), nameof(AddressText), nameof(OpenPortItems),
                     nameof(LatencyLabel), nameof(LatencyMilliseconds), nameof(MacAddressText),
                     nameof(AddressPrefix), nameof(AddressHost) })
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    }
    public PhysicalAddress? MacAddress => Result?.MacAddress
        ?? (_inventoryDevice is null ? null : PhysicalAddress.Parse(_inventoryDevice.Mac));
    public string AddressText => Result?.AddressText ?? _inventoryDevice?.Imported.Address ?? "-";
    public string MacAddressText => MacAddress is { } mac
        ? string.Join("-", mac.GetAddressBytes().Select(value => value.ToString("X2"))) : "-";
    public string HostnameText => !string.IsNullOrWhiteSpace(Result?.DeviceName)
        ? Result.DeviceName : _inventoryDevice?.Imported.Hostname ?? "-";
    public string AutomaticName => VirtualDevice?.AutomaticName ?? _inventoryDevice?.Imported.Name
        ?? (HostnameText != "-" ? HostnameText : AddressText);
    public string VendorText => _inventoryDevice?.Imported.Brand ?? Result?.VendorName ?? "Unknown";
    public IReadOnlyList<OpenPort> OpenPortItems => IsCurrentScanResponse && _inventoryDevice is not null
        ? CurrentConnections.SelectMany(item => item.OpenPortItems).DistinctBy(port => port.Identity)
            .OrderBy(port => port.Port).ThenBy(port => port.Protocol).ToArray()
        : Result?.OpenPortItems ?? [];
    public ImportedDeviceMetadata? ImportedMetadata => _inventoryDevice?.Imported;
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
        ? $"User-selected. Automatic: {Detected.OperatingSystem.Label()}. {Detected.OperatingSystemEvidence}"
        : ImportedMetadata?.OperatingSystem is { } os
            ? $"Imported from Fing: {os}{(FingClassificationMapper.OperatingSystem(os) is null ? " (unmapped; using automatic category)" : string.Empty)}. Automatic: {Detected.OperatingSystemEvidence}" : Detected.OperatingSystemEvidence;
    public string DeviceTypeSource => _classificationOverride?.Type is not null
        ? $"User-selected. Automatic: {Detected.Type.Label()}. {Detected.TypeEvidence}"
        : ImportedMetadata?.Type is { } type
            ? $"Imported from Fing: {type}{(FingClassificationMapper.Type(type) is null ? " (unmapped; using automatic category)" : string.Empty)}. Automatic: {Detected.TypeEvidence}" : Detected.TypeEvidence;
    public string IconSource => _classificationOverride?.Icon is not null
        ? $"User-selected icon: {Icon.Label()}" : $"Icon follows device type: {Type.Label()}";
    public string IconGlyph => GetIconGlyph(Icon);
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
    public string MacOui { get; }
    public string MacNic { get; }
    public Guid? PersonId => _personId;
    public Guid? RoomId => _roomId;
    public string PersonShortName => _personShortName ?? "-";
    public string PersonFullName => _personName ?? "Unassigned";
    public string RoomShortName => _roomShortName ?? "-";
    public string RoomFullName => _roomName ?? "Unassigned";
    public double PersonOpacity => _personId is null ? 0.65 : 1;
    public double RoomOpacity => _roomId is null ? 0.65 : 1;
    public InventoryDeviceStatus Status => VirtualDevice?.Status
        ?? (_historical && _inventoryDevice?.Status != InventoryDeviceStatus.FingOnly ? (InventoryDeviceStatus?)InventoryDeviceStatus.Unknown : null)
        ?? _inventoryDevice?.Status
        ?? (Result?.Status == HostStatus.Alive ? InventoryDeviceStatus.Online : InventoryDeviceStatus.Offline);
    public bool IsOnline => Status == InventoryDeviceStatus.Online;
    public bool IsOffline => Status == InventoryDeviceStatus.Offline;
    public bool IsFingOnly => Status == InventoryDeviceStatus.FingOnly;
    public bool IsHistorical => !IsFingOnly && Status == InventoryDeviceStatus.Unknown;
    public bool IsCurrentScanResponse => IsOnline && !IsHistorical;
    public bool CanProbe => IsCurrentScanResponse && Result is not null;
    public string StatusLabel => IsFingOnly ? "Fing Only" : IsOnline ? "Online" : IsOffline ? "Offline" : "Unknown";
    public string StatusContext => IsFingOnly ? "Imported from Fing; never observed locally."
        : _inventoryDevice?.LatestObservation is { } observation
            ? $"{StatusLabel}{(IsHistorical ? " · historical" : string.Empty)} · {observation.Subnet} · last seen {observation.LastSeen:g}"
            : StatusLabel + (IsHistorical ? " · historical scan observation" : string.Empty);
    public double NameOpacity => NameText == AddressText || NameText == "-" ? 0.65 : 1;
    public double VendorOpacity => VendorText is "Unknown" or "-" ? 0.65 : 1;
    public double OperatingSystemOpacity => OperatingSystem == DeviceOperatingSystem.Unknown ? 0.65 : 1;
    public double DeviceTypeOpacity => Type == DeviceType.Unknown ? 0.65 : 1;
    public bool HasLatency => _showLatency && IsOnline && Result?.RoundtripTimeMilliseconds is >= 0;
    public long? LatencyMilliseconds => HasLatency ? Result?.RoundtripTimeMilliseconds : null;
    public string LatencyLabel => HasLatency ? Result!.RoundtripText : "-";
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
            || StatusLabel.Contains(search, StringComparison.OrdinalIgnoreCase)
            || HostnameText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || AddressText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || MacAddressText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || VendorText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || (ImportedMetadata?.Type?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (ImportedMetadata?.OperatingSystem?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (ImportedMetadata?.Family?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
            || (ImportedMetadata?.Model?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
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
            nameof(DeviceTypeSource), nameof(IconGlyph), nameof(IconSource),
            nameof(OperatingSystemOpacity), nameof(DeviceTypeOpacity)
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
            nameof(RoomId), nameof(RoomShortName), nameof(RoomFullName), nameof(RoomOpacity)
        })
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
        }
    }

    public void UpdateOpenPorts(IReadOnlyList<OpenPort> openPorts)
    {
        if (Result is null) throw new InvalidOperationException("Imported-only devices have no local probe result.");
        Result = Result with { OpenPorts = openPorts };
        _connectionOverrides[Result.AddressText] = Result;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Result)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(OpenPortItems)));
    }

    public void UpdateUdpObservations(IReadOnlyList<UdpServiceObservation> observations)
    {
        if (Result is null) throw new InvalidOperationException("Imported-only devices have no local probe result.");
        Result = Result with { UdpObservations = observations };
        _connectionOverrides[Result.AddressText] = Result;
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
