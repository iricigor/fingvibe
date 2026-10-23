using System.ComponentModel;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed class ScanResultRow : INotifyPropertyChanged
{
    private string? _customName;

    public ScanResultRow(ScanResult result, int prefixLength, string? customName = null)
    {
        if (prefixLength is < 0 or > 32)
        {
            throw new ArgumentOutOfRangeException(nameof(prefixLength));
        }

        Result = result;
        _customName = string.IsNullOrWhiteSpace(customName) ? null : customName.Trim();
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
