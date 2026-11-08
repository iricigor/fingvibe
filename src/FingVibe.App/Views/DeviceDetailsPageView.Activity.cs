using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Windows.UI.ViewManagement;
using Path = Microsoft.UI.Xaml.Shapes.Path;
using Colors = Microsoft.UI.Colors;

namespace FingVibe.App.Views;

public sealed partial class DeviceDetailsPageView
{
    private Func<int, int, CancellationToken, Task<ActivityBuckets>>? _activityLoader;
    private string? _activitySourceKey;
    private string? _activityUnavailable;
    private bool _activitySourceLoading;
    private bool _activityActive;
    private bool _activityInitialized;
    private CancellationTokenSource? _activityCancellation;
    private int _activityGeneration;
    private IReadOnlyList<DeviceActivityCell> _activityCells = [];
    private readonly List<Button> _activityButtons = [];
    private readonly UISettings _activityColors = new();
    private (DateOnly Date, string Zone)? _activityDate;

    private void InitializeActivity()
    {
        _activityInitialized = true;
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
        if (_activityActive == active) return;
        _activityActive = active;
        if (active) _ = LoadActivityAsync();
        else CancelActivity();
    }

    private void CancelActivity()
    {
        _activityGeneration++;
        _activityCancellation?.Cancel();
        _activityCells = [];
        _activityDate = null;
        ActivityLoading.IsIndeterminate = false;
        ActivityLoading.Visibility = Visibility.Collapsed;
        ActivityDetail.Text = ActivityWindow.Text = ActivityLegend.Text = string.Empty;
        RenderActivity();
    }

    private void RefreshActivityDate()
    {
        if (!_activityActive) return;
        TimeZoneInfo.ClearCachedData();
        var zone = TimeZoneInfo.Local;
        var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow, zone).DateTime);
        if (_activityDate is { } previous && previous != (date, zone.Id)) _ = LoadActivityAsync();
    }

    private async Task LoadActivityAsync()
    {
        if (!_activityInitialized || !_activityActive) return;
        CancelActivity();
        var generation = _activityGeneration;
        var hours = (int)ActivityHours.Value;
        var weekdays = ActivityPeriod.SelectedIndex == 2;
        var days = ActivityPeriod.SelectedIndex == 0 ? 7 : 30;
        ActivityHoursLabel.Text = $"Group hours: {hours} {(hours == 1 ? "hour" : "hours")} per cell";
        ActivityError.IsOpen = false;
        ActivityRefresh.Content = "Refresh activity";
        ActivityStatus.Text = _activityUnavailable ?? "Loading completed scan evidence...";
        if (_activityLoader is not { } loader)
        {
            ActivityLoading.Visibility = _activitySourceLoading ? Visibility.Visible : Visibility.Collapsed;
            ActivityLoading.IsIndeterminate = _activitySourceLoading;
            return;
        }
        ActivityLoading.Visibility = Visibility.Visible;
        ActivityLoading.IsIndeterminate = true;
        RenderActivityLoading(hours);
        using var cancellation = new CancellationTokenSource();
        _activityCancellation = cancellation;
        try
        {
            var (buckets, cells) = await Task.Run(async () =>
            {
                var result = await loader(days, hours, cancellation.Token);
                cancellation.Token.ThrowIfCancellationRequested();
                return (result, DeviceActivityPresentation.Cells(result, weekdays));
            }, cancellation.Token);
            if (!_activityActive || generation != _activityGeneration || cancellation.IsCancellationRequested) return;
            _activityCells = cells;
            _activityDate = (buckets.LastDate, buckets.TimeZoneId);
            ActivityWindow.Text = $"{buckets.FirstDate:d MMM yyyy} - {buckets.LastDate:d MMM yyyy} ({days} calendar dates) | " +
                $"Local time: {buckets.TimeZoneId} | Today through {TimeZoneInfo.ConvertTimeBySystemTimeZoneId(buckets.QueryTime, buckets.TimeZoneId):HH:mm}; later hours are unknown.";
            var known = buckets.Days.Count(bucket => bucket.Devices[0].Eligible > 0);
            ActivityStatus.Text = known == 0
                ? "No completed scan history for this selection. Imported details do not provide scan evidence."
                : $"Scan evidence in {known} daily time cells. Gaps remain unknown; no continuity is inferred.";
            RenderActivity();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidOperationException or ArgumentException or TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            if (!_activityActive || generation != _activityGeneration) return;
            ActivityError.Message = $"Saved evidence is unavailable. No results are shown for this selection. {exception.Message}";
            ActivityError.IsOpen = true;
            ActivityStatus.Text = "Activity could not be loaded. Retry; restart if another writer changed the saved inventory.";
            ActivityRefresh.Content = "Retry";
            RenderActivity();
        }
        finally
        {
            if (ReferenceEquals(_activityCancellation, cancellation)) _activityCancellation = null;
            if (generation == _activityGeneration)
            {
                ActivityLoading.IsIndeterminate = false;
                ActivityLoading.Visibility = Visibility.Collapsed;
            }
        }
    }

    private void ActivityPeriod_SelectionChanged(object sender, SelectionChangedEventArgs e) => _ = LoadActivityAsync();
    private void ActivityHours_ValueChanged(object sender, RangeBaseValueChangedEventArgs e) => _ = LoadActivityAsync();
    private void ActivityRefresh_Click(object sender, RoutedEventArgs e) => _ = LoadActivityAsync();

    private void RenderActivityLoading(int hours)
    {
        ActivityGrid.MinWidth = 0;
        for (var column = 0; column < 24 / hours; column++)
            ActivityGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var row = 0; row < 3; row++)
        {
            ActivityGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(24) });
            for (var column = 0; column < 24 / hours; column++)
            {
                var placeholder = new Border { Background = new SolidColorBrush(_activityColors.GetColorValue(UIColorType.Foreground)), Opacity = .12 };
                Grid.SetRow(placeholder, row);
                Grid.SetColumn(placeholder, column);
                ActivityGrid.Children.Add(placeholder);
            }
        }
    }

    private void RenderActivity()
    {
        if (!_activityInitialized) return;
        ActivityGrid.Children.Clear();
        ActivityGrid.RowDefinitions.Clear();
        ActivityGrid.ColumnDefinitions.Clear();
        _activityButtons.Clear();
        if (_activityCells.Count == 0) return;
        var columns = 24 / _activityCells[0].Hours;
        var rows = _activityCells.Count / columns;
        var scale = _activityColors.TextScaleFactor;
        ActivityGrid.MinWidth = (124 + columns * 36) * scale;
        ActivityGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120 * scale) });
        for (var column = 0; column < columns; column++)
            ActivityGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var row = 0; row <= rows; row++)
            ActivityGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = new Grid { MinHeight = 24 * scale };
        for (var column = 0; column < columns; column++)
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var column = 0; column < columns; column++)
        {
            var hour = column * _activityCells[0].Hours;
            if (hour % 3 != 0 && columns > 12) continue;
            var label = new TextBlock { Text = $"{hour:00}:00", FontSize = 11 };
            Grid.SetColumn(label, column);
            header.Children.Add(label);
        }
        var end = new TextBlock { Text = "24:00", FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right };
        Grid.SetColumn(end, columns - 1);
        header.Children.Add(end);
        Grid.SetColumn(header, 1);
        Grid.SetColumnSpan(header, columns);
        ActivityGrid.Children.Add(header);
        var contrast = new AccessibilitySettings().HighContrast;
        RenderActivityLegend(contrast);
        for (var row = 0; row < rows; row++)
        {
            var first = _activityCells[row * columns];
            var label = new TextBlock { Text = $"{first.RowLabel} {first.RowTotal}".TrimEnd(),
                FontSize = rows > 7 ? 11 : 13, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
            Grid.SetRow(label, row + 1);
            ActivityGrid.Children.Add(label);
            for (var column = 0; column < columns; column++)
            {
                var index = row * columns + column;
                var cell = _activityCells[index];
                var background = CellColor(cell, contrast);
                var foreground = contrast ? _activityColors.GetColorValue(UIColorType.Foreground) : TextColor(background);
                var content = new Grid { MinWidth = 28, MinHeight = rows > 7 ? 22 : 32,
                    Background = new SolidColorBrush(background) };
                if (cell.Hatched)
                {
                    var hatch = new Path
                    {
                        Stretch = Stretch.Fill, Opacity = contrast ? 1 : .45,
                        Stroke = new SolidColorBrush(foreground), StrokeThickness = .7,
                        Data = HatchGeometry()
                    };
                    content.Children.Add(hatch);
                }
                content.Children.Add(new TextBlock
                {
                    Text = contrast && cell.IsApplicable && string.IsNullOrEmpty(cell.Value)
                        ? cell.Response == AnalyticsResponse.Responded ? "R" : cell.Response == AnalyticsResponse.DidNotRespond ? "N" : "?"
                        : cell.Value,
                    FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                    Foreground = new SolidColorBrush(foreground)
                });
                var button = new Button
                {
                    Content = content, Padding = new Thickness(0), CornerRadius = new CornerRadius(0),
                    HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
                    Tag = index
                };
                AutomationProperties.SetAutomationId(button, $"ActivityCell-{row}-{column}");
                AutomationProperties.SetName(button, cell.Details);
                ToolTipService.SetToolTip(button, cell.Details);
                button.Click += (_, _) => ActivityDetail.Text = cell.Details;
                button.GotFocus += (_, _) =>
                {
                    ActivityDetail.Text = cell.Details;
                    button.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
                };
                button.KeyDown += ActivityCell_KeyDown;
                _activityButtons.Add(button);
                Grid.SetRow(button, row + 1);
                Grid.SetColumn(button, column + 1);
                ActivityGrid.Children.Add(button);
            }
        }
    }

    private Color CellColor(DeviceActivityCell cell, bool contrast)
    {
        if (contrast) return _activityColors.GetColorValue(UIColorType.Background);
        if (!cell.IsApplicable) return ActualTheme == ElementTheme.Dark ? Color.FromArgb(255, 32, 32, 32) : Colors.White;
        if (cell.Response == AnalyticsResponse.Unknown)
            return ActualTheme == ElementTheme.Dark ? Color.FromArgb(255, 55, 60, 67) : Color.FromArgb(255, 233, 237, 241);
        if (cell.Response == AnalyticsResponse.DidNotRespond) return Color.FromArgb(255, 100, 116, 139);
        var fraction = (double)(cell.Fraction ?? 0);
        var low = ActualTheme == ElementTheme.Dark ? Color.FromArgb(255, 38, 60, 47) : Color.FromArgb(255, 206, 232, 216);
        return Color.FromArgb(255, (byte)(low.R + (21 - low.R) * fraction),
            (byte)(low.G + (114 - low.G) * fraction), (byte)(low.B + (60 - low.B) * fraction));
    }

    private static Color TextColor(Color background)
    {
        static double Linear(byte value) => value / 255d <= .04045 ? value / 255d / 12.92 : Math.Pow((value / 255d + .055) / 1.055, 2.4);
        var luminance = .2126 * Linear(background.R) + .7152 * Linear(background.G) + .0722 * Linear(background.B);
        return luminance > .179 ? Colors.Black : Colors.White;
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
                ? _activityColors.GetColorValue(UIColorType.Foreground) : CellColor(sample, false)) });
            ActivityLegend.Inlines.Add(new Run { Text = weekdays ? $"{fraction:P0}  "
                : fraction == 1 ? "At least one response  " : "Scanned, no response  " });
        }
        ActivityLegend.Inlines.Add(new Run { Text = weekdays
            ? "of applicable dates responded. Hatching: some dates unknown. -: not applicable."
            : "Hatching: Unknown - no eligible scans. -: not applicable." });
        if (contrast) ActivityLegend.Inlines.Add(new Run { Text = " R: response; N: nonresponse; ?: unknown." });
    }

    private static PathGeometry HatchGeometry()
    {
        var geometry = new PathGeometry();
        for (var offset = -24; offset <= 24; offset += 6)
        {
            var figure = new PathFigure { StartPoint = new Point(Math.Max(0, offset), Math.Max(0, -offset)), IsClosed = false };
            figure.Segments.Add(new LineSegment { Point = new Point(Math.Min(24, offset + 24), Math.Min(24, 24 - offset)) });
            geometry.Figures.Add(figure);
        }
        return geometry;
    }

    private void ActivityCell_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (sender is not Button { Tag: int index } || _activityCells.Count == 0) return;
        var columns = 24 / _activityCells[0].Hours;
        var next = e.Key switch
        {
            VirtualKey.Left => index - 1, VirtualKey.Right => index + 1,
            VirtualKey.Up => index - columns, VirtualKey.Down => index + columns,
            VirtualKey.Home => index / columns * columns, VirtualKey.End => (index / columns + 1) * columns - 1,
            _ => index
        };
        if (next == index) return;
        e.Handled = true;
        _activityButtons[Math.Clamp(next, 0, _activityButtons.Count - 1)].Focus(FocusState.Keyboard);
    }
}
