using FingVibe.Core.Models;

namespace FingVibe.App;

internal static class ScanProgressPresentation
{
    internal static double FilledWidth(double completed, double maximum, double trackWidth) =>
        Math.Max(0, trackWidth) * Math.Clamp(completed / Math.Max(1, maximum), 0, 1);

    internal static double PulsePosition(TimeSpan elapsed) =>
        elapsed.TotalSeconds % 1.8 / 1.8 * 1.5 - 0.25;

    internal static string Message(LanScanProgress progress) => progress.Phase switch
    {
        LanScanPhase.FirstPass => $"Scanning ICMP: {progress.Completed:N0}/{progress.Total:N0} addresses",
        LanScanPhase.Arp => $"(1/5) Background ARP: {progress.Completed:N0}/{progress.Total:N0} misses",
        LanScanPhase.RetryWait => "(2/5) Waiting 10 seconds before ICMP attempt 2",
        LanScanPhase.Retry => $"(3/5) Background ICMP attempt 2: {progress.Completed:N0}/{progress.Total:N0} misses",
        LanScanPhase.FinalRetryWait => "(4/5) Waiting 10 seconds before ICMP attempt 3",
        LanScanPhase.FinalRetry => $"(5/5) Background ICMP attempt 3: {progress.Completed:N0}/{progress.Total:N0} misses",
        _ => throw new ArgumentOutOfRangeException(nameof(progress), progress.Phase, "Unknown LAN scan phase.")
    };
}
