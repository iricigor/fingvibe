using System.Diagnostics;
using System.Text;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;

namespace FingVibe.App;

public sealed partial class SqlEditorPage : UserControl
{
    private InventoryQueryService? _service;
    private CancellationTokenSource? _cancellation;
    private Task? _runTask;
    private bool _visible;

    public SqlEditorPage()
    {
        InitializeComponent();
        SqlText.Text = InventoryReportingSchema.Examples[0].Sql;
        ExamplePicker.ItemsSource = InventoryReportingSchema.Examples;
        ExamplePicker.SelectedIndex = 0;
        SchemaPicker.ItemsSource = InventoryReportingSchema.Views;
        SchemaPicker.SelectedIndex = 0;
        TablePicker.ItemsSource = InventoryReportingSchema.Tables;
        TablePicker.SelectedIndex = 0;
        ResultScroll.SizeChanged += (_, _) => UpdateResultWidth();
        Unloaded += (_, _) => _cancellation?.Cancel();
    }

    public event EventHandler? BackRequested;
    public bool IsRunning => _runTask is { IsCompleted: false };
    internal void Configure(string? databasePath) =>
        _service = databasePath is null ? null : new InventoryQueryService(databasePath);

    internal void Open()
    {
        _visible = true;
        SqlText.Focus(FocusState.Programmatic);
    }

    internal async Task StopAsync()
    {
        _visible = false;
        _cancellation?.Cancel();
        if (_runTask is { } task) await task;
    }

    private async void Run_Click(object sender, RoutedEventArgs e)
    {
        if (IsRunning) return;
        _runTask = RunAsync();
        await _runTask;
    }

    private async Task RunAsync()
    {
        using var cancellation = new CancellationTokenSource();
        _cancellation = cancellation;
        var clock = Stopwatch.StartNew();
        RunButton.IsEnabled = false;
        CancelButton.IsEnabled = true;
        CancelButton.Focus(FocusState.Programmatic);
        QueryProgress.IsActive = true;
        QueryProgress.Visibility = Visibility.Visible;
        ResultRows.ItemsSource = null;
        ResultHeader.Children.Clear();
        ResultScroll.Visibility = Visibility.Collapsed;
        QueryStatus.Text = "Running against saved inventory...";
        try
        {
            if (_service is null)
                throw new InvalidOperationException("Saved inventory is unavailable in this isolated UI review. Supply an explicit review inventory fixture.");
            var result = await _service.RunAsync(SqlText.Text, cancellation.Token);
            if (!_visible) return;
            var previewLimited = ShowResult(result);
            QueryStatus.Text = $"{result.Rows.Count:N0} row{(result.Rows.Count == 1 ? "" : "s")}, "
                + $"{result.Columns.Count} column{(result.Columns.Count == 1 ? "" : "s")}; {result.Elapsed.TotalMilliseconds:N0} ms. "
                + (result.Limit ?? "Complete.")
                + (previewLimited ? " Cell previews are limited to 4,096 characters; headings to 120." : "");
        }
        catch (OperationCanceledException)
        {
            QueryStatus.Text = $"Cancelled after {clock.Elapsed.TotalMilliseconds:N0} ms. No complete result.";
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException
            or InvalidOperationException or ArgumentException or TimeoutException or SqliteException)
        {
            QueryStatus.Text = $"Error after {clock.Elapsed.TotalMilliseconds:N0} ms: {exception.Message}";
        }
        finally
        {
            _cancellation = null;
            RunButton.IsEnabled = true;
            CancelButton.IsEnabled = false;
            QueryProgress.IsActive = false;
            QueryProgress.Visibility = Visibility.Collapsed;
            if (_visible) RunButton.Focus(FocusState.Programmatic);
        }
    }

    private bool ShowResult(InventoryQueryResult result)
    {
        const int width = 180;
        var previewLimited = false;
        string Preview(string value, int limit)
        {
            if (value.Length <= limit) return value;
            previewLimited = true;
            var length = char.IsHighSurrogate(value[limit - 1]) ? limit - 1 : limit;
            return value[..length] + " [preview truncated]";
        }
        ResultHeader.ColumnDefinitions.Clear();
        var template = new StringBuilder("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
            <Grid><Grid.ColumnDefinitions>
            """);
        foreach (var column in result.Columns)
        {
            ResultHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = width });
            template.Append($"<ColumnDefinition Width=\"*\" MinWidth=\"{width}\"/>");
            var heading = new TextBlock { Text = Preview(column, 120), Margin = new Thickness(8), TextWrapping = TextWrapping.Wrap };
            Grid.SetColumn(heading, ResultHeader.Children.Count);
            ResultHeader.Children.Add(heading);
        }
        template.Append("</Grid.ColumnDefinitions>");
        for (var index = 0; index < result.Columns.Count; index++)
        {
            // Only the binding index is generated; SQL values/column names never become XAML.
            template.Append($"<TextBlock Grid.Column=\"{index}\" Margin=\"8,4\" Text=\"{{Binding [{index}]}}\" "
                + $"TextTrimming=\"CharacterEllipsis\" ToolTipService.ToolTip=\"{{Binding [{index}]}}\"/>");
        }
        template.Append("</Grid></DataTemplate>");
        ResultRows.ItemTemplate = (DataTemplate)XamlReader.Load(template.ToString());
        ResultRows.MinWidth = ResultHeader.MinWidth = width * result.Columns.Count;
        UpdateResultWidth();
        ResultRows.ItemsSource = result.Rows.Select(row => row.Select(value => Preview(value ?? "NULL", 4096)).ToArray()).ToArray();
        AutomationProperties.SetHelpText(ResultRows, "Columns: " + string.Join(", ", result.Columns)
            + ". Missing values are displayed as NULL; blobs use hexadecimal.");
        ResultScroll.Visibility = Visibility.Visible;
        return previewLimited;
    }

    // A finite shared width keeps star columns aligned even inside the horizontal scroller.
    private void UpdateResultWidth() =>
        ResultContent.Width = Math.Max(ResultScroll.ActualWidth, ResultHeader.MinWidth);

    private void Cancel_Click(object sender, RoutedEventArgs e) => _cancellation?.Cancel();
    private async void Back_Click(object sender, RoutedEventArgs e)
    {
        await StopAsync();
        BackRequested?.Invoke(this, EventArgs.Empty);
    }
    private void UseExample_Click(object sender, RoutedEventArgs e)
    {
        if (ExamplePicker.SelectedItem is ReportingExample example) SqlText.Text = example.Sql;
    }
    private void Schema_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SchemaPicker.SelectedItem is not ReportingView view) return;
        SchemaDescription.Text = view.Description;
        SchemaColumns.Text = view.Columns;
    }
    private void Table_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (TablePicker.SelectedItem is not ReportingTable table) return;
        TableColumns.Text = table.Columns;
    }
}
