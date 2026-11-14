using System.Diagnostics;
using FingVibe.Core.Storage;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private InventoryBackupStore? _backupStore;
    private InventoryBackupScheduler? _backupScheduler;
    private string? _backupError;

    private void InitializeBackups()
    {
        if (!IsUiReview || !string.IsNullOrEmpty(ReviewInventoryPath))
        {
            _backupStore = new InventoryBackupStore(InventoryPath);
            _backupScheduler = new InventoryBackupScheduler(async cancellationToken =>
            {
                if (IsUiReview && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_BACKUP_HOLD") is { Length: > 0 } hold)
                    await DeviceActivityReviewHold.WaitAsync(hold, cancellationToken, "backup");
                return await _backupStore.CreateAsync(cancellationToken);
            });
            _backupScheduler.Changed += (_, _) => DispatcherQueue.TryEnqueue(() =>
            {
                ReportBackupError(_backupScheduler.Status.Error);
                ToolsPage.RefreshBackups();
            });
        }
        ToolsPage.ConfigureBackups(_backupStore, _backupScheduler, ReportBackupError);
        Closed += (_, _) => _backupScheduler?.Dispose();
    }

    private void ScheduleStartupBackup()
    {
        if (_backupScheduler is null || _inventoryUnavailable) return;
        if (_inventory.Revision == Guid.Empty) _backupScheduler.SetMissing();
        else _backupScheduler.Schedule();
    }

    private void ReportBackupError(string? error)
    {
        _backupError = error;
        if (error is not null) Debug.WriteLine(error);
        UpdateScanStatus();
    }
}
