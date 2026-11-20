using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public enum NetworkEvidenceOutcome
{
    /// <summary>Started and not yet finished; a saved Running record means FingVibe stopped before it finished.</summary>
    Running,
    Complete,
    /// <summary>Stopped early (45-second limit or interruption); completed checks are kept.</summary>
    Partial,
    /// <summary>Not started because other network work was active; never retried automatically.</summary>
    NotRun,
    Failed
}

/// <summary>
/// Deeper diagnostic evidence collected once, automatically, for one confirmed incident. Saved history only: it records
/// the network context and observation times and is never a current health result.
/// </summary>
public sealed record NetworkIncidentEvidence(
    Guid IncidentId,
    string ContextKey,
    string NetworkLabel,
    DateTimeOffset StartedAt)
{
    public NetworkEvidenceOutcome Outcome { get; init; } = NetworkEvidenceOutcome.Running;
    public DateTimeOffset? CompletedAt { get; init; }
    /// <summary>Why the run stopped early, failed or did not run.</summary>
    public string Detail { get; init; } = "";
    public IReadOnlyList<DiagnosticObservation> Observations { get; init; } = [];
    public IReadOnlyList<TraceHop> Hops { get; init; } = [];
    public bool TraceComplete { get; init; }
    public DiagnosticSummaryKind SummaryKind { get; init; } = DiagnosticSummaryKind.Neutral;
    public string SummaryStatus { get; init; } = "";
    public string SummaryExplanation { get; init; } = "";

    /// <summary>A saved Running record outlived its run, so FingVibe closed before the deeper check finished.</summary>
    public NetworkIncidentEvidence Interrupted(string reason, DateTimeOffset at) => this with
    {
        Outcome = NetworkEvidenceOutcome.Partial,
        CompletedAt = CompletedAt ?? (at < StartedAt ? StartedAt : at),
        Detail = reason,
        Observations = Observations.Select(item => item.State is DiagnosticState.Running or DiagnosticState.Untested
            ? item with { State = DiagnosticState.Cancelled, Detail = "Cancelled; no response inferred." } : item).ToList()
    };
}
