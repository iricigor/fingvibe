using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class ScanSnapshotStore
{
    private const int CurrentVersion = 1;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private readonly string _filePath;

    public ScanSnapshotStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public async Task<ScanSnapshot?> LoadAsync(CancellationToken cancellationToken = default)
    {
        CacheDocument? document;
        try
        {
            await using var stream = new FileStream(
                _filePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            document = await JsonSerializer.DeserializeAsync<CacheDocument>(
                stream,
                JsonOptions,
                cancellationToken).ConfigureAwait(false);
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException("The saved scan cache is invalid.", exception);
        }

        if (document is null
            || document.Version != CurrentVersion
            || document.Results is null
            || !TryGetPrefixLength(document.Subnet, out _))
        {
            throw new InvalidDataException("The saved scan cache is invalid.");
        }

        try
        {
            var results = document.Results.Select(result =>
            {
                if (!IPAddress.TryParse(result.Address, out var address)
                    || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork
                    || !Enum.IsDefined(result.Status)
                    || result.OpenPorts is null)
                {
                    throw new InvalidDataException("The saved scan cache contains invalid device details.");
                }

                return new ScanResult(
                    address,
                    result.Status,
                    result.RoundtripTimeMilliseconds,
                    result.ProbeDuration,
                    result.DeviceName,
                    result.MacAddress is null ? null : PhysicalAddress.Parse(result.MacAddress),
                    result.VendorName ?? "Unknown",
                    result.OpenPorts.Select(port => new OpenPort(port.Port, port.ServiceName ?? string.Empty)).ToArray());
            }).ToArray();

            return new ScanSnapshot(document.Subnet, document.CompletedAt, results);
        }
        catch (FormatException exception)
        {
            throw new InvalidDataException("The saved scan cache contains invalid device details.", exception);
        }
    }

    public async Task SaveAsync(ScanSnapshot snapshot, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (!TryGetPrefixLength(snapshot.Subnet, out _))
        {
            throw new ArgumentException("The scan subnet must be an IPv4 CIDR.", nameof(snapshot));
        }

        var directory = Path.GetDirectoryName(_filePath)
            ?? throw new ArgumentException("The scan cache path must include a directory.", nameof(_filePath));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_filePath)}.{Guid.NewGuid():N}.tmp");
        var document = new CacheDocument(
            CurrentVersion,
            snapshot.Subnet,
            snapshot.CompletedAt,
            snapshot.Results.Select(result => new CachedScanResult(
                result.Address.ToString(),
                result.Status,
                result.RoundtripTimeMilliseconds,
                result.ProbeDuration,
                result.DeviceName,
                result.MacAddress?.ToString(),
                result.VendorName,
                result.OpenPortItems.Select(port => new CachedOpenPort(port.Port, port.ServiceName)).ToArray()))
                .ToArray());

        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await JsonSerializer.SerializeAsync(stream, document, JsonOptions, cancellationToken)
                    .ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            File.Move(temporaryPath, _filePath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static bool TryGetPrefixLength(string? subnet, out int prefixLength)
    {
        prefixLength = 0;
        if (subnet is null)
        {
            return false;
        }

        var separator = subnet.LastIndexOf('/');
        return separator > 0
            && IPAddress.TryParse(subnet[..separator], out var address)
            && address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
            && int.TryParse(subnet[(separator + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out prefixLength)
            && prefixLength is >= 0 and <= 32;
    }

    private sealed record CacheDocument(
        int Version,
        string Subnet,
        DateTimeOffset CompletedAt,
        CachedScanResult[]? Results);

    private sealed record CachedScanResult(
        string? Address,
        HostStatus Status,
        long? RoundtripTimeMilliseconds,
        TimeSpan ProbeDuration,
        string? DeviceName,
        string? MacAddress,
        string? VendorName,
        CachedOpenPort[]? OpenPorts);

    private sealed record CachedOpenPort(int Port, string? ServiceName);
}
