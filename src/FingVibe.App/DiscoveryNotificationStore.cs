using System.Text.Json;

namespace FingVibe.App;

// Short-lived activation payloads, not an inventory or notification archive. Toasts expire at the same time.
internal sealed class DiscoveryNotificationStore(string directory, TimeProvider? timeProvider = null)
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;

    internal async Task SaveAsync(DiscoveryNotificationBatch batch)
    {
        Directory.CreateDirectory(directory);
        foreach (var path in Directory.EnumerateFiles(directory, "*.json"))
        {
            if (File.GetLastWriteTimeUtc(path) < _time.GetUtcNow().AddDays(-1).UtcDateTime)
                File.Delete(path);
        }
        var pathToWrite = Path.Combine(directory, $"{batch.Id:D}.json");
        await using var stream = new FileStream(pathToWrite, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            4096, useAsync: true);
        await JsonSerializer.SerializeAsync(stream, batch);
    }

    internal async Task<DiscoveryNotificationBatch> LoadAsync(Guid id)
    {
        var path = Path.Combine(directory, $"{id:D}.json");
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            4096, useAsync: true);
        var batch = await JsonSerializer.DeserializeAsync<DiscoveryNotificationBatch>(stream);
        if (batch is null || batch.Id != id || batch.ExpiresAt <= _time.GetUtcNow()
            || batch.Devices is not { Length: > 0 }
            || batch.Devices.Any(device => device is null || device.Mac is not { Length: 12 }
                || !device.Mac.All(Uri.IsHexDigit) || string.IsNullOrWhiteSpace(device.IdentityKey)
                || string.IsNullOrWhiteSpace(device.Name) || device.Address is null || device.IconGlyph is null))
            throw new InvalidDataException("This discovery notification has expired or its saved list is invalid.");
        return batch;
    }
}
