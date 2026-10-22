namespace FingVibe.Core.Formatting;

public static class ScanAgeFormatter
{
    public static string FormatAge(TimeSpan age)
    {
        var seconds = Math.Max(0, (long)Math.Floor(age.TotalSeconds));
        var (count, unit) = seconds switch
        {
            >= 86_400 => (seconds / 86_400, "day"),
            >= 3_600 => (seconds / 3_600, "hour"),
            >= 60 => (seconds / 60, "minute"),
            _ => (seconds, "second")
        };

        return $"{count} {unit}{(count == 1 ? string.Empty : "s")}";
    }
}
