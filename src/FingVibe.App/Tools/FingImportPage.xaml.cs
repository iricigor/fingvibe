using System.Security.Cryptography;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Documents;
using Windows.UI.Text;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace FingVibe.App;

public sealed partial class FingImportPage : UserControl
{
    private Func<DeviceInventoryData>? _getData;
    private Func<bool>? _canEdit;
    private Func<FingImportAnalysis, Task<string>>? _import;
    private nint _windowHandle;
    private StorageFile? _file;
    private byte[]? _fileHash;
    private FingExport? _export;
    private FingImportAnalysis? _analysis;
    private readonly HashSet<string> _replacements = [];
    private readonly HashSet<string> _selected = [];
    private readonly Dictionary<string, string> _completed = [];
    private readonly List<Button> _managementButtons = [];
    private bool _selectionMode;
    private bool _busy;
    private int _fileGeneration;

    public FingImportPage()
    {
        InitializeComponent();
        LimitationsText.Text = $"Import limitations: {FingExport.Limitations}";
        ExportHelpText.Text = "Fing Web App: open the network Setup view, choose Export, then Send to email your network inventory spreadsheet. "
            + "Download the .xlsx attachment to this PC. Fing's Network View documentation also describes sending an Excel export from the network page; "
            + "desktop and mobile controls vary by version and subscription, so identical menus are not assumed. "
            + "If your app does not offer Excel export, use the Web App export where available. "
            + "Only .xlsx workbooks with a Devices sheet and MAC column are supported, not CSV, PDF, or text. Owner maps to Person and Location to Room; Group and event history are not imported.";
    }

    public event EventHandler? BackRequested;
    public event EventHandler<string>? ManagementRequested;

    internal void Configure(Func<DeviceInventoryData> getData, Func<bool> canEdit,
        Func<FingImportAnalysis, Task<string>> import, nint windowHandle)
    {
        _getData = getData;
        _canEdit = canEdit;
        _import = import;
        _windowHandle = windowHandle;
    }

    internal void Open()
    {
        if (Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1" && _export is null)
        {
            SelectedFileText.Text = "Synthetic Fing export.xlsx";
            _export = new FingExport(
                [
                    new(2, "020000000001", new(Name: "1\uFE0F\u20E3 Review workstation", Type: "Desktop", OperatingSystem: "Windows"), null, null),
                    new(3, "020000000002", new(Name: "Review speaker", Type: "Speaker/Amp", Brand: "Example", Model: "Speaker", Address: "192.0.2.20"), null, "Missing review room"),
                    new(4, "020000000003", new(Name: "Review controller", Hostname: "controller.local", Type: "Controller", Address: "192.0.2.20"), "Missing review person", null)
                ], [], 3)
            {
                Diagnostics = [new("Private/randomized MACs", "Synthetic preview: locally administered MACs may change.", IsWarning: false)]
            };
            AnalyzeCurrent();
        }
        SetBusy(_busy);
    }

    internal void InvalidateAnalysis(string reason)
    {
        _analysis = null;
        SetFileAnalyzed(false);
        _replacements.Clear();
        ImportButton.IsEnabled = false;
        ChangesList.IsEnabled = false;
        SelectionModeButton.IsEnabled = false;
        ImportHeadingText.Text = "Analysis needs refreshing";
        ImportSummaryText.Text = reason;
    }

    private async void Browse_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        try
        {
            var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
            picker.FileTypeFilter.Add(".xlsx");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, _windowHandle);
            var file = await picker.PickSingleFileAsync();
            if (file is not null) await ChooseFileAsync(file);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            FileStatusText.Text = $"The file picker could not open: {exception.Message}. You can also drag and drop a .xlsx file.";
        }
    }

    private void File_DragOver(object sender, DragEventArgs e)
    {
        e.AcceptedOperation = !_busy && e.DataView.Contains(StandardDataFormats.StorageItems)
            ? DataPackageOperation.Copy : DataPackageOperation.None;
    }

    private async void File_Drop(object sender, DragEventArgs e)
    {
        if (_busy) return;
        var deferral = e.GetDeferral();
        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            if (items.Count != 1 || items[0] is not StorageFile file)
            {
                InvalidateAnalysis("Drop exactly one Fing .xlsx file, not a folder.");
                FileStatusText.Text = "Drop exactly one Fing .xlsx file, not a folder.";
                return;
            }
            await ChooseFileAsync(file);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            InvalidateAnalysis("The dropped file could not be read. Choose it again.");
            FileStatusText.Text = $"The dropped file could not be read: {exception.Message}";
        }
        finally { deferral.Complete(); }
    }

    private async Task ChooseFileAsync(StorageFile file)
    {
        var generation = ++_fileGeneration;
        _file = file;
        _export = null;
        _fileHash = null;
        _selected.Clear();
        _completed.Clear();
        _selectionMode = false;
        InvalidateAnalysis("A different file was selected.");
        ChangesList.Items.Clear();
        AnalysisGroups.Children.Clear();
        _managementButtons.Clear();
        CompletedExpander.Visibility = UnchangedExpander.Visibility = Visibility.Collapsed;
        SelectedFileText.Text = file.Name;
        SetBusy(true);
        try
        {
            if (!file.FileType.Equals(".xlsx", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Only Fing Excel exports (.xlsx) are supported.");
            var bytes = await ReadFileAsync(file);
            var export = await Task.Run(() => FingWorkbookReader.Read(new MemoryStream(bytes)));
            if (generation != _fileGeneration) return;
            _fileHash = SHA256.HashData(bytes);
            _export = export;
            FileStatusText.Text = "Devices sheet found. Analysis is read-only.";
            AnalyzeCurrent();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            FileStatusText.Text = $"Unable to analyze {file.Name}: {exception.Message}";
            AnalysisCountsText.Text = "Analysis failed. Choose a supported Fing export.";
        }
        finally { SetBusy(false); }
    }

    private static async Task<byte[]> ReadFileAsync(StorageFile file)
    {
        using var stream = await file.OpenStreamForReadAsync();
        if (stream.Length > 10 * 1024 * 1024)
            throw new InvalidDataException("The workbook exceeds the 10 MB limit. Export a smaller inventory.");
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int read;
        while ((read = await stream.ReadAsync(chunk)) > 0)
        {
            if (buffer.Length + read > 10 * 1024 * 1024)
                throw new InvalidDataException("The workbook exceeds the 10 MB limit.");
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }

    private async void Analyze_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        if (_file is null) { AnalyzeCurrent(); return; }
        SetBusy(true);
        try
        {
            var bytes = await ReadFileAsync(_file);
            if (_fileHash is not null && SHA256.HashData(bytes).SequenceEqual(_fileHash))
                AnalyzeCurrent();
            else
                await ChooseFileAsync(_file);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            InvalidateAnalysis($"Unable to refresh analysis: {exception.Message}");
        }
        finally { SetBusy(false); }
    }

    private void AnalyzeCurrent()
    {
        if (_export is null || _getData is null || _canEdit?.Invoke() != true)
        {
            InvalidateAnalysis("Wait for saved data and any scan to finish loading, then analyze again.");
            return;
        }
        _analysis = FingImportAnalyzer.Analyze(_export, _getData(), _replacements);
        SetFileAnalyzed(true);
        AnalysisCountsText.Text = $"{_analysis.DeviceRows:N0} devices in export · {_analysis.Matched:N0} matched by MAC · "
            + $"{_analysis.Added:N0} new / Fing Only · {_analysis.Warnings.Count:N0} warnings";
        var validKeys = _analysis.Changes.Where(change => change.CanChoose).Select(change => change.Key).ToHashSet();
        _replacements.IntersectWith(validKeys);
        _selected.IntersectWith(_analysis.Devices.Where(device => device.CanImport).Select(device => device.Mac));
        RenderAnalysis();
        RenderDevices();
        ImportHeadingText.Text = _analysis.CanImport ? "Ready to import reviewed changes" : "No eligible changes";
        ImportSummaryText.Text = $"{_analysis.Added:N0} new devices · {_analysis.AppliedFields:N0} fields to apply · "
            + $"{_analysis.SkippedFields:N0} fields skipped or kept. Blank fields never clear saved values.";
        UpdateActions();
    }

    private static TextBlock Text(string value, bool heading = false) => new()
    {
        Text = value,
        TextWrapping = TextWrapping.Wrap,
        FontWeight = heading ? FontWeights.SemiBold : FontWeights.Normal
    };

    private void SetFileAnalyzed(bool analyzed)
    {
        SelectedFileLabel.Style = (Style)Resources[analyzed ? "ImportAnalyzedFileLabelStyle" : "ImportFileLabelStyle"];
        AutomationProperties.SetHelpText(SelectedFileText, analyzed ? "File analyzed successfully." : "File analysis is not current.");
    }

    private void RenderAnalysis()
    {
        AnalysisGroups.Children.Clear();
        _managementButtons.Clear();
        foreach (var group in _analysis!.Groups)
        {
            var header = new Grid { ColumnSpacing = 12 };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var heading = Text(group.Category + (group.HasWarnings ? " — Review" : group.Category is "People" or "Rooms" ? " — OK" : " — Information"), true);
            heading.VerticalAlignment = VerticalAlignment.Center;
            header.Children.Add(heading);
            var body = new StackPanel { Spacing = 6 };
            body.Children.Add(Text(group.Summary));
            if (group.Category is "People" or "Rooms")
            {
                var button = new Button
                {
                    Content = group.Category == "People" ? "Manage people" : "Manage rooms",
                    Tag = group.Category,
                    HorizontalAlignment = HorizontalAlignment.Right,
                    VerticalAlignment = VerticalAlignment.Center
                };
                button.Click += Manage_Click;
                _managementButtons.Add(button);
                Grid.SetColumn(button, 1);
                header.Children.Add(button);
            }
            if (group.Details.Count > 0)
            {
                body.Children.Add(new Expander
                {
                    Header = $"Details ({group.Details.Count})",
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch,
                    Content = Text(string.Join(Environment.NewLine, group.Details))
                });
            }
            var panel = new StackPanel { Spacing = 6 };
            panel.Children.Add(header);
            panel.Children.Add(body);
            AnalysisGroups.Children.Add(new Border
            {
                Style = (Style)Application.Current.Resources["ScannerSummaryCardStyle"],
                Child = panel
            });
        }
    }

    private void RenderDevices()
    {
        var offset = ImportScroll.VerticalOffset;
        ChangesList.Items.Clear();
        if (_analysis is null) return;
        foreach (var device in _analysis.Devices.Where(device => device.IsNew || device.Changes.Count > 0))
        {
            var card = new StackPanel();
            var body = new StackPanel { Spacing = 8, Margin = new Thickness(16) };
            var header = new Grid { ColumnSpacing = 12 };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var identity = new RichTextBlock { IsTextSelectionEnabled = true, IsColorFontEnabled = true, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAutomationId(identity, $"ImportHeader-{device.Mac}");
            var title = new Paragraph();
            title.Inlines.Add(new Run
            {
                Text = device.Name,
                FontWeight = FontWeights.Bold,
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe UI Emoji")
            });
            title.Inlines.Add(new Run { Text = " · " });
            title.Inlines.Add(new Run
            {
                Text = string.Join("-", Enumerable.Range(0, 6).Select(index => device.Mac.Substring(index * 2, 2))),
                FontWeight = FontWeights.Bold
            });
            title.Inlines.Add(new Run { Text = $" · {device.AdditionCount} additions · " });
            var conflicts = device.ConflictCount;
            if (conflicts > 0)
            {
                var count = Text($"! {conflicts} conflicts");
                count.Style = (Style)Resources["ImportConflictCountStyle"];
                AutomationProperties.SetName(count, $"{device.Mac}: {conflicts} conflicts");
                title.Inlines.Add(new InlineUIContainer { Child = count });
            }
            else
                title.Inlines.Add(new Run { Text = "0 conflicts" });
            title.Inlines.Add(new Run { Text = $" · {device.SkippedCount} skipped" });
            if (_completed.ContainsKey(device.Mac))
                title.Inlines.Add(new Run { Text = " · Imported with remaining items" });
            identity.Blocks.Add(title);
            header.Children.Add(identity);
            FrameworkElement action;
            if (_selectionMode)
            {
                var check = new CheckBox { Content = "Select device", IsChecked = _selected.Contains(device.Mac), IsEnabled = device.CanImport };
                AutomationProperties.SetName(check, $"Select {device.Mac}");
                check.Checked += (_, _) => { _selected.Add(device.Mac); UpdateActions(); };
                check.Unchecked += (_, _) => { _selected.Remove(device.Mac); UpdateActions(); };
                action = check;
            }
            else
            {
                var button = new Button { Content = "Import device", IsEnabled = device.CanImport };
                AutomationProperties.SetName(button, $"Import device {device.Mac}");
                button.Click += async (_, _) => await ImportDevicesAsync(new HashSet<string> { device.Mac });
                action = button;
            }
            action.VerticalAlignment = VerticalAlignment.Top;
            Grid.SetColumn(action, 1);
            header.Children.Add(action);
            card.Children.Add(new Border { Style = (Style)Resources["ImportDeviceHeaderStyle"], Child = header });
            card.Children.Add(body);
            foreach (var fields in new[]
            {
                new[] { "Name", "Hostname" },
                new[] { "Type", "Brand", "Family", "Model" },
                new[] { "OS", "OS version", "Imported IP" },
                new[] { "Person", "Room" },
                new[] { "Device type correction", "OS correction" }
            })
            {
                var changes = fields.Select(field => device.Changes.FirstOrDefault(change => change.Field == field))
                    .OfType<FingImportChange>().ToArray();
                if (changes.Length > 0) body.Children.Add(FieldRow(changes, device.Mac));
            }
            if (device.HasPrivateMac || device.HasLimitedInformation)
            {
                var note = Text((device.HasLimitedInformation ? "Limited information: this export contains only a MAC address and historical Fing IP. " : "")
                    + (device.HasPrivateMac ? "Private MAC address: this device uses a locally administered MAC, which may change. " : "")
                    + "If you don't recognize this device, we recommend leaving it out of the import. "
                    + "Use Select devices and leave it unchecked; Import all includes every eligible device.");
                note.FontSize = 12;
                AutomationProperties.SetAutomationId(note, $"{(device.HasPrivateMac ? "PrivateMacNotice" : "LimitedInformationNotice")}-{device.Mac}");
                body.Children.Add(note);
            }
            ChangesList.Items.Add(new Border
            {
                Style = (Style)Application.Current.Resources["ScannerSummaryCardStyle"],
                Padding = new Thickness(0),
                Margin = new Thickness(0, 4, 0, 4),
                Child = card
            });
        }
        var unchanged = _analysis.Devices.Where(device => !device.IsNew && device.Changes.Count == 0 && !_completed.ContainsKey(device.Mac)).ToArray();
        UnchangedText.Text = string.Join(Environment.NewLine, unchanged.Select(device => $"{device.Name} · {device.Mac}"));
        UnchangedExpander.Header = $"No changes ({unchanged.Length})";
        UnchangedExpander.Visibility = unchanged.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        CompletedText.Text = string.Join(Environment.NewLine, _completed.Values);
        CompletedExpander.Header = $"Imported this session ({_completed.Count})";
        CompletedExpander.Visibility = _completed.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        DispatcherQueue.TryEnqueue(() => ImportScroll.ChangeView(null, offset, null, true));
    }

    private RichTextBlock FieldRow(IReadOnlyList<FingImportChange> changes, string mac)
    {
        var row = new RichTextBlock { IsTextSelectionEnabled = true, IsColorFontEnabled = true };
        AutomationProperties.SetAutomationId(row, $"ImportFields-{mac}-{changes[0].Field}");
        var paragraph = new Paragraph();
        foreach (var change in changes)
        {
            var field = new Grid { ColumnSpacing = 6, MinHeight = 32, Margin = new Thickness(0, 0, 12, 0) };
            field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var label = Text(change.Field == "Imported IP" ? "Fing IP" : change.Field);
            label.FontSize = 12;
            var chip = new Border { Style = (Style)Resources["ImportFieldChipStyle"], Margin = new Thickness(0),
                Child = label, VerticalAlignment = VerticalAlignment.Center };
            field.Children.Add(chip);
            var value = Text((change.Conflict ? change.BeforeAfter : change.Incoming)
                + (change.SkipReason is not null ? $" — Skipped: {change.SkipReason}" : ""));
            value.VerticalAlignment = VerticalAlignment.Center;
            value.IsTextSelectionEnabled = true;
            value.IsColorFontEnabled = true;
            AutomationProperties.SetAutomationId(value, $"ImportValue-{change.Key}");
            if (change.Field is "Name" or "Person" or "Room") value.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe UI Emoji");
            Grid.SetColumn(value, 1);
            field.Children.Add(value);
            if (change.Field == "Imported IP")
                ToolTipService.SetToolTip(chip, "Historical address from the Fing export, not a local observation or scan target.");
            ComboBox? picker = null;
            if (change.CanChoose)
            {
                field.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                picker = new ComboBox { Tag = change.Key, MinWidth = 180, VerticalAlignment = VerticalAlignment.Center };
                picker.Items.Add(new ComboBoxItem { Content = "Keep existing" });
                picker.Items.Add(new ComboBoxItem { Content = "Replace with Fing" });
                picker.SelectedIndex = change.ChoiceIndex;
                AutomationProperties.SetName(picker, change.Key);
                picker.SelectionChanged += Conflict_Changed;
                Grid.SetColumn(picker, 2);
                field.Children.Add(picker);
            }
            void ConstrainValue()
            {
                if (row.ActualWidth <= 0) return;
                value.MaxWidth = Math.Max(1, row.ActualWidth - field.Margin.Right - chip.ActualWidth
                    - (picker?.ActualWidth ?? 0) - field.ColumnSpacing * (picker is null ? 1 : 2));
            }
            row.SizeChanged += (_, _) => ConstrainValue();
            chip.SizeChanged += (_, _) => ConstrainValue();
            if (picker is not null) picker.SizeChanged += (_, _) => ConstrainValue();
            paragraph.Inlines.Add(new InlineUIContainer { Child = field });
        }
        row.Blocks.Add(paragraph);
        return row;
    }

    private void UpdateActions()
    {
        SelectionActions.Visibility = _selectionMode ? Visibility.Visible : Visibility.Collapsed;
        SelectionModeButton.Content = _selectionMode ? "Cancel selection" : "Select devices";
        SelectionModeButton.IsEnabled = !_busy && _analysis is not null;
        ImportButton.Content = _selectionMode ? $"Import selected ({_selected.Count})" : "Import all";
        ImportButton.IsEnabled = !_busy && _canEdit?.Invoke() == true && _analysis is { CanImport: true }
            && (!_selectionMode || _selected.Count > 0);
        ChangesList.IsEnabled = !_busy && _analysis is not null;
    }

    private void SelectionMode_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _analysis is null) return;
        _selectionMode = !_selectionMode;
        _selected.Clear();
        RenderDevices();
        UpdateActions();
    }

    private void SelectAll_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _analysis is null) return;
        _selected.UnionWith(_analysis.Devices.Where(device => device.CanImport).Select(device => device.Mac));
        RenderDevices();
        UpdateActions();
    }

    private void DeselectAll_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        _selected.Clear();
        RenderDevices();
        UpdateActions();
    }

    private void Conflict_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_busy || sender is not ComboBox { Tag: string key } picker || picker.SelectedIndex < 0) return;
        var replace = picker.SelectedIndex == 1;
        if (_replacements.Contains(key) == replace) return;
        if (replace) _replacements.Add(key); else _replacements.Remove(key);
        _analysis = null;
        ImportButton.IsEnabled = false;
        DispatcherQueue.TryEnqueue(AnalyzeCurrent);
    }

    private async void Import_Click(object sender, RoutedEventArgs e) =>
        await ImportDevicesAsync(_selectionMode ? _selected.ToHashSet() : null);

    private async Task ImportDevicesAsync(IReadOnlySet<string>? macs)
    {
        if (_busy || _analysis is not { CanImport: true } preview || _import is null || _export is null || _getData is null) return;
        SetBusy(true);
        try
        {
            if (_file is not null && (_fileHash is null
                || !SHA256.HashData(await ReadFileAsync(_file)).SequenceEqual(_fileHash)))
                throw new InvalidOperationException("The selected file changed. Analyze it again before importing.");
            var current = _getData();
            if (current.Revision != preview.Revision)
                throw new InvalidOperationException("Device data changed. Analyze again before importing.");
            var analysis = FingImportAnalyzer.Analyze(_export, current, _replacements, macs);
            var pendingReplacements = _replacements.ToHashSet();
            var summary = await _import(analysis);
            // The aggregate save invalidates the page; unselected devices are unchanged by this scoped commit.
            _replacements.UnionWith(pendingReplacements);
            foreach (var device in analysis.Devices.Where(device => device.CanImport))
            {
                _completed[device.Mac] = $"{device.Name} · {device.Mac} · {device.Changes.Count(change => change.Apply)} fields saved";
                _selected.Remove(device.Mac);
                foreach (var change in device.Changes.Where(change => change.Apply)) _replacements.Remove(change.Key);
            }
            AnalyzeCurrent();
            ImportHeadingText.Text = "Import complete";
            ImportSummaryText.Text = summary;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException
                                         or System.Runtime.InteropServices.COMException)
        {
            if (exception is InvalidOperationException)
                InvalidateAnalysis($"Nothing was imported: {exception.Message}");
            else
                ImportSummaryText.Text = $"Nothing was imported: {exception.Message}. Your selection and choices are retained; retry after resolving the error.";
            ImportHeadingText.Text = "Import failed";
        }
        finally { SetBusy(false); }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        BrowseButton.IsEnabled = !busy;
        DropArea.AllowDrop = !busy;
        AnalyzeButton.IsEnabled = !busy && _export is not null;
        foreach (var button in _managementButtons) button.IsEnabled = !busy;
        UpdateActions();
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (!_busy) BackRequested?.Invoke(this, EventArgs.Empty);
    }

    private void Manage_Click(object sender, RoutedEventArgs e)
    {
        if (!_busy && sender is Button { Tag: string category })
        {
            InvalidateAnalysis("Return from management and analyze again against the updated entries.");
            ManagementRequested?.Invoke(this, category);
        }
    }
}
