using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Serialization;

namespace FingVibe.Core.Models;

public enum HostStatus
{
    Alive,
    Unreachable
}

public sealed record ScanResult(
    IPAddress Address,
    HostStatus Status,
    long? RoundtripTimeMilliseconds,
    TimeSpan ProbeDuration,
    string? DeviceName = null,
    PhysicalAddress? MacAddress = null,
    string VendorName = "Unknown",
    IReadOnlyList<OpenPort>? OpenPorts = null,
    DeviceClassification? Classification = null,
    IReadOnlyList<UdpServiceObservation>? UdpObservations = null)
{
    public DeviceClassification DetectedClassification => Classification ?? DeviceClassification.Unknown;
    public string AddressText => Address.ToString();

    public string NameText => string.IsNullOrWhiteSpace(DeviceName) ? AddressText : DeviceName;

    public string StatusText => Status == HostStatus.Alive ? "Alive" : "Unreachable";

    public string RoundtripText => RoundtripTimeMilliseconds is long milliseconds
        ? $"{milliseconds} ms"
        : "-";

    public string VendorText => Status == HostStatus.Alive ? VendorName : "-";

    public IReadOnlyList<OpenPort> OpenPortItems => OpenPorts ?? [];
    public IReadOnlyList<UdpServiceObservation> UdpObservationItems => UdpObservations ?? [];

    public string MacAddressText => MacAddress is null
        ? "-"
        : string.Join("-", MacAddress.GetAddressBytes().Select(value => value.ToString("X2")));

    public bool MatchesFilter(string? filter)
    {
        if (string.IsNullOrWhiteSpace(filter))
        {
            return true;
        }

        var searchText = filter.Trim();
        return NameText.Contains(searchText, StringComparison.OrdinalIgnoreCase)
            || AddressText.Contains(searchText, StringComparison.OrdinalIgnoreCase)
            || VendorText.Contains(searchText, StringComparison.OrdinalIgnoreCase)
            || DetectedClassification.OperatingSystem.Label().Contains(searchText, StringComparison.OrdinalIgnoreCase)
            || DetectedClassification.Type.Label().Contains(searchText, StringComparison.OrdinalIgnoreCase)
            || OpenPortItems.Any(port =>
                port.AccessibleLabel.Contains(searchText, StringComparison.OrdinalIgnoreCase))
            || StatusText.Contains(searchText, StringComparison.OrdinalIgnoreCase)
            || RoundtripText.Contains(searchText, StringComparison.OrdinalIgnoreCase)
            || MacAddressText.Contains(searchText, StringComparison.OrdinalIgnoreCase);
    }
}

public enum EndpointProtocol
{
    Tcp,
    Udp
}

public sealed record OpenPort(int Port, string ServiceName, EndpointProtocol Protocol = EndpointProtocol.Tcp)
{
    [JsonIgnore]
    public (EndpointProtocol Protocol, int Port) Identity => (Protocol, Port);
    public string AccessibleLabel => $"{Port}/{Protocol.ToString().ToUpperInvariant()} - {ServiceName}";
}

public enum UdpServiceState
{
    Responded,
    NoResponse,
    Error
}

public sealed record UdpServiceObservation(int Port, string ServiceName, UdpServiceState State, string Detail)
{
    public string AccessibleLabel => $"{Port}/UDP - {ServiceName}: {State switch
    {
        UdpServiceState.Responded => "Responded",
        UdpServiceState.NoResponse => "No response - inconclusive",
        _ => "Error"
    }}. {Detail}";
}

public readonly record struct ScanProgress(int Completed, int Total);

public readonly record struct ScanSummary(int Total, int Alive, int Unreachable);
