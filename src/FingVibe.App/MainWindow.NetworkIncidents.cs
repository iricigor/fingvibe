using System.Globalization;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    // UI review without a review inventory keeps incidents in memory only, like the inventory itself.
    private readonly NetworkHealthHistoryStore? _networkHealthHistory =
        IsUiReview && string.IsNullOrEmpty(ReviewInventoryPath) ? null : new(InventoryPath);
    private readonly Dictionary<Guid, NetworkIncident> _pendingNetworkIncidents = [];
    private readonly SemaphoreSlim _networkIncidentSaveLock = new(1, 1);
    private string? _networkIncidentStorageMessage;
    private string? _networkIncidentViewSignature;

    private async Task LoadNetworkIncidentHistoryAsync()
    {
        try
        {
            var saved = _networkHealthHistory is null ? [] : await _networkHealthHistory.LoadAsync() ?? [];
            QueueNetworkIncidentChanges(_networkIncidents.Load(saved));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            // Without the saved records, new incidents could contradict them, so lifecycle tracking stays off.
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

    /// <summary>Retries unsaved incident records, for example after the first inventory save creates the database.</summary>
    private void RetryNetworkIncidentSave()
    {
        if (_pendingNetworkIncidents.Count > 0) _ = SaveNetworkIncidentsAsync();
    }

    private async Task SaveNetworkIncidentsAsync()
    {
        await _networkIncidentSaveLock.WaitAsync();
        try
        {
            if (_pendingNetworkIncidents.Count == 0) return;
            var batch = _pendingNetworkIncidents.Values.ToList();
            if (_networkHealthHistory is null)
            {
                _pendingNetworkIncidents.Clear();
                return;
            }

            string? message;
            try
            {
                message = await _networkHealthHistory.SaveAsync(batch) ? null : NetworkHealthHistoryStore.MissingDatabaseMessage;
                if (message is null)
                {
                    foreach (var incident in batch)
                    {
                        if (_pendingNetworkIncidents.TryGetValue(incident.Id, out var pending) && ReferenceEquals(pending, incident))
                            _pendingNetworkIncidents.Remove(incident.Id);
                    }
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                or InvalidDataException or InvalidOperationException)
            {
                message = $"Incident history could not be saved. Unsaved changes are kept and retried after the next change. {exception.Message}";
            }

            _networkIncidentStorageMessage = message;
            UpdateNetworkIncidentPresentation();
        }
        finally
        {
            _networkIncidentSaveLock.Release();
        }
    }

    private void UpdateNetworkIncidentPresentation()
    {
        if (_periodicScansClosed) return;
        var now = DateTimeOffset.UtcNow;
        var incidents = _networkIncidents.Incidents;
        var rows = NetworkIncidentPresentation.Rows(incidents, now, TimeZoneInfo.Local, CultureInfo.CurrentCulture);
        var summary = NetworkIncidentPresentation.Summary(incidents, now, TimeZoneInfo.Local, CultureInfo.CurrentCulture);
        var signature = string.Join("\n", new[] { summary, _networkIncidentStorageMessage ?? "" }
            .Concat(rows.Select(row => row.AccessibleName)));
        if (signature == _networkIncidentViewSignature) return;
        _networkIncidentViewSignature = signature;
        NetworkPage.ShowIncidentSummary(summary, _networkIncidentStorageMessage);
        ToolsPage.ShowIncidentHistory(rows, _networkIncidentStorageMessage);
    }
}
