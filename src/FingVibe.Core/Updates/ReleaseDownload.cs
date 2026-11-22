using System.Security.Cryptography;

namespace FingVibe.Core.Updates;

public static class ReleaseDownload
{
    public static async Task<string> VerifyAsync(string path, ReleaseAsset asset, CancellationToken cancellationToken)
    {
        ValidateAsset(asset);
        if (Path.GetFileName(path) != asset.Name)
            throw new InvalidDataException("The downloaded file name differs from the published release asset.");
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
        var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false));
        if (stream.Length != asset.Size)
            throw new InvalidDataException("The downloaded file size differs from the published release.");
        if (asset.Sha256 is not null && !hash.Equals(asset.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The downloaded file does not match the published SHA-256 digest.");
        if (OperatingSystem.IsWindows() &&
            !(await File.ReadAllTextAsync(path + ":Zone.Identifier", cancellationToken).ConfigureAwait(false))
                .Split('\n').Any(line => line.Trim() == "ZoneId=3"))
            throw new InvalidDataException("The downloaded file is missing its Internet security marking.");
        return hash;
    }

    public static async Task<string> DownloadAsync(HttpClient http, ReleaseAsset asset, string directory,
        IProgress<double>? progress, CancellationToken cancellationToken)
    {
        ValidateAsset(asset);
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, asset.Name);
        var created = false;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        try
        {
            using var response = await http.GetAsync(asset.DownloadUri, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength is { } length && length != asset.Size)
                throw new InvalidDataException("The download size differs from the published release.");
            await using (var input = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false))
            await using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                created = true;
                var buffer = new byte[65536];
                long total = 0;
                int read;
                while ((read = await input.ReadAsync(buffer, timeout.Token).ConfigureAwait(false)) > 0)
                {
                    total += read;
                    if (total > asset.Size) throw new InvalidDataException("The download exceeds its published size.");
                    hash.AppendData(buffer, 0, read);
                    await output.WriteAsync(buffer.AsMemory(0, read), timeout.Token).ConfigureAwait(false);
                    progress?.Report(100d * total / asset.Size);
                }
                if (total != asset.Size) throw new InvalidDataException("The download is incomplete.");
                var digest = Convert.ToHexString(hash.GetHashAndReset());
                if (asset.Sha256 is { } expected && !digest.Equals(expected, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The download does not match the published SHA-256 digest.");
            }
            if (OperatingSystem.IsWindows())
                await File.WriteAllTextAsync(path + ":Zone.Identifier",
                    $"[ZoneTransfer]\r\nZoneId=3\r\nHostUrl={asset.DownloadUri.AbsoluteUri}\r\n", timeout.Token).ConfigureAwait(false);
            return path;
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or HttpRequestException or UnauthorizedAccessException
            or System.Security.SecurityException or OperationCanceledException)
        {
            if (created && File.Exists(path)) File.Delete(path);
            if (exception is OperationCanceledException && !cancellationToken.IsCancellationRequested)
                throw new IOException("The update download timed out. Try again or download manually.", exception);
            throw;
        }
    }

    private static void ValidateAsset(ReleaseAsset asset)
    {
        if (!StableRelease.IsDownloadUri(asset.DownloadUri, asset.Name)
            || Path.GetFileName(asset.Name) != asset.Name || asset.Size <= 0 || asset.Size > 2L * 1024 * 1024 * 1024)
            throw new InvalidDataException("The selected release asset is invalid.");
    }
}
