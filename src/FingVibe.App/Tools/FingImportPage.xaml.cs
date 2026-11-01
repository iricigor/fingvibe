using System.Security.Cryptography;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
    private bool _busy;
    private int _fileGeneration;

    public FingImportPage()
    {
        InitializeComponent();
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
                    new(2, "020000000001", new(Name: "Review workstation", Type: "Desktop", OperatingSystem: "Windows"), null, null),
                    new(3, "020000000002", new(Name: "Review speaker", Type: "Speaker/Amp", Brand: "Example", Model: "Speaker", Address: "192.0.2.20"), null, "Missing review room"),
                    new(4, "020000000003", new(Name: "Review controller", Hostname: "controller.local", Type: "Controller", Address: "192.0.2.20"), "Missing review person", null)
                ], ["Synthetic preview: private/randomized MACs may change."], 3);
            AnalyzeCurrent();
        }
        SetBusy(_busy);
    }

    internal void InvalidateAnalysis(string reason)
    {
        _analysis = null;
        _replacements.Clear();
        ImportButton.IsEnabled = false;
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
        InvalidateAnalysis("A different file was selected.");
        ChangesList.ItemsSource = null;
        WarningsBar.IsOpen = false;
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
        if (_file is not null) await ChooseFileAsync(_file);
        else AnalyzeCurrent();
    }

    private void AnalyzeCurrent()
    {
        if (_export is null || _getData is null || _canEdit?.Invoke() != true)
        {
            InvalidateAnalysis("Wait for saved data and any scan to finish loading, then analyze again.");
            return;
        }
        _analysis = FingImportAnalyzer.Analyze(_export, _getData(), _replacements);
        AnalysisCountsText.Text = $"{_analysis.DeviceRows:N0} devices in export · {_analysis.Matched:N0} matched by MAC · "
            + $"{_analysis.Added:N0} new / Fing Only · {_analysis.Warnings.Count:N0} warnings";
        ChangesList.ItemsSource = _analysis.Changes;
        WarningsText.Text = string.Join(Environment.NewLine, _analysis.Warnings);
        WarningsBar.IsOpen = _analysis.Warnings.Count > 0;
        ImportHeadingText.Text = _analysis.CanImport ? "Ready to import reviewed changes" : "No eligible changes";
        ImportSummaryText.Text = $"{_analysis.Added:N0} new devices · {_analysis.AppliedFields:N0} fields to apply · "
            + $"{_analysis.SkippedFields:N0} fields skipped or kept. Blank fields never clear saved values.";
        ImportButton.IsEnabled = !_busy && _analysis.CanImport;
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

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _analysis is not { CanImport: true } analysis || _import is null) return;
        SetBusy(true);
        try
        {
            if (_file is not null && (_fileHash is null
                || !SHA256.HashData(await ReadFileAsync(_file)).SequenceEqual(_fileHash)))
                throw new InvalidOperationException("The selected file changed. Analyze it again before importing.");
            var summary = await _import(analysis);
            _analysis = null;
            _replacements.Clear();
            ImportHeadingText.Text = "Import complete";
            ImportSummaryText.Text = summary;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException
                                         or System.Runtime.InteropServices.COMException)
        {
            InvalidateAnalysis($"Nothing was imported: {exception.Message}");
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
        ChangesList.IsEnabled = !busy;
        ManagePeopleButton.IsEnabled = ManageRoomsButton.IsEnabled = !busy;
        ImportButton.IsEnabled = !busy && _analysis?.CanImport == true && _canEdit?.Invoke() == true;
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (!_busy) BackRequested?.Invoke(this, EventArgs.Empty);
    }

    private void Manage_Click(object sender, RoutedEventArgs e)
    {
        if (!_busy && sender is HyperlinkButton { Tag: string category })
        {
            InvalidateAnalysis("Return from management and analyze again against the updated entries.");
            ManagementRequested?.Invoke(this, category);
        }
    }
}
