using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.App;

/// <summary>
/// Synthetic raw observation delivered in UI review instead of sending probes. Never live data. The problem variant
/// exceeds the absolute latency limits so two consecutive checks confirm a problem.
/// </summary>
internal static class NetworkMonitorReviewFixture
{
    public const string SyntheticDetail = "Synthetic UI-review evidence; no probes sent.";

    /// <summary>Answers every deeper diagnostic checkpoint and reaches 1.1.1.1 at hop 3 without sending probes.</summary>
    public static INetworkDiagnosticProbes DiagnosticProbes { get; } = new ReviewProbes();

    private sealed class ReviewProbes : INetworkDiagnosticProbes
    {
        public Task<DiagnosticObservation> PingAsync(
            DiagnosticCheckpoint checkpoint, IPAddress target, int ttl, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var responder = checkpoint != DiagnosticCheckpoint.Hop2 || ttl >= 3 ? target
                : IPAddress.Parse(ttl == 1 ? "192.0.2.1" : "198.51.100.1");
            return Task.FromResult(new DiagnosticObservation(checkpoint, target.ToString(), DiagnosticState.Responded,
                SyntheticDetail, responder, checkpoint == DiagnosticCheckpoint.Hop2 ? 10L + ttl : 4));
        }

        public Task<DiagnosticObservation> ResolveAsync(
            DiagnosticCheckpoint checkpoint, IPAddress? resolver, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(new DiagnosticObservation(checkpoint, NetworkDiagnosticService.DnsHostname,
                DiagnosticState.Responded, SyntheticDetail, IPAddress.Parse("192.0.2.80"), 9));
        }
    }

    public static NetworkMonitorObservation Create(LanNetwork network, DateTimeOffset now, bool problem = false)
    {
        var gateway = network.GatewayAddress ?? IPAddress.Parse("192.0.2.1");
        var samples = new List<NetworkMonitorPingSample>();
        Add(NetworkMonitorTarget.Gateway, DiagnosticCheckpoint.Gateway, gateway.ToString(),
            problem ? [41, 45, 42, 44, 43] : [2, 3, 2, 4, 3]);
        Add(NetworkMonitorTarget.Cloudflare, DiagnosticCheckpoint.CloudflarePing, "1.1.1.1",
            problem ? [210, 220, 205, 215, 230] : [11, 12, 14, 11, 13]);
        Add(NetworkMonitorTarget.Google, DiagnosticCheckpoint.GooglePing, "8.8.8.8", [15, 16, null, 15, 17]);
        return new(now.AddSeconds(-6), now, "ui-review-network", gateway, samples,
        [
            Dns(NetworkMonitorDnsSource.WindowsConfiguredOrCached, DiagnosticCheckpoint.ConfiguredDns, "Windows DNS",
                DiagnosticState.Responded, "Resolved example.com.", 9),
            Dns(NetworkMonitorDnsSource.Cloudflare, DiagnosticCheckpoint.CloudflareDns, "1.1.1.1",
                DiagnosticState.Responded, "Resolved example.com.", 15),
            Dns(NetworkMonitorDnsSource.Google, DiagnosticCheckpoint.GoogleDns, "8.8.8.8",
                DiagnosticState.Error, "Timed out after 2 seconds.", null)
        ], false, "Synthetic UI-review observation.");

        void Add(NetworkMonitorTarget target, DiagnosticCheckpoint checkpoint, string address, long?[] latencies)
        {
            for (var index = 0; index < latencies.Length; index++)
            {
                var latency = latencies[index];
                samples.Add(new(target, index + 1, now.AddSeconds(index - 6), now.AddSeconds(index - 5),
                    new(checkpoint, address, latency is null ? DiagnosticState.Unanswered : DiagnosticState.Responded,
                        latency is null ? "No reply." : "Reply.", RoundtripMilliseconds: latency)));
            }
        }

        NetworkMonitorDnsObservation Dns(NetworkMonitorDnsSource source, DiagnosticCheckpoint checkpoint, string target,
            DiagnosticState state, string detail, long? latency) =>
            new(source, now.AddSeconds(-1), now, new(checkpoint, target, state, detail, RoundtripMilliseconds: latency));
    }
}
