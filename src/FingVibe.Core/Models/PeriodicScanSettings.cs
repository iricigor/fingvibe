namespace FingVibe.Core.Models;

// Scheduled scans are opt-in: new installations and unreadable preferences keep them off.
public sealed record PeriodicScanSettings(
    bool IsEnabled = false,
    int IntervalMinutes = PeriodicScanSettings.DefaultIntervalMinutes)
{
    public const int DefaultIntervalMinutes = 60;

    public static IReadOnlyList<int> IntervalChoices { get; } = [15, 30, 60, 120, 240];

    public static PeriodicScanSettings Default { get; } = new();

    public static bool IsSupportedInterval(int minutes) => IntervalChoices.Contains(minutes);

    public PeriodicScanSettings Normalize() =>
        IsSupportedInterval(IntervalMinutes) ? this : this with { IntervalMinutes = DefaultIntervalMinutes };
}
