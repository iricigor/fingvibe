using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

/// <param name="Assessment">The evaluator's current verdict after the check.</param>
/// <param name="Changed">Incidents whose saved record must be written.</param>
public sealed record NetworkIncidentUpdate(NetworkHealthAssessment? Assessment, IReadOnlyList<NetworkIncident> Changed);

/// <summary>
/// Owns incident lifecycle identity on top of <see cref="NetworkHealthEvaluator"/>: one active incident per network
/// context, accumulated symptoms, observation gaps, recovery progress and a new incident only after confirmed recovery.
/// Callers persist <see cref="NetworkIncidentUpdate.Changed"/>; nothing here performs I/O or sends probes.
/// </summary>
public sealed class NetworkIncidentTracker(NetworkHealthEvaluator evaluator)
{
    private readonly object _sync = new();
    private readonly List<NetworkIncident> _incidents = [];
    private readonly Dictionary<string, DateTimeOffset> _firstSuspicious = new(StringComparer.Ordinal);
    private bool _loaded;

    public NetworkHealthEvaluator Evaluator { get; } = evaluator ?? throw new ArgumentNullException(nameof(evaluator));

    /// <summary>Lifecycle tracking starts once saved history has been loaded; verdicts work before that.</summary>
    public bool IsLoaded
    {
        get { lock (_sync) return _loaded; }
    }

    /// <summary>Newest first.</summary>
    public IReadOnlyList<NetworkIncident> Incidents
    {
        get { lock (_sync) return [.. _incidents]; }
    }

    /// <summary>
    /// Loads saved history. Incidents that were still observed when the app last stopped become recovery unknown,
    /// with an app-closed gap from their last observation: the app being closed is not evidence of recovery.
    /// </summary>
    public IReadOnlyList<NetworkIncident> Load(IEnumerable<NetworkIncident> saved)
    {
        ArgumentNullException.ThrowIfNull(saved);
        lock (_sync)
        {
            var incidents = saved.ToList();
            if (incidents.Where(item => item.IsActive).GroupBy(item => item.ContextKey, StringComparer.Ordinal)
                .Any(group => group.Count() > 1))
                throw new InvalidDataException("Saved incident history has more than one active incident for a network.");
            _incidents.Clear();
            _firstSuspicious.Clear();
            var changed = new List<NetworkIncident>();
            foreach (var incident in incidents)
            {
                var current = incident;
                if (current.State == NetworkIncidentState.Ongoing)
                    changed.Add(current = OpenGap(current, NetworkObservationGapReason.AppClosed, current.LastObservedAt));
                _incidents.Add(current);
            }
            Sort();
            // Verdicts computed before loading know nothing of saved problems; the next check resumes from them.
            Evaluator.Reset();
            _loaded = true;
            return changed;
        }
    }

    public NetworkIncidentUpdate Evaluate(
        NetworkMonitorObservation observation, string contextKey, string networkLabel, bool ambiguousRoute)
    {
        ArgumentNullException.ThrowIfNull(observation);
        ArgumentException.ThrowIfNullOrWhiteSpace(contextKey);
        lock (_sync)
        {
            if (!_loaded) return new(Evaluator.Evaluate(observation, contextKey, ambiguousRoute), []);
            var changed = ContextChangedCore(contextKey, observation.StartedAt);
            var active = Active(contextKey);
            if (active is not null && Evaluator.ContextKey != contextKey)
                Evaluator.Resume(contextKey, active.Symptoms.Select(symptom =>
                    new NetworkHealthSymptom(symptom.Kind, symptom.Target, symptom.Description)), active.RecoveryChecks);
            var before = Evaluator.Current;
            var assessment = Evaluator.Evaluate(observation, contextKey, ambiguousRoute);
            // Cancelled and unobserved checks return the previous verdict; uncertain routes judge nothing.
            if (assessment is null || ReferenceEquals(assessment, before) || assessment.Verdict == NetworkHealthVerdict.Uncertain)
                return new(assessment, changed);

            var at = assessment.ObservedAt;
            if (assessment.Verdict == NetworkHealthVerdict.Problem)
            {
                NetworkIncident incident;
                if (active is null)
                {
                    var first = _firstSuspicious.Remove(contextKey, out var suspicious) && suspicious <= at ? suspicious : at;
                    incident = new NetworkIncident(Guid.NewGuid(), contextKey, networkLabel, first, at)
                    {
                        Symptoms = Merge([], assessment.Symptoms, at),
                        LastObservedAt = at,
                        RecoveryChecks = assessment.RecoveryChecks
                    };
                }
                else
                {
                    incident = active with
                    {
                        State = NetworkIncidentState.Ongoing,
                        NetworkLabel = networkLabel,
                        Symptoms = Merge(active.Symptoms, assessment.Symptoms, at),
                        LastObservedAt = at,
                        RecoveryChecks = assessment.RecoveryChecks,
                        // A completed unhealthy check restarts recovery, so earlier gaps no longer hide its timing.
                        GapSinceLastProblem = assessment.RecoveryChecks != 0 && active.GapSinceLastProblem,
                        Gaps = CloseGaps(active.Gaps, at)
                    };
                }
                changed.Add(Store(incident));
            }
            else if (active is not null)
            {
                // The evaluator only clears a restored or confirmed problem after five consecutive healthy checks.
                changed.Add(Store(active with
                {
                    State = NetworkIncidentState.Recovered,
                    LastObservedAt = at,
                    RecoveredAt = at,
                    RecoveryChecks = 0,
                    RecoveryTimeUncertain = active.GapSinceLastProblem || active.Gaps.Any(gap => gap.EndedAt is null),
                    GapSinceLastProblem = false,
                    Gaps = CloseGaps(active.Gaps, at)
                }));
                _firstSuspicious.Remove(contextKey);
            }
            else if (assessment.Verdict == NetworkHealthVerdict.Verifying)
            {
                _firstSuspicious.TryAdd(contextKey, at);
            }
            else
            {
                _firstSuspicious.Remove(contextKey);
            }
            return new(assessment, changed);
        }
    }

    /// <summary>Sleep or monitoring off: observed incidents become recovery unknown until observation resumes.</summary>
    public IReadOnlyList<NetworkIncident> BeginGap(NetworkObservationGapReason reason, DateTimeOffset at)
    {
        lock (_sync)
        {
            if (!_loaded) return [];
            return _incidents.Where(item => item.State == NetworkIncidentState.Ongoing).ToList()
                .Select(item => Store(OpenGap(item, reason, at))).ToList();
        }
    }

    /// <summary>A different selected network leaves incidents on other contexts unobserved.</summary>
    public IReadOnlyList<NetworkIncident> ContextChanged(string? contextKey, DateTimeOffset at)
    {
        lock (_sync) return _loaded ? ContextChangedCore(contextKey, at) : [];
    }

    private List<NetworkIncident> ContextChangedCore(string? contextKey, DateTimeOffset at)
    {
        foreach (var key in _firstSuspicious.Keys.Where(key => key != contextKey).ToList()) _firstSuspicious.Remove(key);
        return _incidents.Where(item => item.State == NetworkIncidentState.Ongoing &&
                !string.Equals(item.ContextKey, contextKey, StringComparison.Ordinal)).ToList()
            .Select(item => Store(OpenGap(item, NetworkObservationGapReason.NetworkChanged, at))).ToList();
    }

    private NetworkIncident? Active(string contextKey) =>
        _incidents.FirstOrDefault(item => item.IsActive && string.Equals(item.ContextKey, contextKey, StringComparison.Ordinal));

    private NetworkIncident Store(NetworkIncident incident)
    {
        var index = _incidents.FindIndex(item => item.Id == incident.Id);
        if (index < 0) _incidents.Add(incident);
        else _incidents[index] = incident;
        Sort();
        return incident;
    }

    private void Sort() => _incidents.Sort((left, right) =>
    {
        var order = right.FirstObservedAt.CompareTo(left.FirstObservedAt);
        return order != 0 ? order : right.ConfirmedAt.CompareTo(left.ConfirmedAt);
    });

    private static NetworkIncident OpenGap(NetworkIncident incident, NetworkObservationGapReason reason, DateTimeOffset at)
    {
        var start = at < incident.LastObservedAt ? incident.LastObservedAt : at;
        return incident with
        {
            State = NetworkIncidentState.RecoveryUnknown,
            GapSinceLastProblem = true,
            Gaps = [.. incident.Gaps, new NetworkObservationGap(Guid.NewGuid(), reason, start, null)]
        };
    }

    private static IReadOnlyList<NetworkObservationGap> CloseGaps(IReadOnlyList<NetworkObservationGap> gaps, DateTimeOffset at) =>
        gaps.Any(gap => gap.EndedAt is null)
            ? gaps.Select(gap => gap.EndedAt is null ? gap with { EndedAt = at < gap.StartedAt ? gap.StartedAt : at } : gap).ToList()
            : gaps;

    private static IReadOnlyList<NetworkIncidentSymptom> Merge(
        IReadOnlyList<NetworkIncidentSymptom> existing, IReadOnlyList<NetworkHealthSymptom> current, DateTimeOffset at)
    {
        var merged = existing.ToList();
        foreach (var symptom in current)
        {
            var index = merged.FindIndex(item => item.Kind == symptom.Kind && item.Target == symptom.Target);
            if (index < 0) merged.Add(new(symptom.Kind, symptom.Target, symptom.Description, at));
            else merged[index] = merged[index] with { Description = symptom.Description };
        }
        return merged;
    }
}
