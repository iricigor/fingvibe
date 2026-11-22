using FingVibe.Core.Updates;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private ReleaseUpdateSession? _updates;
    private ReleaseUpdateActions? _updateActions;
    private ReleaseUpdateCloseScheduler? _updateCloseScheduler;
    private DispatcherTimer? _updateTimer;
    private HttpClient? _updateHttp;

    private void InitializeUpdates()
    {
        var fixturePath = Environment.GetEnvironmentVariable("FINGVIBE_UPDATE_REVIEW");
        var fixture = IsUiReview && !string.IsNullOrWhiteSpace(fixturePath) ? new UpdateReviewFixture(fixturePath) : null;
        var clock = (TimeProvider?)fixture ?? TimeProvider.System;
        _updateHttp = fixture is null ? new HttpClient() : new HttpClient(fixture.CreateHandler());
        var source = new GitHubReleaseSource(_updateHttp, clock);
        _updates = new ReleaseUpdateSession(fixture is not null || BuildIdentity.Current.Kind == BuildKind.Release,
            fixture is null
                ? BuildIdentity.Current.ParsedVersion?.ToString() ?? BuildIdentity.Current.Version
                : "v1.2.99", source.GetLatestAsync, clock);
        _updateActions = new ReleaseUpdateActions(_updateHttp, _updates, fixture,
            fixture is null ? UpdateConnectionCost.IsMeteredOrUnknown : fixture.IsMeteredOrUnknown);
        var schedulePath = fixture is null
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FingVibe", "update-schedule.json")
            : Path.Combine(fixture.DownloadRoot, "update-schedule.json");
        _updateCloseScheduler = new ReleaseUpdateCloseScheduler(
            _updates, _updateActions, new ReleaseUpdateScheduleStore(schedulePath), clock);
        SettingsPage.ConfigureUpdates(_updates, _updateActions, _updateCloseScheduler, fixture is not null, Close);
        _updates.Changed += (_, state) => DispatcherQueue.TryEnqueue(() => ApplyUpdateIndicator(state));
        _updateCloseScheduler.Changed += (_, _) => DispatcherQueue.TryEnqueue(() =>
            ApplyUpdateIndicator(_updates.State));
        _updateTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _updateTimer.Tick += UpdateTimer_Tick;
        if (_updates.IsEligible) _updateTimer.Start();
        Closed += (_, _) =>
        {
            StopUpdates();
            _updateCloseScheduler?.Dispose();
            _updateHttp.Dispose();
        };
    }

    private async void UpdateTimer_Tick(object? sender, object e)
    {
        if (_updates is not null) await _updates.RunDueAsync();
    }

    private void ApplyUpdateIndicator(UpdateState state)
    {
        if (MainNavigation.SettingsItem is not NavigationViewItem settings) return;
        var scheduled = _updateCloseScheduler?.IsScheduled == true;
        var available = state.ConfirmedUpdate is not null && !scheduled;
        settings.InfoBadge = available ? new InfoBadge
        {
            Width = 8, Height = 8, MinWidth = 8, MinHeight = 8,
            Background = new SolidColorBrush(ColorHelper.FromArgb(255, 217, 119, 6))
        } : null;
        AutomationProperties.SetItemStatus(settings, scheduled ? "Update scheduled for close"
            : available ? "Update available" : "");
        AutomationProperties.SetHelpText(settings, available
            ? $"Update available: {state.ConfirmedUpdate!.VersionText}. Open Settings, then About FingVibe & updates."
            : scheduled ? $"Update scheduled for the next completed normal close. Open Settings, then About FingVibe & updates."
                : "Settings");
    }

    private void StopUpdates()
    {
        _updateTimer?.Stop();
        _updateActions?.Dispose();
        _updates?.Dispose();
    }

    private Task<bool> TryInstallScheduledUpdateOnCloseAsync() =>
        _updateCloseScheduler?.TryInstallOnCloseAsync() ?? Task.FromResult(false);
}
