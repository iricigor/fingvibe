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
        var snapshot = DecoSnapshot.Create(clients, DateTimeOffset.Parse("2026-11-15T22:00:00+01:00"));
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
            Assert.Equal(DecoRouterPolicy.SourceUrl, root.GetProperty("sourceUrl").GetString());
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
}
