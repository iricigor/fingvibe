using FingVibe.App.Views;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private IReadOnlySet<string>? _localAdapterMacs;

    // UI review reads synthetic adapters so native checks never depend on the runner's hardware.
    private IReadOnlySet<string> LocalAdapterMacs => _localAdapterMacs ??= IsUiReview
        ? (Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_LOCAL_ADAPTERS") ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(PeopleRoomsData.NormalizeMacAddress).ToHashSet(StringComparer.Ordinal)
        : DeviceMatchSuggestions.ReadLocalAdapterMacs();

    /// <summary>Recomputes suggestions after inventory loads, scans, name, identification or decline changes.</summary>
    private void UpdateMatchSuggestions()
    {
        var suggestions = DeviceMatchSuggestions.Find(CurrentDeviceData, LocalAdapterMacs);
        var rows = MacRows();
        foreach (var row in _allResults)
        {
            var list = row.VirtualDevice is null && row.MacAddress?.GetAddressBytes().Length == 6
                ? suggestions.GetValueOrDefault(row.MacAddress.ToString()) ?? [] : [];
            row.SetMatchSuggestions(list, DeviceMatchPresentation.RowText(list, rows));
        }
        ShowSelectedMatchSuggestions(opening: false);
    }

    private void ShowSelectedMatchSuggestions(bool opening)
    {
        if (_selectedDeviceRow is not { } row) return;
        var data = CurrentDeviceData;
        var rows = MacRows();
        var header = LinkedDevicePresentation.Header(row, data);
        var canLink = header.State is MergeSectionState.NoSuggestions or MergeSectionState.PossibleMatches;
        DeviceLinkChoice Choice(LinkCandidate candidate) => new(candidate.Mac, DeviceMatchPresentation.Card(candidate.Row),
            candidate.Suggestion?.ShortReason, candidate.Suggestion?.Explanation, candidate.Declined,
            LinkedDevicePresentation.CandidateText(candidate));
        IReadOnlyList<DeviceLinkChoice> Search(string? text) => canLink
            ? LinkedDevicePresentation.Candidates(row, _allResults, data, text).Select(Choice).ToArray() : [];
        var mac = row.MacAddress?.ToString();
        var members = mac is not null && data.FindLinkedDevice(mac) is { } linked
            ? LinkedDevicePresentation.Members(linked, rows, mac).Select(line => line.Text).ToArray() : [];
        DevicePage.ShowMergeSection(new(header, DeviceMatchPresentation.Card(row),
            Search(null).Where(item => item.IsSuggested).ToArray(), members, Search,
            other => rows.TryGetValue(other, out var otherRow) ? LinkedDeviceDraft.Create(row, otherRow) : null), opening);
    }

    private Dictionary<string, ScanResultRow> MacRows() => _allResults
        .Where(row => row.VirtualDevice is null && row.MacAddress?.GetAddressBytes().Length == 6)
        .GroupBy(row => row.MacAddress!.ToString()).ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);

    private void DeviceMatchSuggestionRequested(object? sender, ScanResultRow row)
    {
        ShowDeviceDetails(row);
        if (ReferenceEquals(_selectedDeviceRow, row) && row.HasMatchSuggestions) DevicePage.RevealMatchSuggestions();
    }

    private void DeviceServiceDiscoveryRequested(object? sender, ScanResultRow row)
    {
        ShowDeviceDetails(row);
        if (ReferenceEquals(_selectedDeviceRow, row)) DevicePage.RevealServiceDiscovery();
    }

    private async void DeviceMatchDeclineRequested(object? sender, string otherMac)
    {
        var row = _selectedDeviceRow;
        if (row?.MacAddress?.ToString() is not { } mac) return;
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            await PersistDeviceDataAsync(CurrentDeviceData.DeclineMatch(mac, otherMac));
            UpdateMatchSuggestions();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                              or InvalidOperationException or InvalidDataException or ArgumentException)
        {
            if (ReferenceEquals(_selectedDeviceRow, row))
                DevicePage.ShowMatchError($"Both records still show the suggestion. {exception.Message}");
        }
        finally { _deviceDataSaveLock.Release(); }
    }
}

internal static class DeviceMatchPresentation
{
    public const int RowTooltipLimit = 3;

    public static DeviceMatchCard Card(ScanResultRow row) => new(row.NameText, row.StatusLabel,
        $"{row.AddressText} / {row.MacAddressText}",
        $"{row.VendorDisplayText} / {row.OperatingSystemText} / {row.DeviceTypeText}");

    public static string RowText(IReadOnlyList<DeviceMatchSuggestion> suggestions, IReadOnlyDictionary<string, ScanResultRow> rows)
    {
        if (suggestions.Count == 0) return string.Empty;
        var lines = suggestions.Take(RowTooltipLimit).Select(item =>
        {
            var other = rows.TryGetValue(item.OtherMac, out var row)
                ? $"{row.NameText} ({row.AddressText})" : FormatMac(item.OtherMac);
            return $"Possible matching MAC address: {other}. {item.ShortReason}.";
        }).ToList();
        if (suggestions.Count > RowTooltipLimit)
            lines.Add($"{suggestions.Count - RowTooltipLimit} more in Device Details.");
        lines.Add("Click to review in Device Details.");
        return string.Join(Environment.NewLine, lines);
    }

    public static string FormatMac(string mac) =>
        string.Join("-", Enumerable.Range(0, mac.Length / 2).Select(index => mac.Substring(index * 2, 2)));
}
