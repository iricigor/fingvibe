using System.Diagnostics;

namespace FingVibe.App;

internal static class DeviceActivityReviewHold
{
    // Hold the loader, not SQLite: UI automation must not outlive the production busy timeout.
    internal static async Task WaitAsync(string path, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(path)) return;
        var request = $"{path}.{Guid.NewGuid():N}";
        File.WriteAllText(request + ".started", "");
        using var registration = cancellationToken.Register(() => File.WriteAllText(request + ".cancelled", ""));
        var clock = Stopwatch.StartNew();
        while (File.Exists(path))
        {
            if (clock.Elapsed >= TimeSpan.FromSeconds(30))
                throw new InvalidOperationException("The UI-review Activity hold was not released within 30 seconds.");
            await Task.Delay(25, cancellationToken);
        }
        cancellationToken.ThrowIfCancellationRequested();
        File.WriteAllText(request + ".released", "");
    }
}
