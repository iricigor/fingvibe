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
        LanScanPhase.FirstPass => $"Pass 1/2 (ICMP): Scanning {progress.Completed:N0}/{progress.Total:N0} addresses",
        LanScanPhase.Arp => $"Pass 2/2 (ARP): Scanning {progress.Completed:N0}/{progress.Total:N0} missed addresses",
        LanScanPhase.Retry => $"Retrying {progress.Completed:N0}/{progress.Total:N0} missed addresses",
        _ => throw new ArgumentOutOfRangeException(nameof(progress), progress.Phase, "Unknown LAN scan phase.")
    };
}
