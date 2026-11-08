using System.Diagnostics;
using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceActivityReviewHoldTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-activity-hold-{Guid.NewGuid():N}");
    private string Hold => Path.Combine(_directory, "hold");

    public DeviceActivityReviewHoldTests() => Directory.CreateDirectory(_directory);

    [Fact]
    public async Task MissingHoldDoesNotCreateReviewArtifacts()
    {
        await DeviceActivityReviewHold.WaitAsync(Hold, CancellationToken.None);
        Assert.Empty(Directory.GetFiles(_directory));
    }

    [Fact]
    public async Task CancelledSelectionCannotReleaseOrCancelItsReplacement()
    {
        File.WriteAllText(Hold, "");
        using var cancellation = new CancellationTokenSource();
        var old = DeviceActivityReviewHold.WaitAsync(Hold, cancellation.Token);
        var oldRequest = Assert.Single(Directory.GetFiles(_directory, "*.started"));
        Assert.False(old.IsCompleted);
        var current = DeviceActivityReviewHold.WaitAsync(Hold, CancellationToken.None);
        var currentRequest = Assert.Single(Directory.GetFiles(_directory, "*.started"), path => path != oldRequest);
        var clock = Stopwatch.StartNew();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => old);
        Assert.True(clock.Elapsed <= TimeSpan.FromMilliseconds(250), $"Cancellation took {clock.Elapsed}.");
        Assert.True(File.Exists(Path.ChangeExtension(oldRequest, ".cancelled")));
        Assert.False(File.Exists(Path.ChangeExtension(oldRequest, ".released")));
        Assert.False(current.IsCompleted);
        File.Delete(Hold);
        await current.WaitAsync(TimeSpan.FromSeconds(1));
        Assert.True(File.Exists(Path.ChangeExtension(currentRequest, ".released")));
        Assert.False(File.Exists(Path.ChangeExtension(currentRequest, ".cancelled")));
    }

    [Fact]
    public async Task AlreadyCancelledLoaderNeverStarts()
    {
        File.WriteAllText(Hold, "");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            DeviceActivityReviewHold.WaitAsync(Hold, new CancellationToken(true)));
        Assert.Empty(Directory.GetFiles(_directory, "*.started"));
    }

    public void Dispose() => Directory.Delete(_directory, recursive: true);
}
