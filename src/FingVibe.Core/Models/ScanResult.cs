using System.Net;
using System.Net.NetworkInformation;

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
    IReadOnlyList<OpenPort>? OpenPorts = null)
{
    public string AddressText => Address.ToString();

    public string NameText => string.IsNullOrWhiteSpace(DeviceName) ? AddressText : DeviceName;

    public string StatusText => Status == HostStatus.Alive ? "Alive" : "Unreachable";

    public string RoundtripText => RoundtripTimeMilliseconds is long milliseconds
        ? $"{milliseconds} ms"
        : "-";

    public string VendorText => Status == HostStatus.Alive ? VendorName : "-";

    public IReadOnlyList<OpenPort> OpenPortItems => OpenPorts ?? [];
}

public sealed record OpenPort(int Port, string ServiceName)
{
    public string AccessibleLabel => $"{Port} {ServiceName}";
}

public readonly record struct ScanProgress(int Completed, int Total);

public readonly record struct ScanSummary(int Total, int Alive, int Unreachable);
