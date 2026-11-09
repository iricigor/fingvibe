using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace FingVibe.App.Views;

public sealed partial class NetworkPageView
{
    private Func<int, int, bool, ActivityCountFilter, CancellationToken, Task<NetworkActivityDisplay>>? _activityLoader;
    private readonly AsyncSurfaceSession _activitySession = new();
    private readonly UISettings _activityColors = new();
    private readonly DispatcherTimer _activityClock = new() { Interval = TimeSpan.FromSeconds(30) };
    private IReadOnlyList<DeviceActivityCell> _activityCells = [];
    private string? _activityKey, _activityUnavailable;
    private bool _activityInitialized, _activityActive, _activityConfiguring, _activitySourceLoading, _activitySourceError;
    private (DateOnly Date, string Zone)? _activityDate;
    private decimal? _activityMaximum;
    private string _activityLegend = "Counts are unavailable until evidence is loaded.";
    private sealed record RoomChoice(string Label, Guid? Id = null, bool Unassigned = false);

    private void InitializeActivity()
    {
        NetworkActivityType.Items.Add(new ComboBoxItem { Content = "All types" });
        foreach (var type in Enum.GetValues<DeviceType>())
            NetworkActivityType.Items.Add(new ComboBoxItem { Content = type.Label(), Tag = type });
        NetworkActivityCategory.Items.Add(new ComboBoxItem { Content = "All categories" });
        foreach (var category in Enum.GetValues<DeviceUsageCategory>())
            NetworkActivityCategory.Items.Add(new ComboBoxItem { Content = category.ToString(), Tag = category });
        NetworkActivityType.SelectedIndex = NetworkActivityCategory.SelectedIndex = 0;
        _activitySession.StateChanged += (_, _) => AutomationProperties.SetItemStatus(NetworkActivityScroll, _activitySession.Status);
        AutomationProperties.SetItemStatus(NetworkActivityScroll, _activitySession.Status);
        _activityClock.Tick += (_, _) =>
        {
            TimeZoneInfo.ClearCachedData();
            var zone = TimeZoneInfo.Local;
            var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, zone).DateTime);
            if (_activityDate is { } previous && previous != (date, zone.Id)) _ = LoadActivityAsync();
        };
        ActualThemeChanged += (_, _) => RenderActivity();
        Loaded += (_, _) => _activityColors.ColorValuesChanged += ActivityColors_Changed;
        Unloaded += (_, _) =>
        {
            _activityColors.ColorValuesChanged -= ActivityColors_Changed;
            SetActivityActive(false);
        };
        _activityInitialized = true;
    }

    private void ActivityColors_Changed(UISettings sender, object args) => DispatcherQueue.TryEnqueue(RenderActivity);

    internal void ConfigureActivity(string key,
        Func<int, int, bool, ActivityCountFilter, CancellationToken, Task<NetworkActivityDisplay>>? loader,
        IReadOnlyList<ManagedRoom> rooms, string? unavailable = null, bool loading = false, bool error = false)
    {
        if (_activityKey == key) return;
        _activityKey = key;
        _activityLoader = loader;
        _activityUnavailable = unavailable;
        _activitySourceLoading = loading;
        _activitySourceError = error;
        _activityConfiguring = true;
        var selected = (NetworkActivityRoom.SelectedItem as ComboBoxItem)?.Tag as RoomChoice;
        var choices = new[] { new RoomChoice("All rooms"), new RoomChoice("Unassigned", Unassigned: true) }
            .Concat(rooms.OrderBy(room => room.Name).Select(room => new RoomChoice(room.Name, room.Id))).ToArray();
        var selectedChoice = choices.FirstOrDefault(choice => choice.Id == selected?.Id
            && choice.Unassigned == (selected?.Unassigned ?? false)) ?? choices[0];
        NetworkActivityRoom.Items.Clear();
        foreach (var choice in choices)
            NetworkActivityRoom.Items.Add(new ComboBoxItem { Content = choice.Label, Tag = choice });
        NetworkActivityRoom.SelectedIndex = Array.IndexOf(choices, selectedChoice);
        _activityConfiguring = false;
        if (_activityActive) _ = LoadActivityAsync();
    }

    internal void SetActivityActive(bool active)
    {
        if (_activityActive == active) return;
        _activityActive = active;
        if (active) { _activityClock.Start(); _ = LoadActivityAsync(); }
        else
        {
            _activityClock.Stop();
            _activitySession.Cancel();
            ClearActivity();
        }
    }

    private void ClearActivity()
    {
        _activityCells = [];
        _activityDate = null;
        _activityMaximum = null;
        NetworkActivityDetail.Text = "Select a cell to show its scan evidence.";
        _activityLegend = "Counts are unavailable until evidence is loaded.";
        NetworkActivityLoading.IsIndeterminate = false;
        NetworkActivityLoading.Visibility = Visibility.Collapsed;
        RenderActivity();
    }

    private async Task LoadActivityAsync()
    {
        if (!_activityInitialized || !_activityActive || _activityConfiguring) return;
        var hours = (int)NetworkActivityHours.Value;
        var weekdays = NetworkActivityPeriod.SelectedIndex == 2;
        var days = NetworkActivityPeriod.SelectedIndex == 0 ? 7 : 30;
        var room = (NetworkActivityRoom.SelectedItem as ComboBoxItem)?.Tag as RoomChoice;
        var type = (NetworkActivityType.SelectedItem as ComboBoxItem)?.Tag as DeviceType?;
        var category = (NetworkActivityCategory.SelectedItem as ComboBoxItem)?.Tag as DeviceUsageCategory?;
        var filter = new ActivityCountFilter(room?.Id, room?.Unassigned ?? false, type, category);
        var selection = $"{(NetworkActivityPeriod.SelectedItem as ComboBoxItem)?.Content}, {hours}-hour cells | " +
            $"{room?.Label ?? "All rooms"} / {type?.Label() ?? "All types"} / {category?.ToString() ?? "All categories"}";
        var request = _activitySession.Start(selection);
        if (request is null) return;
        ClearActivity();
        NetworkActivityWindow.Text = selection;
        NetworkActivityHoursLabel.Text = $"Group hours: {hours} {(hours == 1 ? "hour" : "hours")} per cell";
        NetworkActivityError.IsOpen = false;
        NetworkActivityRefresh.Content = "Refresh activity";
        NetworkActivityStatus.Text = _activityUnavailable ?? "Loading completed scan evidence...";
        if (_activityLoader is not { } loader)
        {
            NetworkActivityLoading.IsIndeterminate = _activitySourceLoading;
            NetworkActivityLoading.Visibility = _activitySourceLoading ? Visibility.Visible : Visibility.Collapsed;
            if (!_activitySourceLoading)
                _activitySession.Complete(request, _activitySourceError ? AsyncSurfaceState.Error : AsyncSurfaceState.Empty, () =>
                {
                    NetworkActivityError.IsOpen = _activitySourceError;
                    NetworkActivityError.Message = _activityUnavailable ?? "Activity is unavailable.";
                    NetworkActivityGrid.UpdateLayout();
                });
            return;
        }
        NetworkActivityLoading.IsIndeterminate = true;
        NetworkActivityLoading.Visibility = Visibility.Visible;
        ActivityGridRenderer.RenderLoading(NetworkActivityGrid, hours, _activityColors);
        var token = request.CancellationToken;
        try
        {
            var display = await Task.Run(() => loader(days, hours, weekdays, filter, token), token);
            _activitySession.Complete(request, display.EvidenceCells == 0 ? AsyncSurfaceState.Empty : AsyncSurfaceState.Ready, () =>
            {
                _activityCells = display.Cells;
                var buckets = display.Buckets;
                _activityDate = (buckets.LastDate, buckets.TimeZoneId);
                NetworkActivityWindow.Text = $"{buckets.FirstDate:d MMM yyyy} - {buckets.LastDate:d MMM yyyy} ({days} calendar dates) | " +
                    $"Local time: {buckets.TimeZoneId} | Today through {TimeZoneInfo.ConvertTimeBySystemTimeZoneId(buckets.QueryTime, buckets.TimeZoneId):HH:mm}.";
                _activityLegend = display.Legend;
                _activityMaximum = display.Maximum;
                NetworkActivityStatus.Text = $"{display.Contributors} current contributors; {display.UnavailableContributors} with unavailable/ambiguous evidence. " +
                    (display.EvidenceCells == 0 ? "No completed scan history for this selection. Imported details do not provide scan evidence."
                        : display.Contributors == 0 ? "No devices match the current filters. Zero is shown only where completed evidence exists."
                        : $"Evidence in {display.EvidenceCells} daily time cells. Gaps remain unknown.");
                FinishActivityRender();
            });
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidOperationException or ArgumentException or TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            _activitySession.Complete(request, AsyncSurfaceState.Error, () =>
            {
                NetworkActivityError.Message = $"Saved evidence is unavailable. No results are shown for this selection. {exception.Message}";
                NetworkActivityError.IsOpen = true;
                NetworkActivityStatus.Text = "Activity could not be loaded. Retry; restart if another writer changed the saved inventory.";
                NetworkActivityRefresh.Content = "Retry";
                FinishActivityRender();
            });
        }
    }

    private void FinishActivityRender()
    {
        NetworkActivityLoading.IsIndeterminate = false;
        NetworkActivityLoading.Visibility = Visibility.Collapsed;
        RenderActivity();
        NetworkActivityGrid.UpdateLayout();
    }

    private void RenderActivity()
    {
        if (!_activityInitialized) return;
        ActivityGridRenderer.Render(NetworkActivityGrid, _activityCells, ActualTheme, _activityColors,
            "NetworkActivityCell", details => NetworkActivityDetail.Text = details);
        NetworkActivityLegend.Inlines.Clear();
        if (_activityMaximum is { } maximum)
        {
            var contrast = new AccessibilitySettings().HighContrast;
            foreach (var fraction in maximum == 0 ? new[] { 0m } : new[] { 0m, .25m, .5m, .75m, 1m })
            {
                var sample = new DeviceActivityCell("", "", 0, 1, true,
                    fraction == 0 ? AnalyticsResponse.DidNotRespond : AnalyticsResponse.Responded, fraction, false, "", "");
                NetworkActivityLegend.Inlines.Add(new Run { Text = "\u25A0 ", Foreground = new SolidColorBrush(contrast
                    ? _activityColors.GetColorValue(UIColorType.Foreground)
                    : ActivityGridRenderer.CellColor(sample, false, ActualTheme, _activityColors)) });
                NetworkActivityLegend.Inlines.Add(new Run { Text = $"{maximum * fraction:0.#}  " });
            }
        }
        NetworkActivityLegend.Inlines.Add(new Run { Text = _activityLegend });
    }

    private void ActivitySelection_Changed(object sender, SelectionChangedEventArgs e) => _ = LoadActivityAsync();
    private void ActivityHours_Changed(object sender, RangeBaseValueChangedEventArgs e) => _ = LoadActivityAsync();
    private void ActivityRefresh_Click(object sender, RoutedEventArgs e) => _ = LoadActivityAsync();

    private void ActivityFields_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (sender is not Grid grid) return;
        var columns = e.NewSize.Width >= 640 ? grid.Children.Count : 1;
        if (grid.ColumnDefinitions.Count == columns) return;
        grid.ColumnDefinitions.Clear();
        grid.RowDefinitions.Clear();
        for (var index = 0; index < columns; index++) grid.ColumnDefinitions.Add(new());
        for (var index = 0; index < grid.Children.Count; index++)
        {
            grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
            Grid.SetRow((FrameworkElement)grid.Children[index], index / columns);
            Grid.SetColumn((FrameworkElement)grid.Children[index], index % columns);
        }
    }
}
