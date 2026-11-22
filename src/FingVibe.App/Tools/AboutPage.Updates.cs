using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using FingVibe.Core.Updates;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class AboutPage
{
    private ReleaseUpdateSession? _updates;
    private ReleaseUpdateActions? _actions;
    private ReleaseUpdateCloseScheduler? _closeScheduler;
    private Action? _closeForInstaller;
    private StableRelease? _renderedNotesRelease;

    internal void ConfigureUpdates(ReleaseUpdateSession updates, ReleaseUpdateActions actions,
        ReleaseUpdateCloseScheduler closeScheduler, bool isFixture, Action close)
    {
        _updates = updates;
        _actions = actions;
        _closeScheduler = closeScheduler;
        _closeForInstaller = close;
        UpdateInstalledVersion.Text = isFixture ? "Controlled update fixture: installed v1.2.99"
            : $"Installed version: {BuildIdentity.Current.Version}";
        UpdateDeploymentText.Text = updates.IsEligible ? actions.Deployment.Description
            : updates.State.Outcome == UpdateOutcome.Disabled
                ? "Development, PR and Test builds are not directly comparable to stable releases. No automatic checks or installation are offered; use the stable releases link to review releases manually."
                : "The installed release version could not be verified. No automatic checks or installation are offered; use the stable releases link for manual review.";
        updates.Changed += (_, state) => DispatcherQueue.TryEnqueue(() => RenderUpdateState(state));
        actions.Changed += (_, _) => DispatcherQueue.TryEnqueue(() => RenderUpdateState(updates.State));
        closeScheduler.Changed += (_, _) => DispatcherQueue.TryEnqueue(() => RenderUpdateState(updates.State));
        RenderUpdateState(updates.State);
        _ = RenderInstallOutcomeAsync();
    }

    private void RenderUpdateState(UpdateState state)
    {
        UpdateStatus.Text = ReleaseUpdatePresentation.Status(state, _updates!.InstalledVersion);
        UpdateLastChecked.Text = ReleaseUpdatePresentation.LastChecked(state.CheckedAt, DateTimeOffset.UtcNow);
        var details = new List<string>();
        if (state.Latest is { } release) details.Add($"Latest known stable version: {release.VersionText}.");
        if (state.ConfirmedUpdate is { } confirmed)
            details.Add($"Update available: {confirmed.VersionText}. Last confirmed {state.ConfirmedAt:u}.");
        if (state.Error is { } error) details.Add($"Latest check failed: {error}");
        if (state.CheckedAt is { } checkedAt) details.Add($"Last check completed {checkedAt:u}.");
        if (state.NextCheckAt is { } next) details.Add($"Next automatic check no earlier than {next:u}.");
        if (state.ConfirmedUpdate is not null && _actions?.SelectedAsset is null)
            details.Add("The required Windows x64 asset is unavailable. Use the release page for manual download.");
        if (_actions?.BackgroundDownloadStatus is { } backgroundStatus)
            details.Add(backgroundStatus);
        if (_actions?.IsBackgroundDownloading == true)
            details.Add($"Background update download: {_actions.DownloadProgress:0}% complete.");
        if (_actions?.BackgroundDownloadError is { } backgroundError)
            details.Add($"Background download failed: {backgroundError} The next update check will retry.");
        if (_closeScheduler?.LastError is { } closeError)
            details.Add($"Postponed update failed: {closeError}");
        UpdateDetails.Text = string.Join(Environment.NewLine, details);
        var scheduledVersion = _closeScheduler?.ScheduledVersionText;
        var scheduled = scheduledVersion is not null;
        UpdateScheduledStatus.Text = scheduled
            ? _closeScheduler!.IsReady
                ? $"{scheduledVersion} will install when you close FingVibe."
                : $"{scheduledVersion} is scheduled; its verified download is being prepared."
            : "";
        UpdateScheduledStatus.Visibility = scheduled ? Visibility.Visible : Visibility.Collapsed;
        CancelScheduledUpdateButton.Visibility = scheduled ? Visibility.Visible : Visibility.Collapsed;
        CheckUpdatesButton.Visibility = _updates!.IsEligible ? Visibility.Visible : Visibility.Collapsed;
        CheckUpdatesButton.IsEnabled = !state.IsChecking;
        UpdateReleaseLink.NavigateUri = state.ConfirmedUpdate?.PageUri ?? StableRelease.ReleasesUri;
        UpdateReleaseLink.Content = state.ConfirmedUpdate is null ? "Stable releases (opens in browser)" : "Release notes and downloads (opens in browser)";
        var canUpdateNow = _actions?.CanUpdateNow == true;
        UpdateSecurityWarning.Visibility = canUpdateNow ? Visibility.Visible : Visibility.Collapsed;
        DownloadUpdateButton.Visibility = !canUpdateNow && _actions?.SelectedAsset is not null
            && _actions?.Deployment.IsInstalled == false ? Visibility.Visible : Visibility.Collapsed;
        DownloadUpdateButton.IsEnabled = _actions is { IsDownloading: false } && !state.IsChecking;
        DownloadUpdateButton.Content = new TextBlock
        {
            Text = _actions?.Deployment.IsInstalled == true ? "Download Setup" : "Download portable ZIP",
            TextWrapping = TextWrapping.Wrap
        };
        InstallUpdateButton.Visibility = canUpdateNow || scheduled ? Visibility.Visible : Visibility.Collapsed;
        InstallUpdateButton.IsEnabled = !state.IsChecking &&
            (scheduled ? _closeScheduler!.IsReady : canUpdateNow);
        InstallUpdateButton.Content = scheduled ? "Restart now" : "Update now";
        RenderReleaseNotes(state.ConfirmedUpdate);
    }

    private void RenderReleaseNotes(StableRelease? update)
    {
        // Rebuild only for a different release so routine state refreshes keep the reader's expansion.
        if (Equals(update, _renderedNotesRelease)) return;
        _renderedNotesRelease = update;
        ReleaseNotesContent.Children.Clear();
        ReleaseNotesExpander.IsExpanded = false;
        var notes = update?.Notes;
        ReleaseNotesExpander.Visibility = notes is null ? Visibility.Collapsed : Visibility.Visible;
        ReleaseNotesFallbackLink.Visibility = update is not null && notes is null ? Visibility.Visible : Visibility.Collapsed;
        ReleaseNotesFullLink.Visibility = notes?.IsTruncated == true ? Visibility.Visible : Visibility.Collapsed;
        if (update is null) return;
        ReleaseNotesFallbackLink.NavigateUri = ReleaseNotesFullLink.NavigateUri = update.PageUri;
        if (notes is null) return;
        ReleaseNotesHeader.Text = $"What's new in {update.VersionText.TrimStart('v')}";
        AutomationProperties.SetName(ReleaseNotesExpander, ReleaseNotesHeader.Text);
        foreach (var block in notes.Blocks)
            ReleaseNotesContent.Children.Add(CreateReleaseNoteElement(block));
    }

    private static FrameworkElement CreateReleaseNoteElement(ReleaseNoteBlock block)
    {
        var text = new TextBlock { Text = block.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        switch (block.Kind)
        {
            case ReleaseNoteKind.Heading:
                text.Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"];
                text.Margin = new Thickness(0, 4, 0, 0);
                AutomationProperties.SetHeadingLevel(text, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level3);
                return text;
            case ReleaseNoteKind.Bullet:
                var row = new Grid { ColumnSpacing = 8, Margin = new Thickness(8, 0, 0, 0) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var marker = new TextBlock { Text = "•" };
                AutomationProperties.SetAccessibilityView(marker, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                Grid.SetColumn(text, 1);
                row.Children.Add(marker);
                row.Children.Add(text);
                return row;
            default:
                return text;
        }
    }

    private async void CheckUpdates_Click(object sender, RoutedEventArgs e)
    {
        if (_updates is not null) await _updates.CheckAsync();
    }

    private async void DownloadUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (_actions is null || _updates is null) return;
        UpdateDownloadStatus.Text = "Downloading update...";
        UpdateDownloadProgress.Value = 0;
        UpdateDownloadProgress.Visibility = CancelUpdateDownloadButton.Visibility = Visibility.Visible;
        var progress = new Progress<double>(value => UpdateDownloadProgress.Value = value);
        try
        {
            var download = _actions.DownloadAsync(progress);
            RenderUpdateState(_updates.State);
            await download;
            UpdateDownloadStatus.Text = _actions.Deployment.IsInstalled
                ? $"Setup downloaded to {_actions.DownloadedPath}. Installation has not started."
                : $"ZIP downloaded to {_actions.DownloadedPath}. Close FingVibe and replace your portable files manually; keep your saved data.";
        }
        catch (OperationCanceledException)
        {
            UpdateDownloadStatus.Text = "Download cancelled or timed out. No incomplete file can be installed.";
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or HttpRequestException or UnauthorizedAccessException or SecurityException)
        {
            Trace.TraceWarning($"Update download failed: {exception}");
            if (_actions.IsDisposed) return;
            UpdateDownloadStatus.Text = $"Download failed: {exception.Message}";
            await ShowDownloadFailureAsync(exception);
        }
        finally
        {
            UpdateDownloadProgress.Visibility = CancelUpdateDownloadButton.Visibility = Visibility.Collapsed;
            if (!_actions.IsDisposed) RenderUpdateState(_updates.State);
        }
    }

    private void CancelDownload_Click(object sender, RoutedEventArgs e) => _actions?.CancelDownload();

    internal async Task UpdateNowAsync()
    {
        if (_actions is null || !_actions.CanUpdateNow) return;
        var confirmationDialog = new ContentDialog
        {
            Name = "UpdateInstallConfirmationDialog", XamlRoot = XamlRoot, Title = "Update FingVibe now?",
            Content = "FingVibe will close, update, and reopen. Saved data is preserved. Windows may still ask for confirmation.",
            PrimaryButtonText = "Restart now", SecondaryButtonText = "When I close",
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        };
        AutomationProperties.SetAutomationId(confirmationDialog, "UpdateInstallConfirmationDialog");
        var confirmation = await confirmationDialog.ShowAsync();
        if (confirmation == ContentDialogResult.Secondary && _closeScheduler is not null)
        {
            UpdateDownloadProgress.Value = 0;
            UpdateDownloadProgress.Visibility = CancelUpdateDownloadButton.Visibility = Visibility.Visible;
            UpdateDownloadStatus.Text = "Preparing the verified update for the next normal close...";
            try
            {
                await _closeScheduler.ScheduleAsync(
                    new Progress<double>(value => UpdateDownloadProgress.Value = value));
                UpdateDownloadStatus.Text = _closeScheduler.IsReady
                    ? $"FingVibe {_closeScheduler.ScheduledVersionText} will install when you close FingVibe."
                    : "The update remains scheduled; verification will continue.";
            }
            catch (OperationCanceledException)
            {
                UpdateDownloadStatus.Text = "Scheduled update cancelled. FingVibe remains available.";
            }
            catch (Exception exception) when (exception is IOException or InvalidDataException
                or HttpRequestException or UnauthorizedAccessException or SecurityException)
            {
                Trace.TraceWarning($"Scheduling update for close failed: {exception}");
                UpdateDownloadStatus.Text = $"The update could not be prepared: {exception.Message}";
                await ShowDownloadFailureAsync(exception);
            }
            finally
            {
                UpdateDownloadProgress.Visibility = CancelUpdateDownloadButton.Visibility = Visibility.Collapsed;
                if (_updates is not null) RenderUpdateState(_updates.State);
            }
            return;
        }
        if (confirmation != ContentDialogResult.Primary) return;
        if (_closeScheduler is not null) await _closeScheduler.CancelAsync();
        InstallUpdateButton.IsEnabled = false;
        try
        {
            UpdateDownloadProgress.Value = 0;
            UpdateDownloadProgress.Visibility = CancelUpdateDownloadButton.Visibility = Visibility.Visible;
            UpdateDownloadStatus.Text = "Downloading update...";
            if (!_actions.CanInstall)
            {
                try
                {
                    await _actions.DownloadAsync(new Progress<double>(value => UpdateDownloadProgress.Value = value));
                }
                catch (OperationCanceledException)
                {
                    UpdateDownloadStatus.Text = "Download cancelled or timed out. No incomplete file can be installed.";
                    return;
                }
                catch (Exception downloadException) when (downloadException is IOException or InvalidDataException
                    or HttpRequestException or UnauthorizedAccessException or SecurityException)
                {
                    UpdateDownloadStatus.Text = $"Download failed: {downloadException.Message}";
                    await ShowDownloadFailureAsync(downloadException);
                    return;
                }
            }
            await _actions.StartInstallHandoffAsync(relaunch: true);
            _closeForInstaller?.Invoke();
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or HttpRequestException or UnauthorizedAccessException
            or Win32Exception or InvalidOperationException or SecurityException or OperationCanceledException)
        {
            Trace.TraceWarning($"Update now failed: {exception}");
            if (_actions.IsDisposed) return;
            var recovery = exception is InvalidDataException
                ? "Do not run the downloaded file. Obtain a fresh update manually from the official GitHub Releases before installation."
                : $"Install the downloaded update manually from {_actions.DownloadedPath}. Close FingVibe before continuing. Windows security protections still apply; installation has not completed.";
            var failureDialog = new ContentDialog
            {
                Name = "UpdateLaunchFailureDialog", XamlRoot = XamlRoot, Title = "Installer could not be started",
                Content = $"Windows did not start the installer. {exception.Message}\n\n{recovery}",
                CloseButtonText = "OK"
            };
            AutomationProperties.SetAutomationId(failureDialog, "UpdateLaunchFailureDialog");
            await failureDialog.ShowAsync();
        }
        finally
        {
            UpdateDownloadProgress.Visibility = CancelUpdateDownloadButton.Visibility = Visibility.Collapsed;
            InstallUpdateButton.IsEnabled = true;
            if (!_actions.IsDisposed && _updates is not null) RenderUpdateState(_updates.State);
        }
    }

    private async void InstallUpdate_Click(object sender, RoutedEventArgs e) => await UpdateNowAsync();
    private async void CancelScheduledUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (_closeScheduler is null) return;
        await _closeScheduler.CancelAsync();
        if (_updates is not null) RenderUpdateState(_updates.State);
    }

    private async Task RenderInstallOutcomeAsync()
    {
        if (_actions is null || _updates is null) return;
        ReleaseInstallHandoffRecord? record = null;
        string? message = null;
        var deadline = DateTimeOffset.UtcNow.AddSeconds(10);
        do
        {
            record = await _actions.ReadLatestInstallHandoffAsync();
            message = ReleaseUpdatePresentation.InstallResult(record, _updates.InstalledVersion,
                AppContext.BaseDirectory, Environment.ProcessPath);
            if (record is null || record.Outcome is not null || DateTimeOffset.UtcNow >= deadline) break;
            await Task.Delay(250);
        } while (true);
        if (DispatcherQueue.HasThreadAccess)
            ApplyInstallOutcome(message);
        else
            DispatcherQueue.TryEnqueue(() => ApplyInstallOutcome(message));
    }

    private async Task ShowDownloadFailureAsync(Exception exception)
    {
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = $"The update could not be downloaded. {exception.Message}", TextWrapping = TextWrapping.Wrap });
        content.Children.Add(new HyperlinkButton
        {
            Content = "Download manually from GitHub Releases",
            NavigateUri = new Uri("https://github.com/iricigor/fingvibe/releases")
        });
        var dialog = new ContentDialog
        {
            Name = "UpdateDownloadFailureDialog", XamlRoot = XamlRoot,
            Title = "Update download failed", Content = content, CloseButtonText = "Close"
        };
        AutomationProperties.SetAutomationId(dialog, "UpdateDownloadFailureDialog");
        await dialog.ShowAsync();
    }

    private void ApplyInstallOutcome(string? message)
    {
        UpdateInstallOutcome.Text = message ?? "";
        UpdateInstallOutcome.Visibility = string.IsNullOrWhiteSpace(message)
            ? Visibility.Collapsed : Visibility.Visible;
    }
}
