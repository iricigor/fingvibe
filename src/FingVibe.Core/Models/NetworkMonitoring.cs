using System.Net;

namespace FingVibe.Core.Models;

public sealed record NetworkMonitorSettings(bool IsEnabled = false)
{
    public static NetworkMonitorSettings Default { get; } = new();
}

public enum NetworkMonitorState
{
    Off,
    Waiting,
    Paused,
    Checking
}

public enum NetworkMonitorTarget
{
    Gateway,
    Cloudflare,
    Google
}

public enum NetworkMonitorDnsSource
{
    WindowsConfiguredOrCached,
    Cloudflare,
    Google
}

public sealed record NetworkMonitorPingSample(
    NetworkMonitorTarget Target,
    int Sequence,
    DateTimeOffset StartedAt,
    DateTimeOffset CompletedAt,
    DiagnosticObservation Observation);

public sealed record NetworkMonitorDnsObservation(
    NetworkMonitorDnsSource Source,
    DateTimeOffset StartedAt,
    DateTimeOffset CompletedAt,
    DiagnosticObservation Observation);

public sealed record NetworkMonitorObservation(
    DateTimeOffset StartedAt,
    DateTimeOffset CompletedAt,
    string? NetworkId,
    IPAddress Gateway,
    IReadOnlyList<NetworkMonitorPingSample> PingSamples,
    IReadOnlyList<NetworkMonitorDnsObservation> DnsObservations,
    bool Cancelled,
    string Detail);

public sealed record NetworkMonitorSnapshot(
    NetworkMonitorState State,
    DateTimeOffset ObservedAt,
    DateTimeOffset? NextCheckAt,
    NetworkMonitorObservation? LastObservation,
    string? Detail);
