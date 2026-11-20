using System.Globalization;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private const string ClosedBeforeEvidenceFinished = "FingVibe closed before the deeper diagnostics finished";

    // UI review without a review inventory keeps incidents in memory only, like the inventory itself.
    private readonly NetworkHealthHistoryStore? _networkHealthHistory =
        IsUiReview && string.IsNullOrEmpty(ReviewInventoryPath) ? null : new(InventoryPath);
    private readonly Dictionary<Guid, NetworkIncident> _pendingNetworkIncidents = [];
    private readonly Dictionary<Guid, NetworkIncidentEvidence> _networkIncidentEvidence = [];
    private readonly Dictionary<Guid, NetworkIncidentEvidence> _pendingNetworkEvidence = [];
    private readonly SemaphoreSlim _networkIncidentSaveLock = new(1, 1);
    private string? _networkIncidentStorageMessage;
    private string? _networkIncidentRetentionMessage;
    private string? _networkIncidentViewSignature;

    private async Task LoadNetworkIncidentHistoryAsync()
    {
        try
        {
            var saved = _networkHealthHistory is null ? [] : await _networkHealthHistory.LoadAsync() ?? [];
            var evidence = _networkHealthHistory is null ? [] : await _networkHealthHistory.LoadEvidenceAsync() ?? [];
            foreach (var item in evidence) _networkIncidentEvidence[item.IncidentId] = item;
            QueueNetworkIncidentChanges(_networkIncidents.Load(saved));
            // A saved running record means FingVibe stopped during the check; keep its partial evidence, never rerun it.
            foreach (var running in evidence.Where(item => item.Outcome == NetworkEvidenceOutcome.Running))
                RecordNetworkIncidentEvidence(running.Interrupted(
                    NetworkIncidentDiagnostics.Interrupted(ClosedBeforeEvidenceFinished), running.StartedAt));
            await PruneNetworkIncidentHistoryAsync();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            // Without the saved records, new incidents could contradict them, so lifecycle tracking stays off.
            _networkIncidentEvidence.Clear();
            _networkIncidentStorageMessage =
                $"Saved incident history could not be loaded, so new incidents are not recorded until FingVibe restarts. {exception.Message}";
        }

        UpdateNetworkIncidentPresentation();
    }

    private void QueueNetworkIncidentChanges(IReadOnlyList<NetworkIncident> changed)
    {
        if (changed.Count == 0) return;
        foreach (var incident in changed) _pendingNetworkIncidents[incident.Id] = incident;
        UpdateNetworkIncidentPresentation();
        _ = SaveNetworkIncidentsAsync();
    }

    private void RecordNetworkIncidentEvidence(NetworkIncidentEvidence evidence)
    {
        _networkIncidentEvidence[evidence.IncidentId] = evidence;
        _pendingNetworkEvidence[evidence.IncidentId] = evidence;
        UpdateNetworkIncidentPresentation();
        _ = SaveNetworkIncidentsAsync();
    }

    /// <summary>Retries unsaved incident records, for example after the first inventory save creates the database.</summary>
    private void RetryNetworkIncidentSave()
    {
        if (_pendingNetworkIncidents.Count > 0 || _pendingNetworkEvidence.Count > 0) _ = SaveNetworkIncidentsAsync();
    }

    private async Task SaveNetworkIncidentsAsync()
    {
        await _networkIncidentSaveLock.WaitAsync();
        try
        {
            if (_pendingNetworkIncidents.Count == 0 && _pendingNetworkEvidence.Count == 0) return;
            var batch = _pendingNetworkIncidents.Values.ToList();
            var evidence = _pendingNetworkEvidence.Values.ToList();
            if (_networkHealthHistory is null)
            {
                _pendingNetworkIncidents.Clear();
                _pendingNetworkEvidence.Clear();
                return;
            }

            string? message;
            try
            {
                message = await _networkHealthHistory.SaveAsync(batch, evidence)
                    ? null : NetworkHealthHistoryStore.MissingDatabaseMessage;
                if (message is null)
                {
                    foreach (var incident in batch)
                    {
                        if (_pendingNetworkIncidents.TryGetValue(incident.Id, out var pending) && ReferenceEquals(pending, incident))
                            _pendingNetworkIncidents.Remove(incident.Id);
                    }
                    foreach (var item in evidence)
                    {
                        if (_pendingNetworkEvidence.TryGetValue(item.IncidentId, out var pending) && ReferenceEquals(pending, item))
                            _pendingNetworkEvidence.Remove(item.IncidentId);
                    }
                }
            }
            catch (Exception exception) when (evidence.Count > 0 && exception is InvalidDataException or InvalidOperationException)
            {
                // A rejected evidence record must not block incident lifecycle saves; it stays visible but unsaved.
                foreach (var item in evidence) _pendingNetworkEvidence.Remove(item.IncidentId);
                message = $"Deeper diagnostic evidence could not be saved and is shown only until FingVibe closes. {exception.Message}";
                try
                {
                    if (await _networkHealthHistory.SaveAsync(batch))
                    {
                        foreach (var incident in batch)
                        {
                            if (_pendingNetworkIncidents.TryGetValue(incident.Id, out var pending) && ReferenceEquals(pending, incident))
                                _pendingNetworkIncidents.Remove(incident.Id);
                        }
                    }
                }
                catch (Exception retry) when (retry is IOException or UnauthorizedAccessException
                    or InvalidDataException or InvalidOperationException)
                {
                    message += $" Incident history could not be saved either; unsaved changes are kept and retried after the next change. {retry.Message}";
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                or InvalidDataException or InvalidOperationException)
            {
                message = $"Incident history or evidence could not be saved. Unsaved changes are kept and retried after the next change. {exception.Message}";
            }

            _networkIncidentStorageMessage = message;
            if (message is null && batch.Any(item => item.State == NetworkIncidentState.Recovered))
                await PruneNetworkIncidentHistoryCoreAsync();
            UpdateNetworkIncidentPresentation();
        }
        finally
        {
            _networkIncidentSaveLock.Release();
        }
    }

    private async Task PruneNetworkIncidentHistoryAsync()
    {
        await _networkIncidentSaveLock.WaitAsync();
        try { await PruneNetworkIncidentHistoryCoreAsync(); }
        finally { _networkIncidentSaveLock.Release(); }
    }

    /// <summary>Retention: resolved incidents for 90 days, at most 1,000; never ongoing or recovery-unknown ones.</summary>
    private async Task PruneNetworkIncidentHistoryCoreAsync()
    {
        if (_networkHealthHistory is null) return;
        try
        {
            var removed = await _networkHealthHistory.PruneAsync(DateTimeOffset.UtcNow) ?? [];
            _networkIncidents.Forget(removed);
            foreach (var id in removed)
            {
                _networkIncidentEvidence.Remove(id);
                _pendingNetworkEvidence.Remove(id);
                _pendingNetworkIncidents.Remove(id);
            }
            _networkIncidentRetentionMessage = null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidDataException or InvalidOperationException)
        {
            _networkIncidentRetentionMessage =
                $"Older resolved incidents could not be removed under the 90-day / 1,000-incident retention; they are kept. {exception.Message}";
        }
    }

    private void UpdateNetworkIncidentPresentation()
    {
        if (_periodicScansClosed) return;
        var now = DateTimeOffset.UtcNow;
        var incidents = _networkIncidents.Incidents;
        var rows = NetworkIncidentPresentation.Rows(incidents, _networkIncidentEvidence, now, TimeZoneInfo.Local,
            CultureInfo.CurrentCulture);
        var evidence = incidents.ToDictionary(item => item.Id, item => NetworkIncidentPresentation.Evidence(item,
            _networkIncidentEvidence.GetValueOrDefault(item.Id), now, TimeZoneInfo.Local, CultureInfo.CurrentCulture));
        var summary = NetworkIncidentPresentation.Summary(incidents, now, TimeZoneInfo.Local, CultureInfo.CurrentCulture);
        var message = string.Join(" ", new[] { _networkIncidentStorageMessage, _networkIncidentRetentionMessage }
            .Where(part => part is not null));
        var storage = message.Length == 0 ? null : message;
        var signature = string.Join("\n", new[] { summary, storage ?? "" }
            .Concat(rows.Select(row => row.AccessibleName))
            .Concat(evidence.Values.Select(view => view.Signature)));
        if (signature == _networkIncidentViewSignature) return;
        _networkIncidentViewSignature = signature;
        NetworkPage.ShowIncidentSummary(summary, storage);
        ToolsPage.ShowIncidentHistory(rows, evidence, storage);
    }
}
