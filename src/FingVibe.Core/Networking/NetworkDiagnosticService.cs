using System.Net;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public interface INetworkDiagnosticProbes
{
    Task<DiagnosticObservation> PingAsync(DiagnosticCheckpoint checkpoint, IPAddress target, int ttl, CancellationToken cancellationToken);
    Task<DiagnosticObservation> ResolveAsync(DiagnosticCheckpoint checkpoint, IPAddress? resolver, CancellationToken cancellationToken);
}

public sealed class NetworkDiagnosticService(INetworkDiagnosticProbes probes)
{
    public const string DnsHostname = "example.com";
    public const int TimeoutMilliseconds = 1500;
    public const int MaximumHops = 16;
    public static readonly IPAddress Cloudflare = IPAddress.Parse("1.1.1.1");
    public static readonly IPAddress Google = IPAddress.Parse("8.8.8.8");

    public static IReadOnlyList<DiagnosticObservation> CreateCheckpoints(LanNetwork? network, IPAddress? wan) =>
    [
        Pending(DiagnosticCheckpoint.Loopback, "127.0.0.1"),
        Pending(DiagnosticCheckpoint.LocalAddress, network?.LocalAddress.ToString()),
        Pending(DiagnosticCheckpoint.Gateway, network?.GatewayAddress?.ToString()),
        Pending(DiagnosticCheckpoint.RouterWan, wan?.ToString()),
        Pending(DiagnosticCheckpoint.Hop2, Cloudflare.ToString()),
        Pending(DiagnosticCheckpoint.CloudflarePing, Cloudflare.ToString()),
        Pending(DiagnosticCheckpoint.GooglePing, Google.ToString()),
        Pending(DiagnosticCheckpoint.ConfiguredDns, $"{DnsHostname} (Windows configured DNS)"),
        Pending(DiagnosticCheckpoint.CloudflareDns, $"{DnsHostname} via {Cloudflare}"),
        Pending(DiagnosticCheckpoint.GoogleDns, $"{DnsHostname} via {Google}")
    ];

    private static DiagnosticObservation Pending(DiagnosticCheckpoint checkpoint, string? target) =>
        new(checkpoint, target ?? "Not available", target is null ? DiagnosticState.Unavailable : DiagnosticState.Untested,
            target is null ? "Configuration unavailable or optional address not supplied." : "Not tested.");

    public async Task<NetworkDiagnosticReport> RunAsync(
        LanNetwork? network, IPAddress? wan, IProgress<DiagnosticObservation>? progress, CancellationToken cancellationToken,
        IProgress<TraceHop>? traceProgress = null)
    {
        var observations = CreateCheckpoints(network, wan).ToDictionary(item => item.Checkpoint);
        var hops = new List<TraceHop>();
        var complete = false;
        void Publish(DiagnosticObservation observation)
        {
            observations[observation.Checkpoint] = observation;
            progress?.Report(observation);
        }

        async Task Check(DiagnosticCheckpoint checkpoint, Func<Task<DiagnosticObservation>> probe)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var current = observations[checkpoint];
            if (current.State == DiagnosticState.Unavailable)
            {
                progress?.Report(current);
                return;
            }
            Publish(current with { State = DiagnosticState.Running, Detail = "Checking..." });
            Publish(await probe().ConfigureAwait(false));
        }

        try
        {
            foreach (var (checkpoint, target) in new (DiagnosticCheckpoint, IPAddress?)[]
            {
                (DiagnosticCheckpoint.Loopback, IPAddress.Loopback),
                (DiagnosticCheckpoint.LocalAddress, network?.LocalAddress),
                (DiagnosticCheckpoint.Gateway, network?.GatewayAddress),
                (DiagnosticCheckpoint.RouterWan, wan),
                (DiagnosticCheckpoint.CloudflarePing, Cloudflare),
                (DiagnosticCheckpoint.GooglePing, Google)
            })
            {
                if (target is null)
                {
                    progress?.Report(observations[checkpoint]);
                    continue;
                }
                await Check(checkpoint, () => probes.PingAsync(checkpoint, target, 128, cancellationToken)).ConfigureAwait(false);
            }

            foreach (var (checkpoint, resolver) in new (DiagnosticCheckpoint, IPAddress?)[]
            {
                (DiagnosticCheckpoint.ConfiguredDns, null),
                (DiagnosticCheckpoint.CloudflareDns, Cloudflare),
                (DiagnosticCheckpoint.GoogleDns, Google)
            })
            {
                await Check(checkpoint, () => probes.ResolveAsync(checkpoint, resolver, cancellationToken)).ConfigureAwait(false);
            }

            Publish(observations[DiagnosticCheckpoint.Hop2] with { State = DiagnosticState.Running, Detail = "Tracing toward 1.1.1.1..." });
            for (var ttl = 1; ttl <= MaximumHops; ttl++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var response = await probes.PingAsync(DiagnosticCheckpoint.Hop2, Cloudflare, ttl, cancellationToken).ConfigureAwait(false);
                var reached = response.State == DiagnosticState.Responded && response.RespondingAddress?.Equals(Cloudflare) == true;
                var hop = new TraceHop(ttl, response, reached);
                hops.Add(hop);
                traceProgress?.Report(hop);
                if (ttl == 2)
                {
                    Publish(response with { Detail = $"Hop 2: {response.Detail}" });
                }
                if (reached)
                {
                    complete = true;
                    break;
                }
            }
            if (hops.Count < 2)
            {
                Publish(observations[DiagnosticCheckpoint.Hop2] with
                {
                    State = DiagnosticState.Unavailable,
                    Detail = "Destination reached before hop 2; no upstream hop-2 router observed."
                });
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            foreach (var observation in observations.Values.ToArray())
            {
                if (observation.State is DiagnosticState.Running or DiagnosticState.Untested)
                {
                    Publish(observation with { State = DiagnosticState.Cancelled, Detail = "Cancelled; no response inferred." });
                }
            }
            return new(observations.Values.ToArray(), hops, complete, true);
        }

        return new(observations.Values.ToArray(), hops, complete, false);
    }
}

public static class NetworkDiagnosticInterpreter
{
    public static DiagnosticSummary Summarize(LanNetwork? network, NetworkDiagnosticReport? report)
    {
        if (report?.Cancelled == true)
            return new(DiagnosticSummaryKind.Neutral, "Cancelled / partial results", "Completed observations remain visible. Rerun when ready; cancelled checks establish no fault.");
        if (network is null)
            return new(DiagnosticSummaryKind.Problem, "No active LAN connection", "Windows reports no selected active IPv4 LAN adapter. Check Wi-Fi or Ethernet, refresh the adapter list, and rerun; report persistent adapter problems.");
        if (report is null)
            return new(DiagnosticSummaryKind.Neutral, "Ready / not tested", "Run checks on request. Windows chooses the route; the selected LAN adapter does not force probe routing.");
        if (Enum.GetValues<DiagnosticCheckpoint>().Any(checkpoint => report.Observations.Count(item => item.Checkpoint == checkpoint) != 1))
            return new(DiagnosticSummaryKind.Neutral, "Incomplete diagnostics", "Some diagnostic checkpoints are missing or ambiguous. Rerun and report persistent diagnostic errors with their time.");

        bool Responded(DiagnosticCheckpoint checkpoint) =>
            report.Observations.Any(item => item.Checkpoint == checkpoint && item.State == DiagnosticState.Responded);
        var dns = new[] { DiagnosticCheckpoint.ConfiguredDns, DiagnosticCheckpoint.CloudflareDns, DiagnosticCheckpoint.GoogleDns };
        var external = Responded(DiagnosticCheckpoint.CloudflarePing) || Responded(DiagnosticCheckpoint.GooglePing);
        var dnsResponded = dns.Any(Responded);
        var dnsFailures = report.Observations.Where(item => dns.Contains(item.Checkpoint) && item.State is DiagnosticState.Unanswered or DiagnosticState.Error).ToArray();
        if (report.Observations.Any(item => item.State is DiagnosticState.Untested or DiagnosticState.Running or DiagnosticState.Cancelled))
            return new(DiagnosticSummaryKind.Neutral, "Incomplete diagnostics", "Checks have not all completed. Review the partial evidence and rerun; untested checks establish no fault.");
        if (external && dnsFailures.Length > 0)
        {
            var configuredFailed = dnsFailures.Any(item => item.Checkpoint == DiagnosticCheckpoint.ConfiguredDns);
            return new(DiagnosticSummaryKind.Warning, "DNS issues",
                configuredFailed
                    ? "An internet IP responded, but Windows configured-DNS resolution failed. Check DNS settings, VPN/firewall rules, and report the failed checks and time."
                    : "An internet IP responded, but a direct public-resolver DNS query failed. Windows DNS may still work; check resolver filtering and report the failed checks and time.");
        }
        if (report.Observations.Any(item => item.Checkpoint != DiagnosticCheckpoint.RouterWan && item.State == DiagnosticState.Error))
            return new(DiagnosticSummaryKind.Neutral, "Incomplete diagnostics", "Evidence is incomplete or a probe reported an error. Review its details and rerun; report persistent errors with their time.");
        if (!external)
            return new(DiagnosticSummaryKind.Warning, dnsResponded ? "IP reachability uncertain" : "Connectivity uncertain",
                dnsResponded
                    ? "DNS responded, but neither external IP answered ICMP. Filtering may explain this; check in a browser and report targets, outcomes, and time."
                    : "Neither external IP answered ICMP and DNS did not respond. This is not an exact-fault verdict; check in a browser, DNS/VPN settings, and report outcomes and time.");
        if (!Responded(DiagnosticCheckpoint.Loopback) || !Responded(DiagnosticCheckpoint.LocalAddress))
            return new(DiagnosticSummaryKind.Warning, "Local checks need attention", "Internet probes responded, but a local check did not. Check Windows networking/firewall settings and report the failed check and time.");
        if (!Responded(DiagnosticCheckpoint.CloudflarePing) || !Responded(DiagnosticCheckpoint.GooglePing)
            || !dns.All(Responded) || !Responded(DiagnosticCheckpoint.Gateway))
            return new(DiagnosticSummaryKind.Warning, "Connectivity available / some checks unanswered", "Internet probes responded. Missing gateway or other responses may reflect filtering, not a broken link; review details and report persistent service errors.");
        return new(DiagnosticSummaryKind.Good, "All good", "The local, gateway, internet IP, and DNS checks passed. Optional WAN and intermediate probes may be filtered; report any app-specific error separately, since not every service was tested.");
    }
}
