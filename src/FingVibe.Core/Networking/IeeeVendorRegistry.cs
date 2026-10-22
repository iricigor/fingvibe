using System.Net.NetworkInformation;
using System.Text;

namespace FingVibe.Core.Networking;

public sealed class IeeeVendorRegistry
{
    private static readonly RegistrySource[] Sources =
    [
        new("oui.csv", new Uri("https://standards-oui.ieee.org/oui/oui.csv")),
        new("mam.csv", new Uri("https://standards-oui.ieee.org/oui28/mam.csv")),
        new("oui36.csv", new Uri("https://standards-oui.ieee.org/oui36/oui36.csv"))
    ];

    private readonly HttpClient _httpClient;
    private readonly string _cacheDirectory;
    private readonly SemaphoreSlim _loadLock = new(1, 1);
    private VendorPrefixLookup? _lookup;

    public IeeeVendorRegistry(HttpClient? httpClient = null, string? cacheDirectory = null)
    {
        _httpClient = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        _cacheDirectory = cacheDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FingVibe",
            "VendorRegistry");
    }

    public async Task<string> ResolveAsync(
        PhysicalAddress? address,
        CancellationToken cancellationToken)
    {
        if (address is null)
        {
            return "Unknown";
        }

        if (MacAddressResolver.IsPrivateOrRandomized(address))
        {
            return "Private/Randomized";
        }

        var lookup = await GetLookupAsync(cancellationToken).ConfigureAwait(false);
        return lookup.Resolve(address) ?? "Unknown";
    }

    private async Task<VendorPrefixLookup> GetLookupAsync(CancellationToken cancellationToken)
    {
        if (_lookup is not null)
        {
            return _lookup;
        }

        await _loadLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_lookup is not null)
            {
                return _lookup;
            }

            Directory.CreateDirectory(_cacheDirectory);
            var documents = await Task.WhenAll(
                Sources.Select(source => GetRegistryDocumentAsync(source, cancellationToken)))
                .ConfigureAwait(false);
            _lookup = VendorPrefixLookup.Parse(documents.OfType<string>());
            return _lookup;
        }
        finally
        {
            _loadLock.Release();
        }
    }

    private async Task<string?> GetRegistryDocumentAsync(
        RegistrySource source,
        CancellationToken cancellationToken)
    {
        var cachePath = Path.Combine(_cacheDirectory, source.FileName);
        var cacheIsFresh = File.Exists(cachePath) &&
            DateTime.UtcNow - File.GetLastWriteTimeUtc(cachePath) < TimeSpan.FromDays(30);
        if (cacheIsFresh)
        {
            return await File.ReadAllTextAsync(cachePath, cancellationToken).ConfigureAwait(false);
        }

        try
        {
            var csv = await _httpClient.GetStringAsync(source.Uri, cancellationToken).ConfigureAwait(false);
            await File.WriteAllTextAsync(cachePath, csv, cancellationToken).ConfigureAwait(false);
            return csv;
        }
        catch (HttpRequestException) when (File.Exists(cachePath))
        {
            return await File.ReadAllTextAsync(cachePath, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException)
        {
            return null;
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested && File.Exists(cachePath))
        {
            return await File.ReadAllTextAsync(cachePath, cancellationToken).ConfigureAwait(false);
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
    }

    private sealed record RegistrySource(string FileName, Uri Uri);
}

public sealed class VendorPrefixLookup
{
    private readonly IReadOnlyDictionary<string, string> _vendors;

    private VendorPrefixLookup(IReadOnlyDictionary<string, string> vendors)
    {
        _vendors = vendors;
    }

    public static VendorPrefixLookup Parse(IEnumerable<string> csvDocuments)
    {
        ArgumentNullException.ThrowIfNull(csvDocuments);
        var vendors = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (var document in csvDocuments)
        {
            using var reader = new StringReader(document);
            _ = reader.ReadLine();
            while (reader.ReadLine() is { } line)
            {
                var fields = ParseCsvLine(line);
                if (fields.Count >= 3 && fields[1].Length is 6 or 7 or 9)
                {
                    vendors[fields[1].ToUpperInvariant()] = fields[2];
                }
            }
        }

        return new VendorPrefixLookup(vendors);
    }

    public string? Resolve(PhysicalAddress address)
    {
        ArgumentNullException.ThrowIfNull(address);
        var mac = Convert.ToHexString(address.GetAddressBytes());

        foreach (var length in new[] { 9, 7, 6 })
        {
            if (mac.Length >= length && _vendors.TryGetValue(mac[..length], out var vendor))
            {
                return vendor;
            }
        }

        return null;
    }

    private static IReadOnlyList<string> ParseCsvLine(string line)
    {
        var fields = new List<string>();
        var field = new StringBuilder();
        var quoted = false;

        for (var index = 0; index < line.Length; index++)
        {
            var character = line[index];
            if (character == '"')
            {
                if (quoted && index + 1 < line.Length && line[index + 1] == '"')
                {
                    field.Append('"');
                    index++;
                }
                else
                {
                    quoted = !quoted;
                }
            }
            else if (character == ',' && !quoted)
            {
                fields.Add(field.ToString());
                field.Clear();
            }
            else
            {
                field.Append(character);
            }
        }

        fields.Add(field.ToString());
        return fields;
    }
}
