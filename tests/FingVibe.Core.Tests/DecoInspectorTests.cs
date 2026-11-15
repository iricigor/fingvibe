using System.IO;
using System.Text.Json;
using DecoX50Inspector;
using Ex220Inspector;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DecoInspectorTests
{
    private static DecoClient Client(string mac = "00-28-F8-9E-88-51", string ip = "192.168.0.110") =>
        new(" T470s ", mac, ip, "Wireless (5G)");

    [Fact]
    public async Task ExportWritesFullImmutableSnapshotWithMetadataAndNoDatabaseOrBrowserSecrets()
    {
        var clients = new[] { Client(), new DecoClient("WDMyCloud", "00:90:A9:EE:92:65", "192.168.0.123", "Wired") };
        var snapshot = DecoSnapshot.Create(clients, DateTimeOffset.Parse("2026-11-15T22:00:00+01:00"),
            new("192.168.0.111"));
        clients[0] = Client(ip: "192.168.0.99");
        var path = Path.Combine(Path.GetTempPath(), $"deco-export-{Guid.NewGuid():N}.json");
        try
        {
            await snapshot.ExportAsync(path, CancellationToken.None);
            using var result = JsonDocument.Parse(await File.ReadAllTextAsync(path));
            var root = result.RootElement;
            Assert.Equal(1, root.GetProperty("schemaVersion").GetInt32());
            Assert.Equal(2, root.GetProperty("clientCount").GetInt32());
            Assert.Equal(2, root.GetProperty("clients").GetArrayLength());
            foreach (var client in root.GetProperty("clients").EnumerateArray())
                Assert.Equal(new[] { "name", "mac", "ip", "connection" },
                    client.EnumerateObject().Select(property => property.Name));
            Assert.Equal("https://192.168.0.111/webpages/index.html#networkMap", root.GetProperty("sourceUrl").GetString());
            Assert.Equal(TimeSpan.Zero, root.GetProperty("capturedAtUtc").GetDateTimeOffset().Offset);
            Assert.Contains(snapshot.Clients, client => client.Mac == "00:28:F8:9E:88:51" && client.Ip == "192.168.0.110");
            Assert.All(root.EnumerateObject(), property =>
                Assert.Contains(property.Name, new[] { "schemaVersion", "router", "sourceUrl", "capturedAtUtc", "clientCount", "clients" }));
            var filtered = ClientCapture.FilterRows(snapshot.ComparisonRows()
                .Select(row => row with { DbComparison = "Same in DB" }), true);
            Assert.Empty(filtered);
            Assert.Equal(2, snapshot.Clients.Count);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public async Task CancelledExportPreservesAnExistingFileAndCleansTemporaryFile()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"deco-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "snapshot.json");
        try
        {
            await File.WriteAllTextAsync(path, "previous");
            using var cancellation = new CancellationTokenSource();
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
                DecoSnapshot.Create([Client()], DateTimeOffset.UtcNow).ExportAsync(path, cancellation.Token));
            Assert.Equal("previous", await File.ReadAllTextAsync(path));
            Assert.Single(Directory.GetFiles(directory));
            await Assert.ThrowsAsync<DirectoryNotFoundException>(() =>
                DecoSnapshot.Create([Client()], DateTimeOffset.UtcNow)
                    .ExportAsync(Path.Combine(directory, "missing", "snapshot.json"), CancellationToken.None));
        }
        finally
        {
            File.Delete(path);
            Directory.Delete(directory);
        }
    }

    [Fact]
    public void RejectsDuplicateMacsAndInvalidIpv4ButKeepsDifferentMacsSharingAnAddressSeparate()
    {
        Assert.Throws<InvalidDataException>(() => DecoSnapshot.Create(
            [Client(), Client("00:28:F8:9E:88:51")], DateTimeOffset.UtcNow));
        Assert.Throws<InvalidDataException>(() => DecoSnapshot.Create([Client(ip: "999.1.1.1")], DateTimeOffset.UtcNow));
        var snapshot = DecoSnapshot.Create([Client(), Client("00:0C:29:2F:62:B2")], DateTimeOffset.UtcNow);
        Assert.Equal(2, snapshot.ClientCount);
    }

    [Theory]
    [InlineData("https://192.168.0.100/webpages/index.html", "approved", true)]
    [InlineData("https://192.168.0.100/webpages/index.html", "changed", false)]
    [InlineData("http://192.168.0.100/", "approved", false)]
    [InlineData("https://192.168.0.1/", "approved", false)]
    [InlineData("https://192.168.0.100:8443/", "approved", false)]
    [InlineData("https://user@192.168.0.100/", "approved", false)]
    [InlineData("https://192.168.0.100.example.com/", "approved", false)]
    public void CertificateApprovalRequiresExactOriginAndExactFingerprint(string uri, string fingerprint, bool trusted)
    {
        Assert.Equal(trusted, DecoRouterPolicy.IsTrusted(uri, fingerprint, "approved"));
        Assert.False(DecoRouterPolicy.IsTrusted(uri, fingerprint, null));
    }

    [Theory]
    [InlineData("192.168.0.111", "https://192.168.0.111/webpages/index.html#networkMap", true)]
    [InlineData("192.168.0.111", "https://192.168.0.100/", false)]
    [InlineData("192.168.0.111", "http://192.168.0.111/", false)]
    [InlineData("192.168.0.111", "https://192.168.0.111:8443/", false)]
    [InlineData("192.168.0.111", "https://user@192.168.0.111/", false)]
    [InlineData("192.168.0.111", "https://192.168.0.111.example.com/", false)]
    public void ConfiguredEndpointRestrictsNavigationAndCertificateTrust(string ip, string url, bool allowed)
    {
        var router = new DecoRouterPolicy(ip);
        Assert.Equal(allowed, router.Allows(url));
        Assert.Equal(allowed, router.Trusts(url, "approved", "approved"));
        Assert.False(router.Trusts(url, "changed", "approved"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("192.168.0.999")]
    [InlineData("192.168.111")]
    [InlineData("192.168.000.111")]
    [InlineData("https://192.168.0.111/")]
    [InlineData("192.168.0.111:443")]
    [InlineData("127.0.0.1")]
    [InlineData("0.0.0.0")]
    [InlineData("224.0.0.1")]
    public void InvalidConfiguredEndpointsFailExplicitly(string ip) =>
        Assert.Throws<ArgumentException>(() => new DecoRouterPolicy(ip));

    [Fact]
    public void ConfiguredCertificateStoresCannotReuseTheOriginalEndpointsApproval()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"deco-endpoints-{Guid.NewGuid():N}");
        var originalPath = DecoCertificateStore.PathFor(new());
        Assert.Equal(DecoCertificateStore.DefaultPath, originalPath);
        var original = new DecoCertificateStore(Path.Combine(directory, Path.GetFileName(originalPath)));
        var otherPath = Path.Combine(directory, Path.GetFileName(DecoCertificateStore.PathFor(new("192.168.0.111"))));
        var other = new DecoCertificateStore(otherPath);
        try
        {
            original.Save(new string('A', 64));
            Assert.Null(other.Load());
            other.Save(new string('B', 64));
            Assert.Equal(new string('A', 64), original.Load());
            Assert.Equal(new string('B', 64), new DecoCertificateStore(otherPath).Load());
        }
        finally
        {
            foreach (var path in Directory.GetFiles(directory)) File.Delete(path);
            Directory.Delete(directory);
        }
    }

    [Fact]
    public async Task RepairedPageWithoutMapControlsCanCaptureAStableEmptySnapshotWithSelectedEndpoint()
    {
        await DecoClientNavigation.OpenAsync((_, _) => Task.FromResult(false),
            _ => Task.FromResult(true), CancellationToken.None);
        await Assert.ThrowsAsync<InspectorTransientCaptureException>(() =>
            DecoClientNavigation.OpenAsync((_, _) => Task.FromResult(false),
                _ => Task.FromResult(false), CancellationToken.None));
        var time = new FakeTimeProvider();
        var reads = 0;
        var capture = DecoCaptureRunner.CaptureAsync(_ => Task.CompletedTask,
            _ => { reads++; return Task.FromResult(new DecoProbe("Ready", "", 0, [])); },
            (_, _) => { }, CancellationToken.None, time, new("192.168.0.111"));
        time.Advance(TimeSpan.FromMilliseconds(300));
        var snapshot = await capture.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(2, reads);
        Assert.Empty(snapshot.Clients);
        Assert.Equal("https://192.168.0.111/webpages/index.html#networkMap", snapshot.SourceUrl);
        Assert.Equal("TP-Link Deco", snapshot.Router);
        using var cancellation = new CancellationTokenSource();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            DecoClientNavigation.OpenAsync((_, _) => Task.FromResult(false), _ =>
            {
                cancellation.Cancel();
                return Task.FromResult(true);
            }, cancellation.Token));
    }

    [Fact]
    public void CertificateApprovalSurvivesStoreRecreationButOnlyTrustsTheExactRouterAndCertificate()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"deco-pin-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "approved.sha256");
        var fingerprint = new string('a', 64);
        try
        {
            Assert.Null(new DecoCertificateStore(path).Load());
            Assert.False(Directory.Exists(directory));
            new DecoCertificateStore(path).Save(fingerprint);
            var loaded = new DecoCertificateStore(path).Load();
            Assert.Equal(fingerprint.ToUpperInvariant(), loaded);
            Assert.Equal(fingerprint.ToUpperInvariant() + "\n", File.ReadAllText(path));
            Assert.Single(Directory.GetFiles(directory));
            Assert.True(DecoRouterPolicy.IsTrusted(DecoRouterPolicy.SourceUrl, fingerprint.ToUpperInvariant(), loaded));
            Assert.False(DecoRouterPolicy.IsTrusted(DecoRouterPolicy.SourceUrl, new string('B', 64), loaded));
            Assert.False(DecoRouterPolicy.IsTrusted("https://192.168.0.1/", fingerprint.ToUpperInvariant(), loaded));
            if (OperatingSystem.IsWindows())
            {
                File.SetAttributes(path, FileAttributes.ReadOnly);
                Assert.True(Record.Exception(() => new DecoCertificateStore(path).Save(new string('B', 64)))
                    is IOException or UnauthorizedAccessException);
                Assert.Equal(loaded, new DecoCertificateStore(path).Load());
                Assert.Single(Directory.GetFiles(directory));
            }
        }
        finally
        {
            if (File.Exists(path))
            {
                File.SetAttributes(path, FileAttributes.Normal);
                File.Delete(path);
            }
            if (Directory.Exists(directory)) Directory.Delete(directory);
        }
    }

    [Theory]
    [InlineData("")]
    [InlineData("invalid")]
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAG")]
    public void InvalidStoredCertificateApprovalFailsExplicitlyWithoutWeakeningOrOverwritingTrust(string invalid)
    {
        var path = Path.Combine(Path.GetTempPath(), $"deco-pin-{Guid.NewGuid():N}.sha256");
        try
        {
            File.WriteAllText(path, invalid);
            Assert.Throws<InvalidDataException>(() => new DecoCertificateStore(path).Load());
            new DecoCertificateStore(path).Save(new string('A', 64));
            Assert.Throws<InvalidDataException>(() => new DecoCertificateStore(path).Save(invalid));
            Assert.Equal(new string('A', 64), new DecoCertificateStore(path).Load());
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }

    [Fact]
    public void OversizedApprovalAndFailedReplacementRemainErrorsAndCleanTheirTemporaryFile()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"deco-pin-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "approved.sha256");
        try
        {
            File.WriteAllText(path, new string('A', 257));
            Assert.Throws<InvalidDataException>(() => new DecoCertificateStore(path).Load());
            File.Delete(path);
            Directory.CreateDirectory(path);
            Assert.True(Record.Exception(() => new DecoCertificateStore(path).Load())
                is IOException or UnauthorizedAccessException);
            Assert.True(Record.Exception(() => new DecoCertificateStore(path).Save(new string('A', 64)))
                is IOException or UnauthorizedAccessException);
            Assert.Empty(Directory.GetFiles(directory));
            Assert.True(Directory.Exists(path));
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            if (Directory.Exists(path)) Directory.Delete(path);
            Directory.Delete(directory);
        }
    }

    [Fact]
    public async Task StableCaptureIgnoresRowOrderingButRequiresTwoCompleteObservations()
    {
        var time = new FakeTimeProvider();
        var reads = 0;
        var first = new[] { Client(), Client("00:90:A9:EE:92:65") };
        var capture = DecoCaptureRunner.CaptureAsync(_ => Task.CompletedTask,
            _ => Task.FromResult(new DecoProbe("Ready", "", 2, ++reads == 1 ? first : first.Reverse().ToArray())),
            (_, _) => { }, CancellationToken.None, time);
        time.Advance(TimeSpan.FromMilliseconds(300));
        var snapshot = await capture.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(2, reads);
        Assert.Equal(2, snapshot.ClientCount);
    }

    [Fact]
    public async Task TransientFailuresRetryFiveTimesWhileMalformedContentStopsImmediately()
    {
        var time = new FakeTimeProvider();
        var attempts = 0;
        var capture = DecoCaptureRunner.CaptureAsync(_ =>
        {
            attempts++;
            throw new TimeoutException("fixture");
        }, _ => throw new InvalidOperationException(), (_, _) => { }, CancellationToken.None, time);
        for (var step = 0; !capture.IsCompleted && step < 100; step++)
        {
            time.Advance(TimeSpan.FromSeconds(2));
            await Task.Delay(1);
        }
        await Assert.ThrowsAsync<InspectorTransientCaptureException>(() => capture.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(5, attempts);
        attempts = 0;
        await Assert.ThrowsAsync<InvalidDataException>(() => DecoCaptureRunner.CaptureAsync(
            _ => { attempts++; return Task.CompletedTask; },
            _ => Task.FromResult(new DecoProbe("Ready", "Malformed MAC", 0, [])),
            (_, _) => { }, CancellationToken.None));
        Assert.Equal(1, attempts);
    }

    [Fact]
    public async Task TerminalLoginAndMalformedCaptureErrorsAreHandledByTheUiFailureFilter()
    {
        foreach (var message in new[] { "Unsupported local login", "Malformed MAC" })
        {
            var failure = await Record.ExceptionAsync(() => DecoCaptureRunner.CaptureAsync(
                _ => throw new InvalidDataException(message),
                _ => throw new InvalidOperationException(), (_, _) => { }, CancellationToken.None));
            Assert.NotNull(failure);
            Assert.True(DecoFailurePolicy.IsBrowserError(failure));
            Assert.Equal(message, failure.Message);
        }
        Assert.False(DecoFailurePolicy.IsBrowserError(new NullReferenceException("unexpected defect")));
    }

    [Fact]
    public async Task CancellationDuringRetryWaitStopsFurtherAttemptsWithoutReturningSnapshot()
    {
        using var cancellation = new CancellationTokenSource();
        var attempts = 0;
        var capture = DecoCaptureRunner.CaptureAsync(_ =>
        {
            attempts++;
            throw new TimeoutException("fixture");
        }, _ => throw new InvalidOperationException(), (_, _) => { }, cancellation.Token);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => capture);
        Assert.Equal(1, attempts);
    }

    [Fact]
    public async Task IncompleteObservationResetsStabilityAndCancellationBeforePublicationNeverReturnsSnapshot()
    {
        var time = new FakeTimeProvider();
        var reads = 0;
        var capture = DecoCaptureRunner.CaptureAsync(_ => Task.CompletedTask,
            _ => Task.FromResult(++reads == 2 ? new DecoProbe("Incomplete", "", 2, []) :
                new DecoProbe("Ready", "", 1, [Client()])),
            (_, _) => { }, CancellationToken.None, time);
        for (var step = 0; !capture.IsCompleted && step < 100; step++)
        {
            time.Advance(TimeSpan.FromMilliseconds(300));
            await Task.Delay(1);
        }
        Assert.Single((await capture.WaitAsync(TimeSpan.FromSeconds(5))).Clients);
        Assert.Equal(4, reads);

        using var cancellation = new CancellationTokenSource();
        reads = 0;
        var cancelled = DecoCaptureRunner.CaptureAsync(_ => Task.CompletedTask, _ =>
        {
            if (++reads == 2) cancellation.Cancel();
            return Task.FromResult(new DecoProbe("Ready", "", 1, [Client()]));
        }, (_, _) => { }, cancellation.Token, time);
        time.Advance(TimeSpan.FromMilliseconds(300));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelled.WaitAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task NavigationUsesClientsDirectlyAndInternetThenClientsOnlyIfTheGridDoesNotOpen()
    {
        var clicks = new List<string>();
        await DecoClientNavigation.OpenAsync((target, _) =>
        {
            clicks.Add(target);
            return Task.FromResult(true);
        }, _ => Task.FromResult(true), CancellationToken.None);
        Assert.Equal(new[] { "clients" }, clicks);

        clicks.Clear();
        var time = new FakeTimeProvider();
        var fallback = DecoClientNavigation.OpenAsync((target, _) =>
        {
            clicks.Add(target);
            return Task.FromResult(true);
        }, _ => Task.FromResult(clicks.Count == 3), CancellationToken.None, time);
        for (var step = 0; !fallback.IsCompleted && step < 100; step++)
        {
            time.Advance(TimeSpan.FromMilliseconds(300));
            await Task.Delay(1);
        }
        await fallback.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(new[] { "clients", "internet", "clients" }, clicks);
    }

    [Fact]
    public async Task CancelledDirectNavigationNeverClicksTheFallback()
    {
        using var cancellation = new CancellationTokenSource();
        var clicks = new List<string>();
        var navigation = DecoClientNavigation.OpenAsync((target, _) =>
        {
            clicks.Add(target);
            return Task.FromResult(true);
        }, _ => Task.FromResult(false), cancellation.Token);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => navigation);
        Assert.Equal(new[] { "clients" }, clicks);
    }
}
