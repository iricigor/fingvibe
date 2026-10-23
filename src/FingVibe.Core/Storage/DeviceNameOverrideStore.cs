using System.Net.NetworkInformation;
using System.Text.Json;

namespace FingVibe.Core.Storage;

public sealed class DeviceNameOverrideStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private readonly string _filePath;

    public DeviceNameOverrideStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public async Task<IReadOnlyDictionary<string, string>> LoadAsync(
        CancellationToken cancellationToken = default)
    {
        Dictionary<string, string?>? document;
        try
        {
            await using var stream = new FileStream(
                _filePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            document = await JsonSerializer.DeserializeAsync<Dictionary<string, string?>>(
                stream,
                JsonOptions,
                cancellationToken).ConfigureAwait(false);
        }
        catch (FileNotFoundException)
        {
            return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }
        catch (DirectoryNotFoundException)
        {
            return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException exception)
        {
            throw new InvalidDataException("The saved device names are invalid.", exception);
        }

        if (document is null)
        {
            throw new InvalidDataException("The saved device names are invalid.");
        }

        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (macAddress, name) in document)
        {
            string key;
            try
            {
                key = NormalizeMacAddress(macAddress);
            }
            catch (FormatException exception)
            {
                throw new InvalidDataException("The saved device names contain an invalid MAC address.", exception);
            }

            if (string.IsNullOrWhiteSpace(name) || name.Length > 64)
            {
                throw new InvalidDataException("The saved device names contain an invalid name.");
            }

            names[key] = name.Trim();
        }

        return names;
    }

    public async Task SaveAsync(
        IReadOnlyDictionary<string, string> names,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(names);
        var normalizedNames = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (macAddress, name) in names)
        {
            var key = NormalizeMacAddress(macAddress);
            if (string.IsNullOrWhiteSpace(name) || name.Trim().Length > 64)
            {
                throw new ArgumentException("Device names must contain 1 to 64 characters.", nameof(names));
            }

            normalizedNames[key] = name.Trim();
        }

        var directory = Path.GetDirectoryName(_filePath)
            ?? throw new ArgumentException("The device name path must include a directory.", nameof(_filePath));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_filePath)}.{Guid.NewGuid():N}.tmp");

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
                await JsonSerializer.SerializeAsync(stream, normalizedNames, JsonOptions, cancellationToken)
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

    internal static string NormalizeMacAddress(string macAddress)
    {
        if (string.IsNullOrWhiteSpace(macAddress))
        {
            throw new FormatException("A MAC address is required.");
        }

        var address = PhysicalAddress.Parse(macAddress);
        if (address.GetAddressBytes().Length != 6)
        {
            throw new FormatException("A six-byte MAC address is required.");
        }

        return address.ToString();
    }
}
