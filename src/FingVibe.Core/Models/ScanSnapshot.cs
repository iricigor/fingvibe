namespace FingVibe.Core.Models;

public enum ScanCheckpointState
{
    Complete,
    Pending,
    Incomplete
}

public sealed record ScanSnapshot(
    string Subnet,
    DateTimeOffset CompletedAt,
    IReadOnlyList<ScanResult> Results,
    TimeSpan? Duration = null)
{
    public Guid ScanId { get; init; }
    public ScanCheckpointState State { get; init; }
    public string? NetworkId { get; init; }
}
