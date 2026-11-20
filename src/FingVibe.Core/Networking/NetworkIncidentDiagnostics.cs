using System.Net.NetworkInformation;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

/// <summary>
/// Runs the existing manual diagnostic flow once for a confirmed incident, bounded to 45 seconds. Completed checks are
/// kept when the run is stopped early; the caller saves the result and never restarts it automatically.
/// </summary>
public sealed class NetworkIncidentDiagnostics(NetworkDiagnosticService service, TimeProvider? timeProvider = null)
{
    public static readonly TimeSpan Limit = TimeSpan.FromSeconds(45);

    public const string LimitReason =
        "Stopped at the 45-second limit for automatic deeper diagnostics. Completed checks were saved; it is not retried automatically.";

    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;

    /// <summary>Starts a Running record for the incident, before any probe is sent.</summary>
    public NetworkIncidentEvidence Begin(NetworkIncident incident) =>
        new(incident.Id, incident.ContextKey, incident.NetworkLabel, _time.GetUtcNow());

    /// <param name="interruptionReason">Explains why <paramref name="stop"/> was cancelled (manual work, monitoring off, sleep).</param>
    /// <param name="progress">Receives each completed or updated checkpoint while the run is in progress.</param>
    public async Task<NetworkIncidentEvidence> RunAsync(
        NetworkIncidentEvidence started, LanNetwork? network, Func<string> interruptionReason, CancellationToken stop,
        Action<NetworkIncidentEvidence>? progress = null)
    {
        ArgumentNullException.ThrowIfNull(started);
        ArgumentNullException.ThrowIfNull(interruptionReason);
        using var limit = new CancellationTokenSource(Limit, _time);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(stop, limit.Token);
        var observations = new Dictionary<DiagnosticCheckpoint, DiagnosticObservation>();
        var hops = new List<TraceHop>();
        var sync = new object();
        void Report()
        {
            if (progress is null) return;
            NetworkIncidentEvidence snapshot;
            lock (sync) snapshot = started with { Observations = [.. observations.Values], Hops = [.. hops] };
            progress(snapshot);
        }

        try
        {
            // No LAN peer is probed automatically: the monitoring disclosure covers the gateway, public targets,
            // DNS and the traceroute, not other devices. The optional router WAN is a manual-run input.
            var report = await service.RunAsync(network, null,
                new Immediate<DiagnosticObservation>(item => { lock (sync) observations[item.Checkpoint] = item; Report(); }),
                linked.Token,
                new Immediate<TraceHop>(hop => { lock (sync) hops.Add(hop); Report(); })).ConfigureAwait(false);
            var summary = NetworkDiagnosticInterpreter.Summarize(network, report);
            var outcome = report.Cancelled ? NetworkEvidenceOutcome.Partial : NetworkEvidenceOutcome.Complete;
            var detail = !report.Cancelled ? ""
                : stop.IsCancellationRequested ? Interrupted(interruptionReason())
                : LimitReason;
            return started with
            {
                Outcome = outcome,
                CompletedAt = Completed(started),
                Detail = detail,
                Observations = report.Observations,
                Hops = report.Hops,
                TraceComplete = report.TraceComplete,
                SummaryKind = summary.Kind,
                SummaryStatus = summary.Status,
                SummaryExplanation = summary.Explanation
            };
        }
        catch (Exception exception) when (exception is InvalidOperationException or NetworkInformationException
            or System.Net.Sockets.SocketException or OperationCanceledException)
        {
            List<DiagnosticObservation> kept;
            lock (sync)
                kept = observations.Values.Select(item => item.State is DiagnosticState.Running or DiagnosticState.Untested
                    ? item with { State = DiagnosticState.Error, Detail = "Run stopped by a diagnostic error." } : item).ToList();
            var cancelled = exception is OperationCanceledException;
            return started with
            {
                Outcome = cancelled ? NetworkEvidenceOutcome.Partial : NetworkEvidenceOutcome.Failed,
                CompletedAt = Completed(started),
                Detail = cancelled
                    ? stop.IsCancellationRequested ? Interrupted(interruptionReason()) : LimitReason
                    : $"Deeper diagnostics failed: {exception.Message} Completed checks were saved; it is not retried automatically.",
                Observations = kept,
                Hops = [.. hops]
            };
        }
    }

    // A backward clock step during the run must not produce evidence that ends before it started.
    private DateTimeOffset Completed(NetworkIncidentEvidence started)
    {
        var now = _time.GetUtcNow();
        return now < started.StartedAt ? started.StartedAt : now;
    }

    public static string Interrupted(string reason) =>
        $"Interrupted because {reason}. Completed checks were saved; it is not retried automatically.";

    private sealed class Immediate<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
