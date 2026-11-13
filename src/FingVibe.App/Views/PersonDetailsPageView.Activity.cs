using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.UI.ViewManagement;

namespace FingVibe.App.Views;

public sealed partial class PersonDetailsPageView
{
    private Func<int, int, bool, CancellationToken, Task<EquipmentActivityDisplay>>? _activityLoader;
    private readonly AsyncSurfaceSession _activitySession = new();
    private readonly UISettings _activityColors = new();
    private readonly DispatcherTimer _activityClock = new() { Interval = TimeSpan.FromSeconds(30) };
    private EquipmentActivityDisplay? _activityDisplay;
    private IReadOnlyList<AssignedDeviceListRow> _assignedDevices = [];
    private string? _activityKey, _activityUnavailable;
    private string _activityNetwork = "No selected network";
    private bool _activityInitialized, _activityActive, _activitySourceLoading, _activitySourceError;

    private void InitializeActivity()
    {
        _activitySession.StateChanged += (_, _) => AutomationProperties.SetItemStatus(EquipmentActivityScroll, _activitySession.Status);
        AutomationProperties.SetItemStatus(EquipmentActivityScroll, _activitySession.Status);
        _activityClock.Tick += (_, _) =>
        {
            UpdateEquipmentIndicator();
            TimeZoneInfo.ClearCachedData();
            var zone = TimeZoneInfo.Local;
            var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, zone).DateTime);
            if (_activityDisplay is { } display && (date != display.Grid.Buckets.LastDate || zone.Id != display.Grid.Buckets.TimeZoneId))
                _ = LoadActivityAsync();
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

    internal void ConfigureActivity(string key, string network,
        Func<int, int, bool, CancellationToken, Task<EquipmentActivityDisplay>>? loader,
        string? unavailable = null, bool loading = false, bool error = false)
    {
        if (_activityKey == key) return;
        _activityKey = key;
        _activityNetwork = network;
        _activityLoader = loader;
        _activityUnavailable = unavailable;
        _activitySourceLoading = loading;
        _activitySourceError = error;
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
        _activityDisplay = null;
        EquipmentActivityDetail.Text = "Select a cell to show its equipment and scan evidence.";
        EquipmentActivityContributors.Text = "Equipment is not loaded.";
        EquipmentActivityLoading.IsIndeterminate = false;
        EquipmentActivityLoading.Visibility = Visibility.Collapsed;
        RefreshAssignedCategories();
        UpdateEquipmentIndicator();
        RenderActivity();
    }

    private async Task LoadActivityAsync()
    {
        if (!_activityInitialized || !_activityActive) return;
        var hours = (int)EquipmentActivityHours.Value;
        var weekdays = EquipmentActivityPeriod.SelectedIndex == 2;
        var days = EquipmentActivityPeriod.SelectedIndex == 0 ? 7 : 30;
        var selection = $"{SelectedPerson?.Name} | {_activityNetwork} | " +
            $"{(EquipmentActivityPeriod.SelectedItem as ComboBoxItem)?.Content}, {hours}-hour cells";
        var request = _activitySession.Start(selection);
        if (request is null) return;
        ClearActivity();
        EquipmentActivityWindow.Text = selection;
        EquipmentActivityHoursLabel.Text = $"Group hours: {hours} {(hours == 1 ? "hour" : "hours")} per cell";
        EquipmentActivityError.IsOpen = false;
        EquipmentActivityRefresh.Content = "Refresh activity";
        EquipmentActivityStatus.Text = _activityUnavailable ?? "Loading completed scan evidence...";
        if (_activityLoader is not { } loader)
        {
            EquipmentActivityLoading.IsIndeterminate = _activitySourceLoading;
            EquipmentActivityLoading.Visibility = _activitySourceLoading ? Visibility.Visible : Visibility.Collapsed;
            if (!_activitySourceLoading)
                _activitySession.Complete(request, _activitySourceError ? AsyncSurfaceState.Error : AsyncSurfaceState.Empty, () =>
                {
                    EquipmentActivityError.IsOpen = _activitySourceError;
                    EquipmentActivityError.Message = _activityUnavailable ?? "Activity is unavailable.";
                    EquipmentActivityGrid.UpdateLayout();
                });
            return;
        }
        EquipmentActivityLoading.IsIndeterminate = true;
        EquipmentActivityLoading.Visibility = Visibility.Visible;
        ActivityGridRenderer.RenderLoading(EquipmentActivityGrid, hours, _activityColors);
        var token = request.CancellationToken;
        try
        {
            var display = await Task.Run(() => loader(days, hours, weekdays, token), token);
            var empty = display.Latest.Total == 0 || display.Grid.EvidenceCells == 0;
            _activitySession.Complete(request, empty ? AsyncSurfaceState.Empty : AsyncSurfaceState.Ready, () =>
            {
                _activityDisplay = display;
                var buckets = display.Grid.Buckets;
                EquipmentActivityWindow.Text = $"{buckets.FirstDate:d MMM yyyy} - {buckets.LastDate:d MMM yyyy} ({days} calendar dates) | " +
                    $"{_activityNetwork} | Local time: {buckets.TimeZoneId} | Today through {TimeZoneInfo.ConvertTimeBySystemTimeZoneId(buckets.QueryTime, buckets.TimeZoneId):HH:mm}.";
                EquipmentActivityContributors.Text = display.Contributors;
                EquipmentActivityStatus.Text = display.Latest.Total == 0 ? "No equipment assigned. Use Assign devices below; no chart estimate is shown."
                    : $"{display.Grid.Contributors} current contributors; {display.Grid.UnavailableContributors} with unavailable/ambiguous evidence. " +
                        (display.Grid.EvidenceCells == 0 ? "No completed scan history for this selection. Imported details do not provide scan evidence."
                            : $"Evidence in {display.Grid.EvidenceCells} daily time cells. Gaps remain unknown.");
                RefreshAssignedCategories();
                UpdateEquipmentIndicator();
                FinishActivityRender();
            });
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException
            or InvalidOperationException or ArgumentException or TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            _activitySession.Complete(request, AsyncSurfaceState.Error, () =>
            {
                EquipmentActivityError.Message = $"Saved evidence is unavailable. No results are shown for this selection. {exception.Message}";
                EquipmentActivityError.IsOpen = true;
                EquipmentActivityStatus.Text = "Activity could not be loaded. Retry; restart if another writer changed the saved inventory.";
                EquipmentActivityRefresh.Content = "Retry";
                FinishActivityRender();
            });
        }
    }

    private void RefreshAssignedCategories()
    {
        PersonAssignedDevicesList.ItemsSource = _assignedDevices.Select(device =>
        {
            var row = device.ScanResult;
            var inference = row?.UsageIdentity is { } id ? _activityDisplay?.Categories.GetValueOrDefault(id) : null;
            var category = row?.UsageCategoryOverride ?? inference?.Category;
            return device with { UsageCategoryLabel = category is null ? "Usage category unavailable"
                : $"{category} - {(row?.UsageCategoryOverride is not null ? "Manual" : "Auto")}" };
        }).ToArray();
    }

    private void UpdateEquipmentIndicator()
    {
        EquipmentOnlineDot.Visibility = _activityDisplay?.Latest.State == EquipmentScanState.Online
            ? Visibility.Visible : Visibility.Collapsed;
        EquipmentIndicator.Text = _activityDisplay is { } display
            ? EquipmentActivityPresentation.StateText(display.Latest) : "Unknown";
        EquipmentIndicatorContext.Text = _activityDisplay is { } current
            ? EquipmentActivityPresentation.Context(current.Latest, _activityNetwork, DateTimeOffset.UtcNow)
            : $"Response count unavailable | {_activityNetwork} | Scan age unavailable";
    }

    private void FinishActivityRender()
    {
        EquipmentActivityLoading.IsIndeterminate = false;
        EquipmentActivityLoading.Visibility = Visibility.Collapsed;
        RenderActivity();
        EquipmentActivityGrid.UpdateLayout();
    }

    private void RenderActivity()
    {
        if (!_activityInitialized) return;
        ActivityGridRenderer.Render(EquipmentActivityGrid, _activityDisplay?.Grid.Cells ?? [], ActualTheme, _activityColors,
            "EquipmentActivityCell", details => EquipmentActivityDetail.Text = details);
        ActivityGridRenderer.RenderCountLegend(EquipmentActivityLegend,
            _activityDisplay?.Latest.Total == 0 ? "No equipment assigned; no chart estimate."
                : _activityDisplay?.Grid.Legend ?? "Counts are unavailable until evidence is loaded.",
            _activityDisplay?.Latest.Total == 0 ? null : _activityDisplay?.Grid.Maximum, ActualTheme, _activityColors);
    }

    private void EquipmentSelection_Changed(object sender, SelectionChangedEventArgs e) => _ = LoadActivityAsync();
    private void EquipmentHours_Changed(object sender, RangeBaseValueChangedEventArgs e) => _ = LoadActivityAsync();
    private void EquipmentRefresh_Click(object sender, RoutedEventArgs e) => _ = LoadActivityAsync();

    private void EquipmentHeader_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var narrow = e.NewSize.Width < 640;
        Grid.SetRow(EquipmentActivityPeriod, narrow ? 1 : 0);
        Grid.SetColumn(EquipmentActivityPeriod, narrow ? 0 : 1);
        Grid.SetColumnSpan(EquipmentActivityPeriod, narrow ? 2 : 1);
    }
}
