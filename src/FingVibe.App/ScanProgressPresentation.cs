using FingVibe.Core.Models;

namespace FingVibe.App;

internal static class ScanProgressPresentation
{
    internal static double FilledWidth(double completed, double maximum, double trackWidth) =>
        Math.Max(0, trackWidth) * Math.Clamp(completed / Math.Max(1, maximum), 0, 1);

    internal static double PulsePosition(TimeSpan elapsed) =>
        elapsed.TotalSeconds % 1.8 / 1.8 * 1.5 - 0.25;

    // User-facing stages; neither a phase counter nor an ETA, because remaining work depends on who answers.
    internal static string Message(LanScanProgress progress) => progress.Phase switch
    {
        LanScanPhase.FirstPass => $"Finding devices: {progress.Completed:N0} of {progress.Total:N0} addresses checked",
        LanScanPhase.Arp => $"Confirming remaining devices: address lookup, {Unanswered(progress)}",
        LanScanPhase.RetryWait => "Confirming remaining devices: waiting 10 seconds before trying unanswered addresses again",
        LanScanPhase.Retry => $"Confirming remaining devices: second try, {Unanswered(progress)}",
        LanScanPhase.FinalRetryWait => "Confirming remaining devices: waiting 10 seconds before the last try",
        LanScanPhase.FinalRetry => $"Confirming remaining devices: last try, {Unanswered(progress)}",
        _ => throw new ArgumentOutOfRangeException(nameof(progress), progress.Phase, "Unknown LAN scan phase.")
    };

    // Protocol-level counters stay available as optional detail (tooltip and help text).
    internal static string Detail(LanScanProgress progress) => progress.Phase switch
    {
        LanScanPhase.FirstPass => $"ICMP ping: {progress.Completed:N0}/{progress.Total:N0} addresses",
        LanScanPhase.Arp => $"Background ARP: {progress.Completed:N0}/{progress.Total:N0} ping misses",
        LanScanPhase.RetryWait => "Waiting 10 seconds before ICMP attempt 2",
        LanScanPhase.Retry => $"ICMP attempt 2: {progress.Completed:N0}/{progress.Total:N0} remaining misses",
        LanScanPhase.FinalRetryWait => "Waiting 10 seconds before ICMP attempt 3",
        LanScanPhase.FinalRetry => $"ICMP attempt 3: {progress.Completed:N0}/{progress.Total:N0} remaining misses",
        _ => throw new ArgumentOutOfRangeException(nameof(progress), progress.Phase, "Unknown LAN scan phase.")
    };

    internal static string Elapsed(TimeSpan elapsed)
    {
        var whole = elapsed < TimeSpan.Zero ? TimeSpan.Zero : elapsed;
        return $"{(int)whole.TotalMinutes}:{whole.Seconds:00} elapsed";
    }

    private static string Unanswered(LanScanProgress progress) =>
        $"{progress.Completed:N0} of {progress.Total:N0} unanswered addresses checked";
}
