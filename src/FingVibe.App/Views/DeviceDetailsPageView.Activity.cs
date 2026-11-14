using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace FingVibe.App.Views;

public sealed partial class DeviceDetailsPageView
{
    private Func<int, int, CancellationToken, Task<ActivityBuckets>>? _activityLoader;
    private string? _activitySourceKey;
    private string? _activityUnavailable;
    private bool _activitySourceLoading;
    private bool _activityActive;
    private bool _activityPageActive;
    private bool _activityInitialized;
    private readonly AsyncSurfaceSession _activitySession = new();
    private IReadOnlyList<DeviceActivityCell> _activityCells = [];
    private readonly UISettings _activityColors = new();
    private (DateOnly Date, string Zone, int Hour, TimeSpan Offset)? _activityDate;
    private const string ActivityDetailPrompt = "Select a cell to show its scan evidence.";

    private void InitializeActivity()
    {
        _activityInitialized = true;
        // ItemStatus on the grid's always-present ScrollViewer is the observable Activity state for UI Automation.
        _activitySession.StateChanged += (_, _) => AutomationProperties.SetItemStatus(ActivityScroll, _activitySession.Status);
        AutomationProperties.SetItemStatus(ActivityScroll, _activitySession.Status);
        ClearActivity();
        ActualThemeChanged += (_, _) => RenderActivity();
        Loaded += (_, _) => _activityColors.ColorValuesChanged += ActivityColors_Changed;
        Unloaded += (_, _) =>
        {
            _activityColors.ColorValuesChanged -= ActivityColors_Changed;
            SetActivityActive(false);
        };
    }

    private void ActivityColors_Changed(UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(RenderActivity);

    internal void ConfigureActivity(string key, Func<int, int, CancellationToken, Task<ActivityBuckets>>? loader,
        string? unavailable = null, bool loading = false)
    {
        if (_activitySourceKey == key) return;
        _activitySourceKey = key;
        _activityLoader = loader;
        _activityUnavailable = unavailable;
        _activitySourceLoading = loading;
        if (_activityActive) _ = LoadActivityAsync();
    }

    internal void SetActivityActive(bool active)
    {
        _activityPageActive = active;
        SetActivityTabActive(active && DetailsTabs.SelectedItem == HistoryTab);
    }

    private void SetActivityTabActive(bool active)
    {
        if (_activityActive == active) return;
        _activityActive = active;
        if (active) _ = LoadActivityAsync();
        else CancelActivity();
    }

    private void CancelActivity()
    {
        _activitySession.Cancel();
        ClearActivity();
    }

    // Text elements keep non-empty content in every state so their UI Automation peers stay stable.
    private void ClearActivity()
    {
        _activityCells = [];
        _activityDate = null;
        ActivityLoading.IsIndeterminate = false;
        ActivityLoading.Visibility = Visibility.Collapsed;
        ActivityWindow.Text = ActivitySelection();
        ActivityScope.Text = "Exact scope is available after loading this selection.";
        ActivityDetail.Text = ActivityDetailPrompt;
        if (string.IsNullOrEmpty(ActivityStatus.Text)) ActivityStatus.Text = "Activity is not loaded.";
        RenderActivity();
    }

    private string ActivitySelection()
    {
        var period = (ActivityPeriod.SelectedItem as ComboBoxItem)?.Content as string ?? "Last 7 days";
        return $"{period}, {(int)ActivityHours.Value}-hour cells";
    }

    private void RefreshActivityDate()
    {
        if (!_activityActive) return;
        TimeZoneInfo.ClearCachedData();
        var zone = TimeZoneInfo.Local;
        var local = TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, zone);
        var date = DateOnly.FromDateTime(local.DateTime);
        if (_activityDate is { } previous && previous != (date, zone.Id, local.Hour, local.Offset)) _ = LoadActivityAsync();
    }

    private async Task LoadActivityAsync()
    {
        if (!_activityInitialized || !_activityActive) return;
        var request = _activitySession.Start(ActivitySelection());
        if (request is null) return;
        ClearActivity();
        var hours = (int)ActivityHours.Value;
        var weekdays = ActivityPeriod.SelectedIndex == 2;
        var days = ActivityPeriod.SelectedIndex == 0 ? 7 : 30;
        ActivityHoursLabel.Text = $"Hours per square: {hours}";
        ActivityError.IsOpen = false;
        ActivityRefresh.Visibility = Visibility.Collapsed;
        ActivityStatus.Text = _activityUnavailable ?? "Loading completed scan evidence...";
        if (_activityLoader is not { } loader)
        {
            ActivityLoading.Visibility = _activitySourceLoading ? Visibility.Visible : Visibility.Collapsed;
            ActivityLoading.IsIndeterminate = _activitySourceLoading;
            // A loading source stays Loading until its configuration replaces this request.
            if (!_activitySourceLoading) _activitySession.Complete(request, AsyncSurfaceState.Empty, () => ActivityGrid.UpdateLayout());
            return;
        }
        ActivityLoading.Visibility = Visibility.Visible;
        ActivityLoading.IsIndeterminate = true;
        RenderActivityLoading(hours);
        var token = request.CancellationToken;
        try
        {
            var (buckets, cells) = await Task.Run(async () =>
            {
                var result = await loader(days, hours, token);
                token.ThrowIfCancellationRequested();
                return (result, DeviceActivityPresentation.Cells(result, weekdays));
            }, token);
            _activitySession.Complete(request, AsyncSurfaceState.Ready, () =>
            {
                _activityCells = cells;
                var local = TimeZoneInfo.ConvertTimeBySystemTimeZoneId(buckets.QueryTime, buckets.TimeZoneId);
                _activityDate = (buckets.LastDate, buckets.TimeZoneId, local.Hour, local.Offset);
                ActivityWindow.Text = $"{buckets.FirstDate:d MMM} - {buckets.LastDate:d MMM yyyy} | Local time | " +
                    $"Scans on {DeviceActivityPresentation.CoveredDates(buckets)} of {days} days | " +
                    $"Today through {TimeZoneInfo.ConvertTimeBySystemTimeZoneId(buckets.QueryTime, buckets.TimeZoneId):HH:mm}";
                ActivityScope.Text = $"Timezone: {buckets.TimeZoneId} | Network: {buckets.NetworkId} | {buckets.Subnet}\n" +
                    $"{days} local calendar dates; later intervals today are not yet observed.";
                var known = DeviceActivityPresentation.PopulatedSquares(cells);
                ActivityStatus.Text = known == 0
                    ? "No completed scan history for this selection. Imported details do not provide scan evidence."
                    : $"{known} squares have scan results. Select a square for details.";
                FinishActivityRender();
            });
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException
            or InvalidOperationException or ArgumentException or TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            _activitySession.Complete(request, AsyncSurfaceState.Error, () =>
            {
                ActivityError.Message = $"Saved evidence is unavailable. No results are shown for this selection. {exception.Message}";
                ActivityError.IsOpen = true;
                ActivityStatus.Text = "Activity could not be loaded. Retry; restart if another writer changed the saved inventory.";
                ActivityRefresh.Content = "Retry";
                ActivityRefresh.Visibility = Visibility.Visible;
                FinishActivityRender();
            });
        }
    }

    // Completes layout before the session reports the outcome, so Ready means the content is rendered.
    private void FinishActivityRender()
    {
        ActivityLoading.IsIndeterminate = false;
        ActivityLoading.Visibility = Visibility.Collapsed;
        RenderActivity();
        ActivityGrid.UpdateLayout();
    }

    private void ActivityPeriod_SelectionChanged(object sender, SelectionChangedEventArgs e) => _ = LoadActivityAsync();
    private void ActivityHours_ValueChanged(object sender, RangeBaseValueChangedEventArgs e) => _ = LoadActivityAsync();
    private void ActivityRefresh_Click(object sender, RoutedEventArgs e) => _ = LoadActivityAsync();

    private void RenderActivityLoading(int hours) => ActivityGridRenderer.RenderLoading(ActivityGrid, hours, _activityColors);

    private void RenderActivity()
    {
        if (!_activityInitialized) return;
        RenderActivityLegend(new AccessibilitySettings().HighContrast);
        ActivityGridRenderer.Render(ActivityGrid, _activityCells, ActualTheme, _activityColors,
            "ActivityCell", details => ActivityDetail.Text = details, deviceStyle: true);
    }

    private void RenderActivityLegend(bool contrast)
    {
        ActivityLegend.Inlines.Clear();
        var weekdays = ActivityPeriod.SelectedIndex == 2;
        foreach (var fraction in weekdays ? new[] { 0m, .25m, .5m, .75m, 1m } : new[] { 1m, 0m })
        {
            var sample = new DeviceActivityCell("", "", 0, 1, true,
                fraction == 0 ? AnalyticsResponse.DidNotRespond : AnalyticsResponse.Responded, fraction, false, "", "");
            ActivityLegend.Inlines.Add(new Run { Text = "\u25A0 ", Foreground = new SolidColorBrush(contrast
                ? _activityColors.GetColorValue(UIColorType.Foreground)
                : ActivityGridRenderer.CellColor(sample, false, ActualTheme, _activityColors, deviceStyle: true)) });
            ActivityLegend.Inlines.Add(new Run { Text = weekdays ? $"{fraction:P0}  "
                : fraction == 1 ? "R: Responded  " : "-: Scanned, no response  " });
        }
        ActivityLegend.Inlines.Add(new Run { Text = weekdays
            ? "of applicable dates responded. Hatching: some dates unknown. -: not applicable."
            : "Hatching / ?: No scan data. Dots: Later today. N/A: skipped DST hour." });
        if (contrast) ActivityLegend.Inlines.Add(new Run { Text = " R: response; -: nonresponse; ?: unknown." });
    }

}
