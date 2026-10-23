using System.ComponentModel;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed class ScanResultRow : INotifyPropertyChanged
{
    private string? _customName;
    private DeviceClassificationOverride? _classificationOverride;

    public ScanResultRow(ScanResult result, int prefixLength, string? customName = null,
        DeviceClassificationOverride? classificationOverride = null)
    {
        if (prefixLength is < 0 or > 32)
        {
            throw new ArgumentOutOfRangeException(nameof(prefixLength));
        }

        Result = result;
        _customName = string.IsNullOrWhiteSpace(customName) ? null : customName.Trim();
        _classificationOverride = classificationOverride;
        var octets = result.AddressText.Split('.');
        // Only dim complete network octets; a partially masked octet also identifies hosts.
        var prefixOctets = octets.Length == 4 ? Math.Min(prefixLength / 8, 3) : 0;
        AddressPrefix = prefixOctets == 0
            ? string.Empty
            : string.Join(".", octets.Take(prefixOctets)) + ".";
        AddressHost = string.Join(".", octets.Skip(prefixOctets));

        var mac = result.MacAddressText;
        MacOui = result.MacAddress?.GetAddressBytes().Length == 6 ? mac[..8] : mac;
        MacNic = result.MacAddress?.GetAddressBytes().Length == 6 ? mac[8..] : string.Empty;
    }

    public ScanResult Result { get; private set; }
    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public string NameText => _customName ?? Result.NameText;
    public DeviceClassificationOverride? ClassificationOverride => _classificationOverride;
    public DeviceOperatingSystem OperatingSystem =>
        _classificationOverride?.OperatingSystem ?? Result.DetectedClassification.OperatingSystem;
    public DeviceType Type => _classificationOverride?.Type ?? Result.DetectedClassification.Type;
    public DeviceType Icon => _classificationOverride?.Icon ?? Type;
    public string OperatingSystemText => OperatingSystem.Label()
        + (_classificationOverride?.OperatingSystem is null && Result.DetectedClassification.OperatingSystemIsInferred
            ? " (likely)" : string.Empty);
    public string DeviceTypeText => Type.Label()
        + (_classificationOverride?.Type is null && Result.DetectedClassification.TypeIsInferred
            ? " (likely)" : string.Empty);
    public string OperatingSystemSource => _classificationOverride?.OperatingSystem is not null
        ? $"User-selected. Automatic: {Result.DetectedClassification.OperatingSystem.Label()}. {Result.DetectedClassification.OperatingSystemEvidence}"
        : Result.DetectedClassification.OperatingSystemEvidence;
    public string DeviceTypeSource => _classificationOverride?.Type is not null
        ? $"User-selected. Automatic: {Result.DetectedClassification.Type.Label()}. {Result.DetectedClassification.TypeEvidence}"
        : Result.DetectedClassification.TypeEvidence;
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
    public string AddressPrefix { get; }
    public string AddressHost { get; }
    public string MacOui { get; }
    public string MacNic { get; }
    public bool IsOnline => Result.Status == HostStatus.Alive;
    public bool IsOffline => !IsOnline;
    public string StatusLabel => IsOnline ? "Online" : "Offline";
    public double NameOpacity => NameText == Result.AddressText ? 0.65 : 1;
    public double VendorOpacity => Result.VendorText is "Unknown" or "-" ? 0.65 : 1;
    public bool HasLatency => IsOnline && Result.RoundtripTimeMilliseconds is >= 0;
    public string LatencyLabel => HasLatency ? Result.RoundtripText : "-";
    public double LatencyFraction { get; private set; }
    public double LatencyFill => HasLatency ? 20 + (80 * LatencyFraction) : 0;

    public event PropertyChangedEventHandler? PropertyChanged;

    public bool MatchesFilter(string? filter)
    {
        var search = filter?.Trim() ?? string.Empty;
        return NameText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || OperatingSystemText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || DeviceTypeText.Contains(search, StringComparison.OrdinalIgnoreCase)
            || Result.MatchesFilter(filter);
    }

    public void SetClassificationOverride(DeviceClassificationOverride? value)
    {
        _classificationOverride = value;
        foreach (var property in new[]
        {
            nameof(ClassificationOverride), nameof(OperatingSystem), nameof(Type), nameof(Icon),
            nameof(OperatingSystemText), nameof(DeviceTypeText), nameof(OperatingSystemSource),
            nameof(DeviceTypeSource), nameof(IconGlyph), nameof(IconSource)
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

    public void UpdateOpenPorts(IReadOnlyList<OpenPort> openPorts)
    {
        Result = Result with { OpenPorts = openPorts };
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Result)));
    }

    public void UpdateLatencyRange(long minimum, long maximum)
    {
        if (minimum < 0 || maximum < minimum)
        {
            throw new ArgumentOutOfRangeException(nameof(minimum), "Latency bounds must be nonnegative and ordered.");
        }

        var fraction = HasLatency && Result.RoundtripTimeMilliseconds is long latency && maximum > minimum
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
