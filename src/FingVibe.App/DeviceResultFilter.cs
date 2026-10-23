namespace FingVibe.App;

public sealed record DeviceResultFilter(bool AliveOnly, bool OpenPortsOnly, string SearchText)
{
    public bool Matches(ScanResultRow row) =>
        (!AliveOnly || row.IsOnline)
        && (!OpenPortsOnly || row.Result.OpenPortItems.Count > 0)
        && (row.NameText.Contains(SearchText.Trim(), StringComparison.OrdinalIgnoreCase)
            || row.Result.MatchesFilter(SearchText));
}
