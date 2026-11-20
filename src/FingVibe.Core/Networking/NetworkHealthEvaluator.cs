using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public enum NetworkHealthVerdict
{
    Learning,
    Healthy,
    Verifying,
    Problem,
    Uncertain
}

public enum NetworkHealthSymptomKind
{
    HighLatency,
    IcmpUnanswered,
    WindowsDnsFailed
}

public sealed record NetworkHealthSymptom(NetworkHealthSymptomKind Kind, NetworkMonitorTarget? Target, string Description);

/// <param name="ObservedAt">Completion time of the check that produced this assessment.</param>
/// <param name="RecoveryChecks">Consecutive healthy completed checks while a problem is confirmed (0-5).</param>
/// <param name="BaselineChecks">Fewest collected healthy medians across responding targets (0-20).</param>
public sealed record NetworkHealthAssessment(
    NetworkHealthVerdict Verdict,
    DateTimeOffset ObservedAt,
    IReadOnlyList<NetworkHealthSymptom> Symptoms,
    int RecoveryChecks,
    int BaselineChecks,
    IReadOnlyList<string> Notes);

/// <summary>
/// Applies #344's approved detection defaults to completed raw monitor checks. Baselines and streaks are in memory;
/// <see cref="NetworkIncidentTracker"/> persists confirmed problems and recovery progress and restores them with <see cref="Resume"/>.
/// Cancelled, skipped and unobserved checks are ignored, so they neither count toward nor reset any streak.
/// </summary>
public sealed class NetworkHealthEvaluator
{
    public const int BaselineSize = 20;
    public const int ConfirmationChecks = 2;
    public const int RecoveryCheckCount = 5;
    public const double BaselineMultiplier = 3;
    public const double GatewayThresholdMilliseconds = 20;
    public const double ExternalThresholdMilliseconds = 150;
    public const int UnansweredThreshold = 2;
    public static readonly TimeSpan NormalInterval = TimeSpan.FromMinutes(1);
    public static readonly TimeSpan IssueInterval = TimeSpan.FromSeconds(30);

    private readonly object _sync = new();
    private readonly Dictionary<NetworkMonitorTarget, TargetState> _targets = [];
    private readonly Dictionary<SymptomKey, int> _suspicion = [];
    private readonly Dictionary<SymptomKey, NetworkHealthSymptom> _problems = [];
    private string? _context;
    private int _recovery;
    private NetworkHealthAssessment? _current;

    public NetworkHealthAssessment? Current
    {
        get { lock (_sync) return _current; }
    }

    /// <summary>Checks every 30 seconds while verifying or tracking a problem, otherwise every minute.</summary>
    public TimeSpan NextInterval
    {
        get
        {
            lock (_sync)
                return _current?.Verdict is NetworkHealthVerdict.Verifying or NetworkHealthVerdict.Problem
                    ? IssueInterval : NormalInterval;
        }
    }

    /// <summary>Network context of the current in-memory state, or null after a reset.</summary>
    public string? ContextKey
    {
        get { lock (_sync) return _context; }
    }

    public void Reset()
    {
        lock (_sync) ResetState();
    }

    /// <summary>
    /// Restores a persisted confirmed problem and its completed healthy-check count for the same network context,
    /// so recovery resumes counting after a restart, sleep or re-enable instead of starting over. Baselines restart
    /// learning; targets named by unanswered-ICMP symptoms are known to have responded before.
    /// </summary>
    public void Resume(string contextKey, IEnumerable<NetworkHealthSymptom> problems, int recoveryChecks)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(contextKey);
        ArgumentNullException.ThrowIfNull(problems);
        ArgumentOutOfRangeException.ThrowIfNegative(recoveryChecks);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(recoveryChecks, RecoveryCheckCount);
        lock (_sync)
        {
            ResetState();
            _context = contextKey;
            foreach (var symptom in problems)
            {
                _problems[new(symptom.Kind, symptom.Target)] = symptom;
                if (symptom is { Kind: NetworkHealthSymptomKind.IcmpUnanswered, Target: { } target })
                    Target(target).EverResponded = true;
            }
            _recovery = _problems.Count == 0 ? 0 : recoveryChecks;
        }
    }

    /// <param name="contextKey">Selected adapter/network identity; a change starts fresh baselines and streaks.</param>
    /// <param name="ambiguousRoute">More than one active route (VPN/multiple adapters): report uncertain, judge nothing.</param>
    public NetworkHealthAssessment? Evaluate(NetworkMonitorObservation observation, string contextKey, bool ambiguousRoute)
    {
        ArgumentNullException.ThrowIfNull(observation);
        lock (_sync)
        {
            if (!string.Equals(contextKey, _context, StringComparison.Ordinal))
            {
                ResetState();
                _context = contextKey;
            }
            if (observation.Cancelled) return _current;

            var notes = new List<string>();
            var suspicious = new Dictionary<SymptomKey, NetworkHealthSymptom>();
            var medians = new Dictionary<NetworkMonitorTarget, double>();
            var observed = false;
            foreach (var group in observation.PingSamples.GroupBy(sample => sample.Target))
            {
                var samples = group.ToList();
                var responded = samples.Where(sample => sample.Observation.State == DiagnosticState.Responded).ToList();
                var unanswered = samples.Count(sample => sample.Observation.State == DiagnosticState.Unanswered);
                if (responded.Count + unanswered == 0) continue;
                observed = true;
                var target = Target(group.Key);
                var name = TargetName(group.Key, samples[0].Observation.Target);
                var wasResponsive = target.EverResponded;
                if (responded.Count > 0) target.EverResponded = true;
                if (!target.EverResponded)
                {
                    notes.Add($"Limited visibility: {name} has not answered ICMP probes, so it is not treated as an outage.");
                    continue;
                }
                if (wasResponsive && unanswered >= UnansweredThreshold)
                    suspicious[new(NetworkHealthSymptomKind.IcmpUnanswered, group.Key)] = new(
                        NetworkHealthSymptomKind.IcmpUnanswered, group.Key,
                        $"ICMP probes unanswered: {name} ({unanswered} of {samples.Count})");
                var latencies = responded.Select(sample => sample.Observation.RoundtripMilliseconds).OfType<long>()
                    .Select(value => (double)value).ToList();
                if (latencies.Count == 0) continue;
                var median = Median(latencies);
                medians[group.Key] = median;
                var threshold = group.Key == NetworkMonitorTarget.Gateway ? GatewayThresholdMilliseconds : ExternalThresholdMilliseconds;
                var baseline = target.Baseline.Count >= BaselineSize ? Median(target.Baseline) : (double?)null;
                if (median > threshold && (baseline is null || median > BaselineMultiplier * baseline.Value))
                    suspicious[new(NetworkHealthSymptomKind.HighLatency, group.Key)] = new(
                        NetworkHealthSymptomKind.HighLatency, group.Key,
                        $"High latency: {name} {median:0} ms median (limit {threshold:0} ms" +
                        (baseline is { } normal ? $" and 3 x normal {normal:0} ms)" : ")"));
            }

            var dns = observation.DnsObservations.ToDictionary(item => item.Source, item => item.Observation.State);
            if (dns.TryGetValue(NetworkMonitorDnsSource.WindowsConfiguredOrCached, out var windows))
            {
                var publicFailures = dns.Where(item => item.Key != NetworkMonitorDnsSource.WindowsConfiguredOrCached &&
                    item.Value is DiagnosticState.Unanswered or DiagnosticState.Error).Select(item => DnsName(item.Key)).ToList();
                if (windows == DiagnosticState.Responded)
                {
                    observed = true;
                    if (publicFailures.Count > 0)
                        notes.Add($"{string.Join(" and ", publicFailures)} did not answer; public resolvers may be blocked " +
                            "on this network, which does not show a configured DNS failure.");
                }
                else if (windows is DiagnosticState.Unanswered or DiagnosticState.Error)
                {
                    observed = true;
                    suspicious[new(NetworkHealthSymptomKind.WindowsDnsFailed, null)] = new(
                        NetworkHealthSymptomKind.WindowsDnsFailed, null, "Windows DNS did not resolve example.com");
                }
            }
            if (!observed) return _current;

            if (ambiguousRoute)
            {
                notes.Insert(0, "More than one active network route is available, so Windows may send checks through another adapter or VPN.");
                return _current = new(NetworkHealthVerdict.Uncertain, observation.CompletedAt, [.. suspicious.Values],
                    _recovery, BaselineChecks(), notes);
            }

            foreach (var key in _suspicion.Keys.Where(key => !suspicious.ContainsKey(key)).ToList()) _suspicion.Remove(key);
            foreach (var (key, symptom) in suspicious)
            {
                _suspicion[key] = _suspicion.GetValueOrDefault(key) + 1;
                if (_suspicion[key] >= ConfirmationChecks || _problems.ContainsKey(key)) _problems[key] = symptom;
            }
            if (_problems.Count > 0)
            {
                _recovery = suspicious.Count == 0 ? _recovery + 1 : 0;
                if (_recovery >= RecoveryCheckCount)
                {
                    _problems.Clear();
                    _suspicion.Clear();
                    _recovery = 0;
                }
            }

            // Baselines learn only from healthy medians and freeze while their target is suspicious or a problem.
            foreach (var (key, median) in medians)
            {
                if (_suspicion.Keys.Concat(_problems.Keys).Any(symptom => symptom.Target == key)) continue;
                var baseline = Target(key).Baseline;
                baseline.Enqueue(median);
                while (baseline.Count > BaselineSize) baseline.Dequeue();
            }

            var verdict = _problems.Count > 0 ? NetworkHealthVerdict.Problem
                : suspicious.Count > 0 ? NetworkHealthVerdict.Verifying
                : BaselineChecks() < BaselineSize ? NetworkHealthVerdict.Learning
                : NetworkHealthVerdict.Healthy;
            IReadOnlyList<NetworkHealthSymptom> symptoms = verdict == NetworkHealthVerdict.Problem
                ? [.. _problems.Values] : [.. suspicious.Values];
            return _current = new(verdict, observation.CompletedAt, symptoms, _recovery, BaselineChecks(), notes);
        }
    }

    private int BaselineChecks()
    {
        var responsive = _targets.Values.Where(target => target.EverResponded).ToList();
        return responsive.Count == 0 ? 0 : Math.Min(BaselineSize, responsive.Min(target => target.Baseline.Count));
    }

    private TargetState Target(NetworkMonitorTarget target)
    {
        if (!_targets.TryGetValue(target, out var state)) _targets[target] = state = new();
        return state;
    }

    private void ResetState()
    {
        _targets.Clear();
        _suspicion.Clear();
        _problems.Clear();
        _recovery = 0;
        _current = null;
        _context = null;
    }

    private static double Median(IEnumerable<double> values)
    {
        var sorted = values.Order().ToArray();
        var middle = sorted.Length / 2;
        return sorted.Length % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
    }

    private static string TargetName(NetworkMonitorTarget target, string address) => target switch
    {
        NetworkMonitorTarget.Gateway => $"gateway {address}",
        NetworkMonitorTarget.Cloudflare => $"Cloudflare {address}",
        _ => $"Google {address}"
    };

    private static string DnsName(NetworkMonitorDnsSource source) =>
        source == NetworkMonitorDnsSource.Cloudflare ? "Cloudflare DNS" : "Google DNS";

    private sealed class TargetState
    {
        public bool EverResponded { get; set; }
        public Queue<double> Baseline { get; } = new();
    }

    private readonly record struct SymptomKey(NetworkHealthSymptomKind Kind, NetworkMonitorTarget? Target);
}
