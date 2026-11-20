using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkHealthEvaluatorTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 20, 9, 0, 0, TimeSpan.Zero);
    private const string Context = "network|192.168.0.10|192.168.0.1";
    private int _check;

    private NetworkMonitorObservation Check(long?[]? gateway = null, long?[]? cloudflare = null, long?[]? google = null,
        DiagnosticState windowsDns = DiagnosticState.Responded, DiagnosticState googleDns = DiagnosticState.Responded,
        bool cancelled = false)
    {
        var now = Start.AddMinutes(++_check);
        var samples = new List<NetworkMonitorPingSample>();
        Add(NetworkMonitorTarget.Gateway, "192.168.0.1", gateway ?? [3, 3, 3, 3, 3]);
        Add(NetworkMonitorTarget.Cloudflare, "1.1.1.1", cloudflare ?? [12, 12, 12, 12, 12]);
        Add(NetworkMonitorTarget.Google, "8.8.8.8", google ?? [15, 15, 15, 15, 15]);
        return new(now.AddSeconds(-6), now, "network", IPAddress.Parse("192.168.0.1"), samples,
        [
            Dns(NetworkMonitorDnsSource.WindowsConfiguredOrCached, windowsDns),
            Dns(NetworkMonitorDnsSource.Cloudflare, DiagnosticState.Responded),
            Dns(NetworkMonitorDnsSource.Google, googleDns)
        ], cancelled, "");

        void Add(NetworkMonitorTarget target, string address, long?[] latencies)
        {
            for (var index = 0; index < latencies.Length; index++)
                samples.Add(new(target, index + 1, now, now, new(DiagnosticCheckpoint.Gateway, address,
                    latencies[index] is null ? DiagnosticState.Unanswered : DiagnosticState.Responded, "",
                    RoundtripMilliseconds: latencies[index])));
        }

        NetworkMonitorDnsObservation Dns(NetworkMonitorDnsSource source, DiagnosticState state) =>
            new(source, now, now, new(DiagnosticCheckpoint.ConfiguredDns, "example.com", state, "", RoundtripMilliseconds: 9));
    }

    private static long?[] Ms(long value) => [value, value, value, value, value];

    [Fact]
    public void LearnsTwentyHealthyMediansBeforeReportingHealthy()
    {
        var evaluator = new NetworkHealthEvaluator();
        for (var index = 1; index < NetworkHealthEvaluator.BaselineSize; index++)
        {
            var learning = evaluator.Evaluate(Check(), Context, false)!;
            Assert.Equal((NetworkHealthVerdict.Learning, index), (learning.Verdict, learning.BaselineChecks));
        }

        var healthy = evaluator.Evaluate(Check(), Context, false)!;
        Assert.Equal((NetworkHealthVerdict.Healthy, 20), (healthy.Verdict, healthy.BaselineChecks));
        Assert.Equal(NetworkHealthEvaluator.NormalInterval, evaluator.NextInterval);
    }

    [Theory]
    [InlineData(20, 150, false)]
    [InlineData(21, 150, true)]
    [InlineData(20, 151, true)]
    public void AbsoluteLimitsApplyWhileLearning(long gateway, long external, bool suspicious)
    {
        var evaluator = new NetworkHealthEvaluator();
        var result = evaluator.Evaluate(Check(gateway: Ms(gateway), cloudflare: Ms(external)), Context, false)!;

        Assert.Equal(suspicious ? NetworkHealthVerdict.Verifying : NetworkHealthVerdict.Learning, result.Verdict);
        Assert.All(result.Symptoms, symptom => Assert.Equal(NetworkHealthSymptomKind.HighLatency, symptom.Kind));
    }

    [Fact]
    public void LearnedBaselineMustAlsoBeTripledAndFreezesWhileSuspicious()
    {
        var evaluator = new NetworkHealthEvaluator();
        for (var index = 0; index < NetworkHealthEvaluator.BaselineSize; index++)
            evaluator.Evaluate(Check(cloudflare: Ms(60)), Context, false);

        Assert.Equal(NetworkHealthVerdict.Healthy, evaluator.Evaluate(Check(cloudflare: Ms(180)), Context, false)!.Verdict);
        var high = evaluator.Evaluate(Check(cloudflare: Ms(181)), Context, false)!;
        Assert.Equal(NetworkHealthVerdict.Verifying, high.Verdict);
        Assert.Contains("3 x normal 60 ms", Assert.Single(high.Symptoms).Description);
        Assert.Equal(NetworkHealthEvaluator.IssueInterval, evaluator.NextInterval);

        // The suspicious median was not learned: 181 ms still exceeds 3 x the unchanged 60 ms baseline.
        Assert.Equal(NetworkHealthVerdict.Problem, evaluator.Evaluate(Check(cloudflare: Ms(181)), Context, false)!.Verdict);
    }

    [Fact]
    public void UnansweredIcmpNeedsAPreviouslyResponsiveTargetAndTwoMisses()
    {
        var evaluator = new NetworkHealthEvaluator();
        var silent = evaluator.Evaluate(Check(google: [null, null, null, null, null]), Context, false)!;
        Assert.Equal(NetworkHealthVerdict.Learning, silent.Verdict);
        Assert.Contains(silent.Notes, note => note.StartsWith("Limited visibility: Google 8.8.8.8"));

        Assert.Equal(NetworkHealthVerdict.Learning, evaluator.Evaluate(Check(cloudflare: [12, null, 12, 12, 12]), Context, false)!.Verdict);
        var missing = evaluator.Evaluate(Check(cloudflare: [12, null, 12, null, 12]), Context, false)!;
        var symptom = Assert.Single(missing.Symptoms);
        Assert.Equal((NetworkHealthSymptomKind.IcmpUnanswered, "ICMP probes unanswered: Cloudflare 1.1.1.1 (2 of 5)"),
            (symptom.Kind, symptom.Description));
    }

    [Fact]
    public void PublicResolverFailuresDoNotProveConfiguredDnsFailure()
    {
        var evaluator = new NetworkHealthEvaluator();
        var blocked = evaluator.Evaluate(Check(googleDns: DiagnosticState.Unanswered), Context, false)!;
        Assert.Equal(NetworkHealthVerdict.Learning, blocked.Verdict);
        Assert.Contains(blocked.Notes, note => note.StartsWith("Google DNS did not answer; public resolvers may be blocked"));

        var windows = evaluator.Evaluate(Check(windowsDns: DiagnosticState.Error), Context, false)!;
        Assert.Equal(NetworkHealthSymptomKind.WindowsDnsFailed, Assert.Single(windows.Symptoms).Kind);
    }

    [Fact]
    public void ProblemsNeedTwoConsecutiveSuspiciousCompletedChecks()
    {
        var evaluator = new NetworkHealthEvaluator();
        Assert.Equal(NetworkHealthVerdict.Verifying, evaluator.Evaluate(Check(gateway: Ms(30)), Context, false)!.Verdict);
        Assert.Equal(NetworkHealthVerdict.Learning, evaluator.Evaluate(Check(), Context, false)!.Verdict);
        Assert.Equal(NetworkHealthVerdict.Verifying, evaluator.Evaluate(Check(gateway: Ms(30)), Context, false)!.Verdict);
        // Cancelled and unobserved checks are interruptions, not resets.
        Assert.Equal(NetworkHealthVerdict.Verifying, evaluator.Evaluate(Check(cancelled: true), Context, false)!.Verdict);
        var problem = evaluator.Evaluate(Check(gateway: Ms(30)), Context, false)!;
        Assert.Equal((NetworkHealthVerdict.Problem, 0), (problem.Verdict, problem.RecoveryChecks));
        Assert.Equal(NetworkHealthEvaluator.IssueInterval, evaluator.NextInterval);
    }

    [Fact]
    public void RecoveryNeedsFiveConsecutiveHealthyChecksAndResetsOnUnhealthy()
    {
        var evaluator = new NetworkHealthEvaluator();
        evaluator.Evaluate(Check(windowsDns: DiagnosticState.Unanswered), Context, false);
        evaluator.Evaluate(Check(windowsDns: DiagnosticState.Unanswered), Context, false);
        for (var index = 1; index <= 3; index++)
            Assert.Equal(index, evaluator.Evaluate(Check(), Context, false)!.RecoveryChecks);
        var unobserved = new NetworkMonitorObservation(Start, Start.AddMinutes(++_check), "network", IPAddress.Loopback, [], [], false, "");
        Assert.Equal(3, evaluator.Evaluate(unobserved, Context, false)!.RecoveryChecks);
        Assert.Equal(0, evaluator.Evaluate(Check(windowsDns: DiagnosticState.Error), Context, false)!.RecoveryChecks);

        for (var index = 1; index < NetworkHealthEvaluator.RecoveryCheckCount; index++)
            Assert.Equal((NetworkHealthVerdict.Problem, index),
                (evaluator.Evaluate(Check(), Context, false)!.Verdict, evaluator.Current!.RecoveryChecks));
        var recovered = evaluator.Evaluate(Check(), Context, false)!;
        Assert.Equal((NetworkHealthVerdict.Learning, 0), (recovered.Verdict, recovered.RecoveryChecks));
        Assert.Equal(NetworkHealthEvaluator.NormalInterval, evaluator.NextInterval);
    }

    [Fact]
    public void ContextChangeStartsFreshAndAmbiguousRoutesStayUncertain()
    {
        var evaluator = new NetworkHealthEvaluator();
        evaluator.Evaluate(Check(gateway: Ms(30)), Context, false);
        evaluator.Evaluate(Check(gateway: Ms(30)), Context, false);
        Assert.Equal(NetworkHealthVerdict.Problem, evaluator.Current!.Verdict);

        var fresh = evaluator.Evaluate(Check(), "other|10.0.0.5|10.0.0.1", false)!;
        Assert.Equal((NetworkHealthVerdict.Learning, 1), (fresh.Verdict, fresh.BaselineChecks));

        var uncertain = evaluator.Evaluate(Check(gateway: Ms(30)), "other|10.0.0.5|10.0.0.1", true)!;
        Assert.Equal(NetworkHealthVerdict.Uncertain, uncertain.Verdict);
        Assert.StartsWith("More than one active network route", uncertain.Notes[0]);
        // Uncertain checks neither confirm nor count: one more suspicious check is still only verifying.
        Assert.Equal(NetworkHealthVerdict.Verifying, evaluator.Evaluate(Check(gateway: Ms(30)), "other|10.0.0.5|10.0.0.1", false)!.Verdict);
    }
}
