using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using FingVibe.Core.Updates;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class AboutPage
{
    private ReleaseUpdateSession? _updates;
    private ReleaseUpdateActions? _actions;
    private Action? _closeForInstaller;

    internal void ConfigureUpdates(ReleaseUpdateSession updates, ReleaseUpdateActions actions, bool isFixture, Action close)
    {
        _updates = updates;
        _actions = actions;
        _closeForInstaller = close;
        UpdateInstalledVersion.Text = isFixture ? "Controlled update fixture: installed v1.2.99"
            : $"Installed version: {BuildIdentity.Current.Version}";
        UpdateDeploymentText.Text = updates.IsEligible ? actions.Deployment.Description
            : updates.State.Outcome == UpdateOutcome.Disabled
                ? "Development, PR and Test builds are not directly comparable to stable releases. No automatic checks or installation are offered; use the stable releases link to review releases manually."
                : "The installed release version could not be verified. No automatic checks or installation are offered; use the stable releases link for manual review.";
        updates.Changed += (_, state) => DispatcherQueue.TryEnqueue(() => RenderUpdateState(state));
        RenderUpdateState(updates.State);
    }

    private void RenderUpdateState(UpdateState state)
    {
        UpdateStatus.Text = state.IsChecking ? "Checking for updates..." : state.Outcome switch
        {
            UpdateOutcome.NotChecked => "Updates have not been checked yet.",
            UpdateOutcome.Current when state.Latest?.Version < _updates!.InstalledVersion => "No newer stable release is available.",
            UpdateOutcome.Current => "You are on the latest version",
            UpdateOutcome.Available => "A newer version is available",
            UpdateOutcome.Failed => "Unable to determine the latest version",
            _ => "This build does not use stable-release update checks."
        };
        var details = new List<string>();
        if (state.Latest is { } release) details.Add($"Latest known stable version: {release.VersionText}.");
        if (state.ConfirmedUpdate is { } confirmed)
            details.Add($"Update available: {confirmed.VersionText}. Last confirmed {state.ConfirmedAt:u}.");
        if (state.Error is { } error) details.Add($"Latest check failed: {error}");
        if (state.CheckedAt is { } checkedAt) details.Add($"Last check completed {checkedAt:u}.");
        if (state.NextCheckAt is { } next) details.Add($"Next automatic check no earlier than {next:u}.");
        if (state.ConfirmedUpdate is not null && _actions?.SelectedAsset is null)
            details.Add("The required Windows x64 asset is unavailable. Use the release page for manual download.");
        UpdateDetails.Text = string.Join(Environment.NewLine, details);
        CheckUpdatesButton.Visibility = _updates!.IsEligible ? Visibility.Visible : Visibility.Collapsed;
        CheckUpdatesButton.IsEnabled = !state.IsChecking;
        UpdateReleaseLink.NavigateUri = state.ConfirmedUpdate?.PageUri ?? StableRelease.ReleasesUri;
        UpdateReleaseLink.Content = state.ConfirmedUpdate is null ? "Stable releases (opens in browser)" : "Release notes and downloads (opens in browser)";
        DownloadUpdateButton.Visibility = _actions?.SelectedAsset is null ? Visibility.Collapsed : Visibility.Visible;
        DownloadUpdateButton.IsEnabled = _actions is { IsDownloading: false } && !state.IsChecking;
        DownloadUpdateButton.Content = new TextBlock
        {
            Text = _actions?.Deployment.IsInstalled == true ? "Download Setup" : "Download portable ZIP",
            TextWrapping = TextWrapping.Wrap
        };
        InstallUpdateButton.Visibility = _actions?.CanInstall == true ? Visibility.Visible : Visibility.Collapsed;
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
            var content = new StackPanel { Spacing = 12 };
            content.Children.Add(new TextBlock { Text = $"The update could not be downloaded. {exception.Message}", TextWrapping = TextWrapping.Wrap });
            content.Children.Add(new HyperlinkButton
            {
                Content = "Download manually from GitHub Releases",
                NavigateUri = new Uri("https://github.com/iricigor/fingvibe/releases")
            });
            await new ContentDialog
            {
                Name = "UpdateDownloadFailureDialog", XamlRoot = XamlRoot,
                Title = "Update download failed", Content = content, CloseButtonText = "Close"
            }.ShowAsync();
        }
        finally
        {
            UpdateDownloadProgress.Visibility = CancelUpdateDownloadButton.Visibility = Visibility.Collapsed;
            if (!_actions.IsDisposed) RenderUpdateState(_updates.State);
        }
    }

    private void CancelDownload_Click(object sender, RoutedEventArgs e) => _actions?.CancelDownload();

    private async void InstallUpdate_Click(object sender, RoutedEventArgs e)
    {
        if (_actions is null) return;
        var confirmation = await new ContentDialog
        {
            Name = "UpdateInstallConfirmationDialog", XamlRoot = XamlRoot, Title = "Install update and close FingVibe?",
            Content = $"Launch {_actions.DownloadedPath} using Windows, then close FingVibe normally. The unsigned installer may trigger SmartScreen, Defender, UAC or organization policy. Continue only after FingVibe closes: the installer refuses to update a running copy. Saved data is preserved. Launching does not mean installation completed.",
            PrimaryButtonText = "Install and close", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
        }.ShowAsync();
        if (confirmation != ContentDialogResult.Primary) return;
        InstallUpdateButton.IsEnabled = false;
        try
        {
            await _actions.LaunchInstallerAsync();
            _closeForInstaller?.Invoke();
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException
            or Win32Exception or InvalidOperationException or SecurityException or OperationCanceledException)
        {
            Trace.TraceWarning($"Update installer launch failed: {exception}");
            if (_actions.IsDisposed) return;
            var recovery = exception is InvalidDataException
                ? "Do not run the downloaded file. Obtain a fresh update manually from the official GitHub Releases before installation."
                : $"Install the downloaded update manually from {_actions.DownloadedPath}. Close FingVibe before continuing. Windows security protections still apply; installation has not completed.";
            await new ContentDialog
            {
                Name = "UpdateLaunchFailureDialog", XamlRoot = XamlRoot, Title = "Installer could not be started",
                Content = $"Windows did not start the installer. {exception.Message}\n\n{recovery}",
                CloseButtonText = "OK"
            }.ShowAsync();
        }
        finally
        {
            InstallUpdateButton.IsEnabled = true;
            if (!_actions.IsDisposed && _updates is not null) RenderUpdateState(_updates.State);
        }
    }
}
