using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public enum NetworkIncidentState
{
    /// <summary>Confirmed and still observed by monitoring on its network context.</summary>
    Ongoing,
    /// <summary>Five consecutive completed healthy checks observed recovery.</summary>
    Recovered,
    /// <summary>Not observed since an observation gap began, so whether or when it recovered is unknown.</summary>
    RecoveryUnknown
}

public enum NetworkObservationGapReason
{
    AppClosed,
    Sleep,
    MonitoringOff,
    NetworkChanged
}

/// <param name="ConfirmedAt">When this symptom was first part of the confirmed incident.</param>
public sealed record NetworkIncidentSymptom(
    NetworkHealthSymptomKind Kind,
    NetworkMonitorTarget? Target,
    string Description,
    DateTimeOffset ConfirmedAt);

/// <summary>A period without observations. It is not evidence of continuity or of the exact recovery time.</summary>
public sealed record NetworkObservationGap(
    Guid Id,
    NetworkObservationGapReason Reason,
    DateTimeOffset StartedAt,
    DateTimeOffset? EndedAt);

/// <summary>One confirmed problem on one network context, accumulating symptoms until recovery is confirmed.</summary>
/// <param name="FirstObservedAt">Completion time of the first suspicious check that led to confirmation.</param>
/// <param name="ConfirmedAt">Completion time of the check that confirmed the incident.</param>
public sealed record NetworkIncident(
    Guid Id,
    string ContextKey,
    string NetworkLabel,
    DateTimeOffset FirstObservedAt,
    DateTimeOffset ConfirmedAt)
{
    public NetworkIncidentState State { get; init; } = NetworkIncidentState.Ongoing;
    public IReadOnlyList<NetworkIncidentSymptom> Symptoms { get; init; } = [];
    /// <summary>Completion time of the latest check observed for this incident.</summary>
    public DateTimeOffset LastObservedAt { get; init; }
    /// <summary>Persisted recovery progress: completed healthy checks in a row while active (0-4).</summary>
    public int RecoveryChecks { get; init; }
    /// <summary>An observation gap began after the latest completed unhealthy check.</summary>
    public bool GapSinceLastProblem { get; init; }
    /// <summary>When the fifth consecutive healthy check completed; recovery happened at or before this time.</summary>
    public DateTimeOffset? RecoveredAt { get; init; }
    /// <summary>An observation gap means the exact recovery time is unknown.</summary>
    public bool RecoveryTimeUncertain { get; init; }
    public IReadOnlyList<NetworkObservationGap> Gaps { get; init; } = [];

    public bool IsActive => State != NetworkIncidentState.Recovered;
}
