using FingVibe.Core.Formatting;
using FingVibe.Core.Updates;

namespace FingVibe.App;

internal static class ReleaseUpdatePresentation
{
    public static string LastChecked(DateTimeOffset? checkedAt, DateTimeOffset now)
    {
        if (checkedAt is null) return "Not checked yet";
        return checkedAt > now ? "Last checked just now" : $"Last checked {ScanAgeFormatter.FormatAge(now - checkedAt.Value)} ago";
    }

    public static string Status(UpdateState state, Version installedVersion)
    {
        return state.IsChecking ? "Checking for updates..." : state.Outcome switch
        {
            UpdateOutcome.NotChecked => "Updates have not been checked yet.",
            UpdateOutcome.Current when state.Latest?.Version < installedVersion =>
                "FingVibe is newer than the latest published stable release.",
            UpdateOutcome.Current => "FingVibe is up to date.",
            UpdateOutcome.Available when state.ConfirmedUpdate is { } update =>
                $"FingVibe {update.VersionText} is available.",
            UpdateOutcome.Failed when state.Error is { } error => $"Update check failed: {error}",
            UpdateOutcome.Failed => "The update check failed.",
            _ => "Stable update checks are unavailable for this build."
        };
    }

    public static string? InstallResult(ReleaseInstallHandoffRecord? record, Version runningVersion,
        string? installationDirectory = null, string? executablePath = null)
    {
        if (record is null) return null;
        var sameDirectory = installationDirectory is null
            || PathsEqual(installationDirectory, record.InstallationDirectory);
        var sameExecutable = executablePath is null
            || PathsEqual(executablePath, record.RelaunchExecutablePath);
        if (!sameDirectory || !sameExecutable) return null;
        if (record.Outcome is null)
            return $"The previous update to {record.ExpectedVersion} did not finish reporting an outcome. Retry or download the stable release manually.";
        if (!Version.TryParse(record.ExpectedVersion, out var expected))
            return "The previous update result could not be matched to a version. Download the stable release manually.";
        if (record.State == ReleaseInstallHandoffState.Succeeded &&
            runningVersion == expected && record.Outcome.RelaunchStarted)
            return $"Updated to {expected}.";
        var error = string.IsNullOrWhiteSpace(record.Outcome.Error)
            ? "The installer did not complete as expected."
            : record.Outcome.Error;
        return $"Update to {expected} did not complete: {error} Retry or download the stable release manually.";
    }

    private static bool PathsEqual(string left, string right) =>
        Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar).Equals(
            Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);
}
