using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Threading.Channels;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class LanScannerServiceTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    // A /29 has six usable addresses: 192.0.2.1 through 192.0.2.6.
    private static readonly LanNetwork Network = new(
        "Ethernet", IPAddress.Parse("192.0.2.5"), IPAddress.Parse("192.0.2.0"), 29, true, IPAddress.Parse("192.0.2.1"));

    private static readonly string[] Addresses = Enumerable.Range(1, 6).Select(host => $"192.0.2.{host}").ToArray();

    private readonly FakeTimeProvider _time = new(new DateTimeOffset(2026, 11, 6, 8, 0, 0, TimeSpan.Zero));
    private readonly ScriptedIcmp _icmp = new();
    private readonly RecordingEnricher _enricher = new();
    private readonly Recorder<ScanResult> _results = new();
    private readonly Recorder<LanScanProgress> _progress = new();
    private Func<IPAddress, LanNetwork, CancellationToken, Task<PhysicalAddress?>> _arp =
        (_, _, _) => Task.FromResult<PhysicalAddress?>(null);

    private LanScannerService Scanner(int timeoutMilliseconds = 700, int maximumConcurrency = 256) =>
        new(timeoutMilliseconds, maximumConcurrency, _enricher,
            (_, _) => Task.FromResult(new ScanDiscovery(
                new Dictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>>(),
                new Dictionary<IPAddress, MdnsDeviceInfo>())),
            _icmp.SendAsync, _time, (address, network, token) => _arp(address, network, token));

    private async Task FinishSecondRetryAsync()
    {
        await _progress.WaitForAsync(progress => progress.Phase == LanScanPhase.FinalRetryWait);
        _time.Advance(LanScannerService.RetryPause);
    }

    [Fact]
    public void FirstPassKeepsTheExistingTimeoutAndConcurrencyWithTenSecondRetryPauses()
    {
        Assert.Equal(700, LanScannerService.DefaultTimeoutMilliseconds);
        Assert.Equal(256, LanScannerService.DefaultMaximumConcurrency);
        Assert.Equal(TimeSpan.FromSeconds(10), LanScannerService.RetryPause);
    }

    // The scanner receives no inventory or history, so every first-pass miss is retried, known or not.
    [Fact]
    public async Task OnlyUnconfirmedAddressesAreRetriedUpToTwiceAndOnlyFreshRepliesCountAsAlive()
    {
        _icmp.Respond = (address, attempt) => address switch
        {
            "192.0.2.1" => ScriptedIcmp.Reply(),
            "192.0.2.2" => attempt == 1 ? ScriptedIcmp.Miss() : ScriptedIcmp.Reply(),
            "192.0.2.3" => attempt == 1 ? ScriptedIcmp.PingFailure() : ScriptedIcmp.Reply(),
            "192.0.2.4" => attempt == 1 ? ScriptedIcmp.Miss(IPStatus.DestinationHostUnreachable) : ScriptedIcmp.Miss(),
            _ => ScriptedIcmp.Miss()
        };

        var scan = Scanner().ScanAsync(Network, _results, _progress);
        Assert.Equal(new LanScanProgress(LanScanPhase.RetryWait, 0, 5),
            await _progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait));
        Assert.Equal(6, _icmp.Attempts.Count);

        _time.Advance(LanScannerService.RetryPause - TimeSpan.FromMilliseconds(1));
        await Task.Delay(50);
        Assert.Equal(6, _icmp.Attempts.Count);
        Assert.False(scan.IsCompleted);

        _time.Advance(TimeSpan.FromMilliseconds(1));
        await FinishSecondRetryAsync();
        var summary = await scan.WaitAsync(Timeout);

        Assert.Equal(new ScanSummary(6, 3, 3), summary);
        Assert.Equal([1, 2, 2, 3, 3, 3], Addresses.Select(_icmp.AttemptsFor));
        Assert.All(_icmp.Attempts, attempt => Assert.Equal(700, attempt.Timeout));
        var results = _results.Items.OrderBy(result => result.Address.GetAddressBytes()[3]).ToArray();
        Assert.Equal(Addresses, results.Select(result => result.AddressText));
        Assert.Equal(
            [HostStatus.Alive, HostStatus.Alive, HostStatus.Alive,
                HostStatus.Unreachable, HostStatus.Unreachable, HostStatus.Unreachable],
            results.Select(result => result.Status));
        Assert.Equal(["192.0.2.1", "192.0.2.2", "192.0.2.3"],
            _enricher.Enriched.Select(address => address.ToString()).Order());
        Assert.Equal("001122334402", results[1].MacAddressText.Replace("-", string.Empty));
        Assert.Equal(summary.Alive, results.Count(result => result.Status == HostStatus.Alive));
    }

    [Fact]
    public async Task ProgressReportsTheFirstPassThenADistinctRetryPhaseWithItsOwnCount()
    {
        _icmp.Respond = (address, attempt) => address is "192.0.2.1" or "192.0.2.2" || attempt == 2 && address == "192.0.2.6"
            ? ScriptedIcmp.Reply() : ScriptedIcmp.Miss();

        var scan = Scanner().ScanAsync(Network, _results, _progress);
        await _progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
        _time.Advance(LanScannerService.RetryPause);
        await FinishSecondRetryAsync();
        Assert.Equal(new ScanSummary(6, 3, 3), await scan.WaitAsync(Timeout));

        var progress = _progress.Items.ToArray();
        var firstPass = progress.TakeWhile(item => item.Phase == LanScanPhase.FirstPass).ToArray();
        var arp = progress.Where(item => item.Phase == LanScanPhase.Arp).ToArray();
        var retry = progress.Where(item => item.Phase is LanScanPhase.Retry or LanScanPhase.FinalRetry).ToArray();
        Assert.Equal(Enumerable.Range(1, 6), firstPass.Select(item => item.Completed).Order());
        Assert.All(firstPass, item => Assert.Equal(6, item.Total));
        Assert.Equal(Enumerable.Range(0, 5), arp.Select(item => item.Completed).Order());
        Assert.All(arp, item => Assert.Equal(4, item.Total));
        Assert.Equal([LanScanPhase.FirstPass, LanScanPhase.Arp, LanScanPhase.RetryWait,
            LanScanPhase.Retry, LanScanPhase.FinalRetryWait, LanScanPhase.FinalRetry],
            progress.Select(item => item.Phase).Distinct());
        Assert.Equal(new LanScanProgress(LanScanPhase.Retry, 0, 4), retry[0]);
        Assert.Equal(Enumerable.Range(0, 5), retry.Take(5).Select(item => item.Completed).Order());
        Assert.All(retry.Take(5), item => Assert.Equal(4, item.Total));
        Assert.Equal(Enumerable.Range(0, 4), retry.Skip(5).Select(item => item.Completed).Order());
        Assert.All(retry.Skip(5), item => Assert.Equal(3, item.Total));
        Assert.Equal(6, _results.Items.Count);
    }

    [Fact]
    public async Task SlowArpOnAFullSubnetReplacesTheCompletedIcmpCounterAndThenFinishesBothRetries()
    {
        _icmp.Respond = (address, _) => address == "192.0.2.1" ? ScriptedIcmp.Reply() : ScriptedIcmp.Miss();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var arpCalls = 0;
        _arp = async (_, _, token) =>
        {
            if (Interlocked.Increment(ref arpCalls) == 8) started.TrySetResult();
            await release.Task.WaitAsync(token);
            return null;
        };
        var checkpoints = new Recorder<(IReadOnlyList<ScanResult> Results, ScanCheckpointState State)>();
        var scan = Scanner().ScanAsync(Network with { PrefixLength = 24 }, _results, _progress,
            checkpoint: (results, state) =>
            {
                checkpoints.Report((results, state));
                return Task.CompletedTask;
            });
        Assert.Equal(new LanScanProgress(LanScanPhase.Arp, 0, 253),
            await _progress.WaitForAsync(item => item.Phase == LanScanPhase.Arp));
        await started.Task.WaitAsync(Timeout);
        Assert.Equal(254, _icmp.Attempts.Count);
        Assert.Equal(8, Volatile.Read(ref arpCalls));
        Assert.Equal(LanScanPhase.Arp, _progress.Items.Last().Phase);
        Assert.False(scan.IsCompleted);
        var initial = Assert.Single(checkpoints.Items);
        Assert.Equal(ScanCheckpointState.Pending, initial.State);
        Assert.Equal("192.0.2.1", Assert.Single(initial.Results).AddressText);

        release.SetResult();
        await _progress.WaitForAsync(item => item.Phase == LanScanPhase.RetryWait);
        _time.Advance(LanScannerService.RetryPause);
        await FinishSecondRetryAsync();
        Assert.Equal(new ScanSummary(254, 1, 253), await scan.WaitAsync(Timeout));
        Assert.Equal(253, arpCalls);
        Assert.Equal(254 + 253 * 2, _icmp.Attempts.Count);
        Assert.Equal(Enumerable.Range(0, 254),
            _progress.Items.Where(item => item.Phase == LanScanPhase.Arp).Select(item => item.Completed).Order());
        Assert.Equal(254, _results.Items.Count);
    }

    [Fact]
    public async Task NoFirstPassMissesSkipsThePauseAndRetry()
    {
        _icmp.Respond = (_, _) => ScriptedIcmp.Reply();
        var checkpoints = new Recorder<ScanCheckpointState>();
        var summary = await Scanner().ScanAsync(Network, _results, _progress, checkpoint: (_, state) =>
        {
            checkpoints.Report(state);
            return Task.CompletedTask;
        }).WaitAsync(Timeout);

        Assert.Equal(new ScanSummary(6, 6, 0), summary);
        Assert.Equal(Enumerable.Repeat(1, 6), Addresses.Select(_icmp.AttemptsFor));
        Assert.DoesNotContain(_progress.Items, item => item.Phase == LanScanPhase.Retry);
        Assert.All(_progress.Items, item => Assert.Equal(LanScanPhase.FirstPass, item.Phase));
        Assert.Equal(ScanCheckpointState.Complete, Assert.Single(checkpoints.Items));
        Assert.Equal(Addresses, _results.Items.Select(result => result.AddressText).Order());
    }

    [Fact]
    public async Task InitialCheckpointFailureStopsBeforeAnyBackgroundArp()
    {
        var arpCalls = 0;
        _arp = (_, _, _) =>
        {
            Interlocked.Increment(ref arpCalls);
            return Task.FromResult<PhysicalAddress?>(null);
        };
        var error = await Assert.ThrowsAsync<IOException>(() =>
            Scanner().ScanAsync(Network, _results, _progress, checkpoint: (_, _) =>
                Task.FromException(new IOException("Initial checkpoint failed."))));
        Assert.Equal("Initial checkpoint failed.", error.Message);
        Assert.Equal(0, arpCalls);
        Assert.All(_progress.Items, item => Assert.Equal(LanScanPhase.FirstPass, item.Phase));
    }

    [Fact]
    public async Task PersistentMissesProduceOneUnreachableResultPerAddressAndNoFourthAttempt()
    {
        var scan = Scanner().ScanAsync(Network, _results, _progress);
        await _progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
        Assert.Empty(_results.Items);
        _time.Advance(LanScannerService.RetryPause);
        await FinishSecondRetryAsync();

        Assert.Equal(new ScanSummary(6, 0, 6), await scan.WaitAsync(Timeout));
        Assert.Equal(Enumerable.Repeat(3, 6), Addresses.Select(_icmp.AttemptsFor));
        Assert.Equal(Addresses, _results.Items.Select(result => result.AddressText).Order());
        Assert.All(_results.Items, result => Assert.Equal(HostStatus.Unreachable, result.Status));
        Assert.Empty(_enricher.Enriched);
    }

    [Fact]
    public async Task RetryUsesTheSameTimeoutAndConcurrencyAndStartsOnlyAfterTheFirstPass()
    {
        _icmp.Respond = async (_, _) =>
        {
            await Task.Delay(5);
            return new IcmpEchoReply(IPStatus.TimedOut, 0, null);
        };

        var scan = Scanner(timeoutMilliseconds: 123, maximumConcurrency: 2).ScanAsync(Network, _results, _progress);
        await _progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
        _time.Advance(LanScannerService.RetryPause);
        await FinishSecondRetryAsync();
        await scan.WaitAsync(Timeout);

        Assert.InRange(_icmp.PeakConcurrency, 1, 2);
        Assert.All(_icmp.Attempts, attempt => Assert.Equal(123, attempt.Timeout));
        Assert.Equal(Enumerable.Repeat(1, 6).Concat(Enumerable.Repeat(2, 6)).Concat(Enumerable.Repeat(3, 6)),
            _icmp.Attempts.Select(attempt => attempt.Attempt));
    }

    [Fact]
    public async Task CancellationDuringThePauseStopsBeforeAnyRetryOrMissResult()
    {
        _icmp.Respond = (address, _) => address == "192.0.2.1" ? ScriptedIcmp.Reply() : ScriptedIcmp.Miss();
        using var cancellation = new CancellationTokenSource();

        var scan = Scanner().ScanAsync(Network, _results, _progress, cancellation.Token);
        await _progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan.WaitAsync(Timeout));
        Assert.Equal(6, _icmp.Attempts.Count);
        Assert.Equal("192.0.2.1", Assert.Single(_results.Items).AddressText);
    }

    [Fact]
    public async Task CancellationDuringTheRetryDoesNotReportTheRetryReply()
    {
        var retryStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var retryReply = new TaskCompletionSource<IcmpEchoReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        _icmp.Respond = (address, attempt) =>
        {
            if (address != "192.0.2.2") return ScriptedIcmp.Reply();
            if (attempt == 1) return ScriptedIcmp.Miss();
            retryStarted.SetResult();
            return retryReply.Task;
        };
        using var cancellation = new CancellationTokenSource();

        var scan = Scanner().ScanAsync(Network, _results, _progress, cancellation.Token);
        await _progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
        _time.Advance(LanScannerService.RetryPause);
        await retryStarted.Task.WaitAsync(Timeout);
        cancellation.Cancel();
        retryReply.SetResult(new IcmpEchoReply(IPStatus.Success, 1, 64));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan.WaitAsync(Timeout));
        Assert.DoesNotContain(_results.Items, result => result.AddressText == "192.0.2.2");
        Assert.DoesNotContain("192.0.2.2", _enricher.Enriched.Select(address => address.ToString()));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public async Task UnexpectedProbeErrorsFailTheScanInsteadOfCountingAsMisses(int failingAttempt)
    {
        _icmp.Respond = (address, attempt) => address != "192.0.2.3"
            ? ScriptedIcmp.Reply()
            : attempt == failingAttempt
                ? Task.FromException<IcmpEchoReply>(new InvalidOperationException("adapter failed"))
                : ScriptedIcmp.Miss();

        var scan = Scanner().ScanAsync(Network, _results, _progress);
        if (failingAttempt == 2)
        {
            await _progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
            _time.Advance(LanScannerService.RetryPause);
        }

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => scan.WaitAsync(Timeout));
        Assert.Equal("adapter failed", error.Message);
        Assert.DoesNotContain(_results.Items, result => result.AddressText == "192.0.2.3");
    }

    [Theory]
    [InlineData(nameof(ScanTrigger.Manual))]
    [InlineData(nameof(ScanTrigger.Scheduled))]
    public async Task SharedExecutionSavesOneResultPerRecoveredResponder(string triggerName)
    {
        _icmp.Respond = (address, attempt) => address == "192.0.2.1" || address == "192.0.2.4" && attempt == 2
            ? ScriptedIcmp.Reply() : ScriptedIcmp.Miss();
        var steps = new ScannerSteps(Scanner());
        var execution = new ScanExecution(new NetworkActivityCoordinator(), steps);

        var run = execution.RunAsync(new ScanRequest(Enum.Parse<ScanTrigger>(triggerName), Network));
        await steps.Progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
        Assert.Empty(steps.Saves);
        _time.Advance(LanScannerService.RetryPause);
        await steps.Progress.WaitForAsync(progress => progress.Phase == LanScanPhase.FinalRetryWait);
        _time.Advance(LanScannerService.RetryPause);
        var outcome = await run.WaitAsync(Timeout);

        Assert.Equal(ScanRunStatus.Completed, outcome.Status);
        var saved = Assert.Single(steps.Saves);
        Assert.Equal(["192.0.2.1", "192.0.2.4"], saved.Select(result => result.AddressText).Order());
        Assert.All(saved, result => Assert.Equal(HostStatus.Alive, result.Status));
        Assert.Equal(outcome, Assert.Single(steps.Ended));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SharedExecutionCancellationDuringThePauseOrRetrySavesNothing(bool duringRetry)
    {
        var retryStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var retryReply = new TaskCompletionSource<IcmpEchoReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        _icmp.Respond = (address, attempt) =>
        {
            if (address == "192.0.2.1") return ScriptedIcmp.Reply();
            if (attempt == 1) return ScriptedIcmp.Miss();
            retryStarted.TrySetResult();
            return retryReply.Task;
        };
        var steps = new ScannerSteps(Scanner());
        var execution = new ScanExecution(new NetworkActivityCoordinator(), steps);

        var run = execution.RunAsync(new ScanRequest(ScanTrigger.Scheduled, Network));
        await steps.Progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
        if (duringRetry)
        {
            _time.Advance(LanScannerService.RetryPause);
            await retryStarted.Task.WaitAsync(Timeout);
        }

        steps.Cancellation!.Cancel();
        retryReply.SetResult(new IcmpEchoReply(IPStatus.Success, 1, 64));
        var outcome = await run.WaitAsync(Timeout);

        Assert.Equal(ScanRunStatus.Cancelled, outcome.Status);
        Assert.Empty(steps.Saves);
        Assert.Equal(duringRetry, retryStarted.Task.IsCompleted);
    }

    [Fact]
    public async Task SharedExecutionReportsARetryErrorAsAFailureWithoutSaving()
    {
        _icmp.Respond = (address, attempt) => address == "192.0.2.1"
            ? ScriptedIcmp.Reply()
            : attempt == 2 && address == "192.0.2.6"
                ? Task.FromException<IcmpEchoReply>(new InvalidOperationException("adapter failed"))
                : ScriptedIcmp.Miss();
        var steps = new ScannerSteps(Scanner());
        var execution = new ScanExecution(new NetworkActivityCoordinator(), steps);

        var run = execution.RunAsync(new ScanRequest(ScanTrigger.Manual, Network));
        await steps.Progress.WaitForAsync(progress => progress.Phase == LanScanPhase.RetryWait);
        _time.Advance(LanScannerService.RetryPause);
        var outcome = await run.WaitAsync(Timeout);

        Assert.Equal(ScanRunStatus.Failed, outcome.Status);
        Assert.Equal("adapter failed", outcome.Message);
        Assert.Empty(steps.Saves);
    }

    [Fact]
    public async Task FreshArpRecoversPingSilentDevicesBeforeRetriesAndPreservesItsMacWithoutLatencyOrTtl()
    {
        var arpCalls = new ConcurrentQueue<string>();
        var mac = PhysicalAddress.Parse("001122334499");
        _icmp.Respond = (address, _) => address == "192.0.2.1" ? ScriptedIcmp.Reply() : ScriptedIcmp.Miss();
        _arp = (address, network, _) =>
        {
            Assert.Equal(Network, network);
            arpCalls.Enqueue(address.ToString());
            return Task.FromResult<PhysicalAddress?>(mac);
        };
        var checkpoints = new Recorder<(IReadOnlyList<ScanResult> Results, ScanCheckpointState State)>();

        var summary = await Scanner().ScanAsync(Network, _results, _progress, checkpoint: (results, state) =>
        {
            checkpoints.Report((results, state));
            return Task.CompletedTask;
        }).WaitAsync(Timeout);

        Assert.Equal(new ScanSummary(6, 6, 0), summary);
        Assert.Equal(Addresses.Skip(1), arpCalls.Order());
        Assert.Equal(Enumerable.Repeat(1, 6), Addresses.Select(_icmp.AttemptsFor));
        Assert.Equal(2, checkpoints.Items.Count);
        Assert.Equal(ScanCheckpointState.Pending, checkpoints.Items.First().State);
        Assert.Single(checkpoints.Items.First().Results);
        var saved = checkpoints.Items.Last();
        Assert.Equal(ScanCheckpointState.Complete, saved.State);
        Assert.Equal(6, saved.Results.Count);
        Assert.All(saved.Results.Where(result => result.AddressText != "192.0.2.1"), result =>
        {
            Assert.Equal(mac, result.MacAddress);
            Assert.Null(result.RoundtripTimeMilliseconds);
        });
        Assert.All(_enricher.Ttls.Where(item => item.Address != "192.0.2.1"), item => Assert.Null(item.Ttl));
        Assert.DoesNotContain(_progress.Items, item => item.Phase == LanScanPhase.Retry);
    }

    [Fact]
    public async Task EachPhaseAwaitsItsCheckpointBeforeStartingItsOwnTenSecondTimer()
    {
        _icmp.Respond = (address, attempt) => address == "192.0.2.1" || address == "192.0.2.2" && attempt == 3
            ? ScriptedIcmp.Reply() : ScriptedIcmp.Miss();
        var initialWrite = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var checkpoints = new Recorder<(IReadOnlyList<ScanResult> Results, ScanCheckpointState State)>();
        var scan = Scanner().ScanAsync(Network, _results, _progress, checkpoint: async (results, state) =>
        {
            checkpoints.Report((results, state));
            if (checkpoints.Items.Count == 1) await initialWrite.Task;
        });
        var initial = await checkpoints.WaitForAsync(_ => true);
        Assert.Equal(ScanCheckpointState.Pending, initial.State);
        Assert.Single(initial.Results);
        _time.Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(6, _icmp.Attempts.Count);
        Assert.DoesNotContain(_progress.Items, item => item.Phase == LanScanPhase.Arp);
        initialWrite.SetResult();
        await _progress.WaitForAsync(item => item.Phase == LanScanPhase.RetryWait);
        _time.Advance(TimeSpan.FromMilliseconds(9999));
        await Task.Delay(20);
        Assert.Equal(6, _icmp.Attempts.Count);
        _time.Advance(TimeSpan.FromMilliseconds(1));
        await _progress.WaitForAsync(item => item.Phase == LanScanPhase.FinalRetryWait);
        Assert.Equal(11, _icmp.Attempts.Count);
        _time.Advance(TimeSpan.FromMilliseconds(9999));
        await Task.Delay(20);
        Assert.Equal(11, _icmp.Attempts.Count);
        _time.Advance(TimeSpan.FromMilliseconds(1));
        Assert.Equal(new ScanSummary(6, 2, 4), await scan.WaitAsync(Timeout));
        Assert.Equal([ScanCheckpointState.Pending, ScanCheckpointState.Pending, ScanCheckpointState.Pending, ScanCheckpointState.Complete],
            checkpoints.Items.Select(item => item.State));
        Assert.Equal([1, 1, 1, 2], checkpoints.Items.Select(item => item.Results.Count));
    }

    [Fact]
    public async Task FirstRetryRecoveringAllMissesSkipsTheSecondWaitAndCompletesOnce()
    {
        _icmp.Respond = (_, attempt) => attempt == 2 ? ScriptedIcmp.Reply() : ScriptedIcmp.Miss();
        var checkpoints = new Recorder<ScanCheckpointState>();
        var scan = Scanner().ScanAsync(Network, _results, _progress, checkpoint: (_, state) =>
        {
            checkpoints.Report(state);
            return Task.CompletedTask;
        });
        await _progress.WaitForAsync(item => item.Phase == LanScanPhase.RetryWait);
        _time.Advance(LanScannerService.RetryPause);
        Assert.Equal(new ScanSummary(6, 6, 0), await scan.WaitAsync(Timeout));
        Assert.Equal([ScanCheckpointState.Pending, ScanCheckpointState.Pending, ScanCheckpointState.Complete], checkpoints.Items);
        Assert.Equal(Enumerable.Repeat(2, 6), Addresses.Select(_icmp.AttemptsFor));
    }

    [Theory]
    [InlineData("000000000000")]
    [InlineData("FFFFFFFFFFFF")]
    [InlineData("010000000001")]
    [InlineData("001122")]
    public async Task InvalidFreshArpMacFailsExplicitly(string mac)
    {
        _arp = (_, _, _) => Task.FromResult<PhysicalAddress?>(PhysicalAddress.Parse(mac));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Scanner().ScanAsync(Network, _results, _progress));
        Assert.Empty(_results.Items);
    }

    [Fact]
    public async Task CancellationDuringArpDrainsTheProbeAndRejectsItsLateReply()
    {
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reply = new TaskCompletionSource<PhysicalAddress?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _arp = (_, _, _) => { started.TrySetResult(); return reply.Task; };
        using var cancellation = new CancellationTokenSource();
        var scan = Scanner().ScanAsync(Network, _results, _progress, cancellation.Token);
        await started.Task.WaitAsync(Timeout);
        cancellation.Cancel();
        Assert.False(scan.IsCompleted);
        reply.SetResult(PhysicalAddress.Parse("001122334455"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan.WaitAsync(Timeout));
        Assert.Empty(_results.Items);
    }

    [Fact]
    public async Task UnexpectedArpFailuresFailExplicitlyInsteadOfBecomingMisses()
    {
        _arp = (_, _, _) => Task.FromException<PhysicalAddress?>(new InvalidOperationException("ARP adapter failure"));
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            Scanner().ScanAsync(Network, _results, _progress));
        Assert.Equal("ARP adapter failure", error.Message);
        Assert.Empty(_results.Items);
        Assert.DoesNotContain(_progress.Items, item => item.Phase == LanScanPhase.Retry);
    }

    [Fact]
    public async Task ArpConcurrencyIsBoundedIndependentlyOfPingConcurrency()
    {
        var inFlight = 0;
        var peak = 0;
        _arp = async (_, _, _) =>
        {
            var current = Interlocked.Increment(ref inFlight);
            int previous;
            while (current > (previous = Volatile.Read(ref peak))
                && Interlocked.CompareExchange(ref peak, current, previous) != previous) { }
            await Task.Delay(10);
            Interlocked.Decrement(ref inFlight);
            return null;
        };
        using var cancellation = new CancellationTokenSource();
        var scan = Scanner().ScanAsync(Network with { PrefixLength = 27 }, _results, _progress, cancellation.Token);
        await _progress.WaitForAsync(item => item.Phase == LanScanPhase.RetryWait);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan.WaitAsync(Timeout));
        Assert.InRange(peak, 1, 8);
        Assert.Equal(0, inFlight);
        Assert.Equal(30, _icmp.Attempts.Count);
    }

    [Fact]
    public async Task CancellationDuringTheSecondPauseDoesNotStartAThirdPingRound()
    {
        using var cancellation = new CancellationTokenSource();
        var checkpoints = new Recorder<ScanCheckpointState>();
        var scan = Scanner().ScanAsync(Network, _results, _progress, cancellation.Token, (_, state) =>
        {
            checkpoints.Report(state);
            return Task.CompletedTask;
        });
        await _progress.WaitForAsync(item => item.Phase == LanScanPhase.RetryWait);
        _time.Advance(LanScannerService.RetryPause);
        await _progress.WaitForAsync(item => item.Phase == LanScanPhase.FinalRetryWait);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan.WaitAsync(Timeout));
        Assert.Equal(Enumerable.Repeat(2, 6), Addresses.Select(_icmp.AttemptsFor));
        Assert.Equal([ScanCheckpointState.Pending, ScanCheckpointState.Pending, ScanCheckpointState.Pending], checkpoints.Items);
        Assert.Empty(_results.Items);
    }

    private sealed class ScriptedIcmp
    {
        private readonly ConcurrentDictionary<string, int> _counts = new();
        private int _inFlight;
        private int _peakConcurrency;

        public ConcurrentQueue<(string Address, int Attempt, int Timeout)> Attempts { get; } = new();

        public Func<string, int, Task<IcmpEchoReply>> Respond { get; set; } = (_, _) => Miss();

        public int PeakConcurrency => Volatile.Read(ref _peakConcurrency);

        public static Task<IcmpEchoReply> Reply() => Task.FromResult(new IcmpEchoReply(IPStatus.Success, 3, 64));

        public static Task<IcmpEchoReply> Miss(IPStatus status = IPStatus.TimedOut) =>
            Task.FromResult(new IcmpEchoReply(status, 0, null));

        public static Task<IcmpEchoReply> PingFailure() =>
            Task.FromException<IcmpEchoReply>(new PingException("transient ping failure"));

        public int AttemptsFor(string address) => _counts.GetValueOrDefault(address);

        public async Task<IcmpEchoReply> SendAsync(IPAddress address, int timeoutMilliseconds)
        {
            var text = address.ToString();
            var attempt = _counts.AddOrUpdate(text, 1, (_, count) => count + 1);
            Attempts.Enqueue((text, attempt, timeoutMilliseconds));
            var inFlight = Interlocked.Increment(ref _inFlight);
            int peak;
            while (inFlight > (peak = Volatile.Read(ref _peakConcurrency))
                && Interlocked.CompareExchange(ref _peakConcurrency, inFlight, peak) != peak)
            {
            }

            try
            {
                return await Respond(text, attempt);
            }
            finally
            {
                Interlocked.Decrement(ref _inFlight);
            }
        }
    }

    private sealed class RecordingEnricher : IScanResultEnricher
    {
        public ConcurrentQueue<IPAddress> Enriched { get; } = new();
        public ConcurrentQueue<(string Address, int? Ttl)> Ttls { get; } = new();

        public Task<ScanEnrichment> EnrichAsync(
            IPAddress address, Task<ScanDiscovery> discoveryTask, CancellationToken cancellationToken, int? responseTtl = null)
        {
            Enriched.Enqueue(address);
            Ttls.Enqueue((address.ToString(), responseTtl));
            var host = address.GetAddressBytes()[3];
            return Task.FromResult(new ScanEnrichment(
                $"device-{host}", PhysicalAddress.Parse($"0011223344{host:X2}"), "Example", []));
        }
    }

    private sealed class Recorder<T> : IProgress<T>
    {
        private readonly Channel<T> _channel = Channel.CreateUnbounded<T>();

        public ConcurrentQueue<T> Items { get; } = new();

        public void Report(T value)
        {
            Items.Enqueue(value);
            _channel.Writer.TryWrite(value);
        }

        public async Task<T> WaitForAsync(Func<T, bool> predicate)
        {
            using var timeout = new CancellationTokenSource(Timeout);
            while (true)
            {
                var value = await _channel.Reader.ReadAsync(timeout.Token);
                if (predicate(value)) return value;
            }
        }
    }

    // Runs the real scanner and result buffer through the shared execution path, as MainWindow does.
    private sealed class ScannerSteps(LanScannerService scanner) : IScanExecutionSteps
    {
        private readonly ConcurrentQueue<IReadOnlyList<ScanResult>> _saves = new();
        private readonly ConcurrentQueue<ScanRunOutcome> _ended = new();

        public Recorder<LanScanProgress> Progress { get; } = new();

        public CancellationTokenSource? Cancellation { get; private set; }

        public IReadOnlyList<IReadOnlyList<ScanResult>> Saves => _saves.ToArray();

        public IReadOnlyList<ScanRunOutcome> Ended => _ended.ToArray();

        public void BeginScan(ScanRequest request, CancellationTokenSource cancellation) => Cancellation = cancellation;

        public string? CaptureNetworkIdentity(LanNetwork network) => "network-a";

        public async Task<IReadOnlyList<ScanResult>> ScanAsync(ScanRequest request, CancellationToken cancellationToken)
        {
            var buffer = new ScanResultBuffer();
            await scanner.ScanAsync(request.Network, buffer, Progress, cancellationToken);
            return buffer.Results;
        }

        public Task<ScanSaveResult> SaveAsync(
            ScanRequest request, IReadOnlyList<ScanResult> results, string? networkId, bool networkChanged, TimeSpan duration)
        {
            _saves.Enqueue(results);
            return Task.FromResult(new ScanSaveResult([]));
        }

        public void EndScan(ScanRequest request, ScanRunOutcome outcome) => _ended.Enqueue(outcome);
    }
}
