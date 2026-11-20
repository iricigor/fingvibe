using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly NetworkIncidentDiagnostics _incidentDiagnostics = new(new NetworkDiagnosticService(
        IsUiReview ? NetworkMonitorReviewFixture.DiagnosticProbes : new NetworkDiagnosticProbes()));
    private (NetworkIncident Incident, LanNetwork Network)? _pendingIncidentDiagnostics;
    private CancellationTokenSource? _incidentDiagnosticsCancellation;
    private Task _incidentDiagnosticsTask = Task.CompletedTask;
    private NetworkIncidentEvidence? _incidentDiagnosticsLatest;
    private string? _incidentDiagnosticsStopReason;

    /// <summary>Runs after the monitor check releases its activity lease, so the deeper check can acquire its own.</summary>
    private void QueueIncidentDiagnostics(NetworkIncident incident, LanNetwork network)
    {
        _pendingIncidentDiagnostics = (incident, network);
        DispatcherQueue.TryEnqueue(StartPendingIncidentDiagnostics);
    }

    private void StartPendingIncidentDiagnostics()
    {
        if (_pendingIncidentDiagnostics is not { } pending || _periodicScansClosed) return;
        _pendingIncidentDiagnostics = null;
        var started = _incidentDiagnostics.Begin(pending.Incident);
        if (_incidentDiagnosticsCancellation is not null)
        {
            RecordNetworkIncidentEvidence(NotRun(started, "another automatic deeper check was still running"));
            return;
        }

        var cancellation = new CancellationTokenSource();
        // Automatic deeper checks use the preemptible background lease: user-requested work cancels them.
        if (!_networkActivityCoordinator.TryAcquireBackground(
                NetworkActivityKind.NetworkHealthMonitor, cancellation, out var lease))
        {
            cancellation.Dispose();
            RecordNetworkIncidentEvidence(NotRun(started,
                $"{NetworkMonitorPresentation.ActivityName(_networkActivityCoordinator.ActiveKind)} was in progress"));
            return;
        }

        _incidentDiagnosticsCancellation = cancellation;
        _incidentDiagnosticsStopReason = null;
        _incidentDiagnosticsLatest = started;
        RecordNetworkIncidentEvidence(started);
        _incidentDiagnosticsTask = RunIncidentDiagnosticsAsync(started, pending.Network, lease!, cancellation);
    }

    private async Task RunIncidentDiagnosticsAsync(NetworkIncidentEvidence started, LanNetwork network, IDisposable lease,
        CancellationTokenSource cancellation)
    {
        NetworkIncidentEvidence evidence;
        using (lease)
        {
            evidence = await _incidentDiagnostics.RunAsync(started, network,
                () => _incidentDiagnosticsStopReason ?? "user-requested network activity took priority",
                cancellation.Token, snapshot => _incidentDiagnosticsLatest = snapshot).ConfigureAwait(true);
        }

        _incidentDiagnosticsCancellation = null;
        _incidentDiagnosticsLatest = null;
        cancellation.Dispose();
        if (!_periodicScansClosed) RecordNetworkIncidentEvidence(evidence);
    }

    /// <summary>Cancels and awaits an automatic deeper check; its completed checks are saved as partial evidence.</summary>
    private async Task StopIncidentDiagnosticsAsync(string reason)
    {
        _pendingIncidentDiagnostics = null;
        if (_incidentDiagnosticsCancellation is not { } cancellation) return;
        _incidentDiagnosticsStopReason = reason;
        try { cancellation.Cancel(); }
        catch (ObjectDisposedException) { }
        await _incidentDiagnosticsTask;
    }

    /// <summary>On window close there is no time to await probes; save the partial evidence collected so far.</summary>
    private void StopIncidentDiagnosticsForClose()
    {
        _pendingIncidentDiagnostics = null;
        if (_incidentDiagnosticsCancellation is not { } cancellation || _incidentDiagnosticsLatest is not { } latest) return;
        _incidentDiagnosticsStopReason = ClosedBeforeEvidenceFinished;
        try { cancellation.Cancel(); }
        catch (ObjectDisposedException) { }
        _pendingNetworkEvidence[latest.IncidentId] = latest.Interrupted(
            NetworkIncidentDiagnostics.Interrupted(ClosedBeforeEvidenceFinished), DateTimeOffset.UtcNow);
        _ = SaveNetworkIncidentsAsync();
    }

    private static NetworkIncidentEvidence NotRun(NetworkIncidentEvidence started, string reason) => started with
    {
        Outcome = NetworkEvidenceOutcome.NotRun,
        CompletedAt = started.StartedAt,
        Detail = $"Not run because {reason}. User-requested work has priority, and deeper diagnostics are not retried automatically."
    };
}
