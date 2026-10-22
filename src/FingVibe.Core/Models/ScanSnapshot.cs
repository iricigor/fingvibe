namespace FingVibe.Core.Models;

public sealed record ScanSnapshot(
    string Subnet,
    DateTimeOffset CompletedAt,
    IReadOnlyList<ScanResult> Results);
