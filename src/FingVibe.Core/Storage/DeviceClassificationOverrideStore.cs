using System.Text.Json;
using System.Text.Json.Serialization;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class DeviceClassificationOverrideStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };
    private readonly string _filePath;

    public DeviceClassificationOverrideStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public async Task<IReadOnlyDictionary<string, DeviceClassificationOverride>> LoadAsync(
        CancellationToken cancellationToken = default)
    {
        try
        {
            await using var stream = new FileStream(_filePath, FileMode.Open, FileAccess.Read,
                FileShare.Read, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan);
            var document = await JsonSerializer.DeserializeAsync<Dictionary<string, DeviceClassificationOverride>>(
                stream, JsonOptions, cancellationToken).ConfigureAwait(false);
            return Normalize(document ?? throw new InvalidDataException("The saved device classifications are invalid."));
        }
        catch (FileNotFoundException)
        {
            return new Dictionary<string, DeviceClassificationOverride>(StringComparer.OrdinalIgnoreCase);
        }
        catch (DirectoryNotFoundException)
        {
            return new Dictionary<string, DeviceClassificationOverride>(StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is JsonException or ArgumentException or FormatException)
        {
            throw new InvalidDataException("The saved device classifications are invalid.", exception);
        }
    }

    public async Task SaveAsync(IReadOnlyDictionary<string, DeviceClassificationOverride> overrides,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(overrides);
        var normalized = Normalize(overrides);
        var directory = Path.GetDirectoryName(_filePath)
            ?? throw new ArgumentException("The classification path must include a directory.", nameof(_filePath));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_filePath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await JsonSerializer.SerializeAsync(stream, normalized, JsonOptions, cancellationToken)
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

    private static SortedDictionary<string, DeviceClassificationOverride> Normalize(
        IReadOnlyDictionary<string, DeviceClassificationOverride> overrides)
    {
        var result = new SortedDictionary<string, DeviceClassificationOverride>(StringComparer.OrdinalIgnoreCase);
        foreach (var (mac, value) in overrides)
        {
            var key = DeviceNameOverrideStore.NormalizeMacAddress(mac);
            if (value is null || value.IsEmpty
                || (value.OperatingSystem is { } os && !Enum.IsDefined(os))
                || (value.Type is { } type && !Enum.IsDefined(type))
                || (value.Icon is { } icon && !Enum.IsDefined(icon)))
            {
                throw new ArgumentException("Device classification overrides must contain valid OS, type, or icon choices.",
                    nameof(overrides));
            }

            result.Add(key, value);
        }

        return result;
    }
}
