using FingVibe.Core.Networking;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace FingVibe.App;

public sealed partial class ServiceStatusPage : UserControl
{
    private const double NarrowTableWidth = 860;
    private readonly AccessibilitySettings _accessibility = new();
    private readonly UISettings _uiSettings = new();
    private readonly ServiceStatusPageModel _model = new(
        Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1"
            ? new ControlledServiceStatusSource(TimeProvider.System)
            : new UnconnectedServiceStatusSource(),
        TimeProvider.System);
    private CancellationTokenSource? _load;
    private bool _open;
    private bool? _narrow;

    public ServiceStatusPage()
    {
        InitializeComponent();
        Loaded += (_, _) => _uiSettings.ColorValuesChanged += ColorsChanged;
        Unloaded += (_, _) =>
        {
            _uiSettings.ColorValuesChanged -= ColorsChanged;
            StopForNavigation();
        };
        ActualThemeChanged += (_, _) => Render();
        Render();
    }

    public event EventHandler? BackRequested;

    public async Task OpenAsync()
    {
        _open = true;
        FocusRefreshButton();
        await LoadAsync(refresh: false);
    }

    public void StopForNavigation()
    {
        _open = false;
        _load?.Cancel();
    }

    private void FocusRefreshButton()
    {
        if (RefreshButton.Focus(FocusState.Programmatic)) return;
        // The page was collapsed until this open, so focus can only land after its first layout passes.
        var attempts = 0;
        void Retry(object? sender, object args)
        {
            if (!_open || !IsLoaded || RefreshButton.Focus(FocusState.Programmatic) || ++attempts >= 3)
                RefreshButton.LayoutUpdated -= Retry;
        }
        RefreshButton.LayoutUpdated += Retry;
    }

    private async Task LoadAsync(bool refresh)
    {
        _load?.Cancel();
        using var load = _load = new CancellationTokenSource();
        RefreshButton.IsEnabled = false;
        RefreshProgress.IsActive = true;
        RetrievalText.Text = "Retrieving provider reports...";
        try
        {
            await _model.LoadAsync(refresh, load.Token);
        }
        catch (OperationCanceledException) when (load.IsCancellationRequested)
        {
        }
        finally
        {
            if (ReferenceEquals(_load, load))
            {
                _load = null;
                RefreshButton.IsEnabled = true;
                RefreshProgress.IsActive = false;
                Render();
            }
        }
    }

    private void ColorsChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(Render);

    private void BackButton_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);

    private async void RefreshButton_Click(object sender, RoutedEventArgs e) => await LoadAsync(refresh: true);

    private void FilterBar_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        _model.Filter = sender.SelectedItem == ConsumerFilter ? ServiceStatusFilter.Consumer
            : sender.SelectedItem == InfrastructureFilter ? ServiceStatusFilter.Infrastructure
            : ServiceStatusFilter.All;
        RenderEntries();
    }

    private void TableCard_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var narrow = e.NewSize.Width < NarrowTableWidth;
        if (_narrow == narrow) return;
        _narrow = narrow;
        Grid.SetRow(RegionText, narrow ? 1 : 0);
        Grid.SetColumn(RegionText, narrow ? 0 : 1);
        Grid.SetColumnSpan(RegionText, narrow ? 3 : 1);
        Grid.SetRow(RefreshControls, narrow ? 2 : 0);
        Grid.SetColumn(RefreshControls, narrow ? 0 : 2);
        Grid.SetColumnSpan(RefreshControls, narrow ? 3 : 1);
        Grid.SetRow(RetrievalText, narrow ? 1 : 0);
        Grid.SetColumn(RetrievalText, narrow ? 0 : 1);
        RenderEntries();
    }

    private void Render()
    {
        if (_load is null) RetrievalText.Text = _model.RetrievalText;
        SummaryText.Text = _model.Summary;
        RequestErrorText.Text = _model.RequestError ?? "";
        RequestErrorText.Visibility = _model.RequestError is null ? Visibility.Collapsed : Visibility.Visible;
        RenderEntries();
    }

    private void RenderEntries()
    {
        var narrow = _narrow == true;
        HeaderRow.Visibility = narrow ? Visibility.Collapsed : Visibility.Visible;
        if (HeaderRow.ColumnDefinitions.Count == 0) ApplyColumns(HeaderRow);
        EntriesPanel.Children.Clear();
        var rows = _model.VisibleRows;
        var groups = rows.GroupBy(row => row.Entry.Provider).ToList();
        for (var index = 0; index < groups.Count; index++)
        {
            var group = new StackPanel
            {
                Style = RowStyle("ServiceStatusGroupStyle"),
                BorderThickness = new Thickness(0, 0, 0, index == groups.Count - 1 ? 0 : 1)
            };
            var first = true;
            foreach (var row in groups[index])
            {
                group.Children.Add(narrow ? NarrowEntry(row) : WideEntry(row, first));
                first = false;
            }
            EntriesPanel.Children.Add(group);
        }
    }

    private static void ApplyColumns(Grid grid)
    {
        foreach (var width in new[]
        {
            new GridLength(140), new GridLength(1.1, GridUnitType.Star), new GridLength(130),
            new GridLength(1.5, GridUnitType.Star), new GridLength(1.4, GridUnitType.Star), new GridLength(130)
        })
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }
    }

    private Grid WideEntry(ServiceStatusRow row, bool showProvider)
    {
        var grid = new Grid { Padding = new Thickness(20, 10, 20, 10), ColumnSpacing = 16 };
        ApplyColumns(grid);
        if (showProvider)
            grid.Children.Add(new TextBlock
            {
                Text = row.Entry.Provider, FontSize = 16, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center
            });
        Add(grid, ServiceText(row, row.Entry.Service), 1);
        Add(grid, CategoryChip(row), 2);
        Add(grid, Report(row), 3);
        Add(grid, Source(row), 4);
        Add(grid, Link(row), 5);
        return grid;
    }

    private StackPanel NarrowEntry(ServiceStatusRow row)
    {
        var panel = new StackPanel { Padding = new Thickness(16, 12, 16, 12), Spacing = 8 };
        var heading = new Grid { ColumnSpacing = 12 };
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        heading.Children.Add(ServiceText(row, $"{row.Entry.Provider} - {row.Entry.Service}", FontWeights.SemiBold));
        Add(heading, CategoryChip(row), 1);
        panel.Children.Add(heading);
        panel.Children.Add(Report(row));
        panel.Children.Add(Source(row));
        panel.Children.Add(Link(row));
        return panel;
    }

    private static void Add(Grid grid, FrameworkElement element, int column)
    {
        Grid.SetColumn(element, column);
        grid.Children.Add(element);
    }

    private static TextBlock ServiceText(ServiceStatusRow row, string text, Windows.UI.Text.FontWeight? weight = null)
    {
        var block = new TextBlock
        {
            Text = text, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center,
            FontWeight = weight ?? FontWeights.Normal
        };
        AutomationProperties.SetAutomationId(block, $"ServiceStatusService-{row.Entry.Id}");
        AutomationProperties.SetHelpText(block, row.AccessibleName);
        return block;
    }

    private Border CategoryChip(ServiceStatusRow row) => new()
    {
        Style = RowStyle("ServiceStatusChipStyle"),
        HorizontalAlignment = HorizontalAlignment.Left,
        VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock { Text = row.CategoryText, FontSize = 12 }
    };

    private Grid Report(ServiceStatusRow row)
    {
        var grid = new Grid { ColumnSpacing = 8, VerticalAlignment = VerticalAlignment.Center };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        // Neutral and high-contrast states use theme styles; color alone never carries the state.
        var themed = row.Tone == ServiceStatusTone.Neutral || _accessibility.HighContrast;
        var dot = new Ellipse
        {
            Width = 8, Height = 8, Margin = new Thickness(0, 7, 0, 0), VerticalAlignment = VerticalAlignment.Top,
            IsHitTestVisible = false
        };
        if (row.Tone == ServiceStatusTone.Neutral) dot.Style = RowStyle("ServiceStatusNeutralDotStyle");
        else if (themed) dot.Style = RowStyle("ServiceStatusHighContrastDotStyle");
        else dot.Fill = ToneBrush(row.Tone);
        AutomationProperties.SetAccessibilityView(dot, AccessibilityView.Raw);
        grid.Children.Add(dot);
        var text = new StackPanel { Spacing = 2 };
        var headline = new TextBlock { Text = row.Headline, Style = RowStyle("ServiceStatusPrimaryHeadlineStyle") };
        if (!themed) headline.Foreground = ToneBrush(row.Tone);
        AutomationProperties.SetAutomationId(headline, $"ServiceStatusReport-{row.Entry.Id}");
        text.Children.Add(headline);
        var detail = new TextBlock { Text = row.Detail, Style = RowStyle("ServiceStatusSecondaryTextStyle") };
        AutomationProperties.SetAutomationId(detail, $"ServiceStatusDetail-{row.Entry.Id}");
        text.Children.Add(detail);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return grid;
    }

    private StackPanel Source(ServiceStatusRow row)
    {
        var panel = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock { Text = row.SourceLine, FontSize = 13, TextWrapping = TextWrapping.Wrap });
        var timestamp = new TextBlock { Text = row.TimestampLine, Style = RowStyle("ServiceStatusSecondaryTextStyle") };
        AutomationProperties.SetAutomationId(timestamp, $"ServiceStatusTimestamp-{row.Entry.Id}");
        panel.Children.Add(timestamp);
        return panel;
    }

    private static HyperlinkButton Link(ServiceStatusRow row)
    {
        var link = new HyperlinkButton
        {
            Content = row.LinkLabel, NavigateUri = row.Link, Padding = new Thickness(0, 4, 0, 4),
            VerticalAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetName(link, $"{row.LinkLabel} for {row.Entry.Provider} {row.Entry.Service} (opens in browser)");
        AutomationProperties.SetAutomationId(link, $"ServiceStatusLink-{row.Entry.Id}");
        ToolTipService.SetToolTip(link, row.Link.AbsoluteUri);
        return link;
    }

    private SolidColorBrush ToneBrush(ServiceStatusTone tone)
    {
        var dark = ActualTheme == ElementTheme.Dark;
        return new SolidColorBrush(tone == ServiceStatusTone.Good
            ? dark ? Color.FromArgb(255, 108, 203, 95) : Color.FromArgb(255, 15, 123, 15)
            : dark ? Color.FromArgb(255, 252, 225, 0) : Color.FromArgb(255, 157, 93, 0));
    }

    private Style RowStyle(string key) => (Style)Resources[key];
}
