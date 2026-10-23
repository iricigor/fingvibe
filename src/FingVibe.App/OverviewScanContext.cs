using FingVibe.Core.Formatting;

namespace FingVibe.App;

public enum ScanDisplayStatus
{
    Scanning,
    Completed,
    Cancelled,
    Failed
}

public sealed record OverviewScanContext(
    string Subnet,
    DateTimeOffset ObservedAt,
    ScanDisplayStatus Status,
    string? FailureMessage = null)
{
    public string Freshness(DateTimeOffset now) => Status switch
    {
        ScanDisplayStatus.Scanning => "Scan in progress - partial results",
        ScanDisplayStatus.Cancelled => "Scan cancelled - partial results",
        ScanDisplayStatus.Failed => "Scan failed - partial results",
        _ => $"Updated {ScanAgeFormatter.FormatAge(now - ObservedAt)} ago"
    };

    public string Describe(string? selectedSubnet)
    {
        var observation = Status == ScanDisplayStatus.Completed ? "completed" : "started";
        var scope = $"Results for {Subnet} - scan {observation} {ObservedAt.ToLocalTime():g}.";
        if (Status == ScanDisplayStatus.Failed && FailureMessage is not null)
        {
            scope = $"{FailureMessage} {scope}";
        }
        return selectedSubnet == Subnet
            ? scope
            : $"{scope} These results are not for the selected scan target ({selectedSubnet ?? "none"}).";
    }
}
