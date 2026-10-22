using System.Net;

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
    string? MacAddress,
    TimeSpan ProbeDuration)
{
    public string AddressText => Address.ToString();

    public string StatusText => Status == HostStatus.Alive ? "Alive" : "Unreachable";

    public string RoundtripText => RoundtripTimeMilliseconds is long milliseconds
        ? $"{milliseconds} ms"
        : "-";

    public string MacAddressText => MacAddress ?? "-";
}

public readonly record struct ScanProgress(int Completed, int Total);

public readonly record struct ScanSummary(int Total, int Alive, int Unreachable);
