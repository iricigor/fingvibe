using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace FingVibe.Core.Updates;

public sealed record ReleaseAsset(string Name, Uri DownloadUri, long Size, string? Sha256);

public sealed record StableRelease(Version Version, Uri PageUri, ReleaseAsset? Setup, ReleaseAsset? Portable)
{
    public static readonly Uri ReleasesUri = new("https://github.com/iricigor/fingvibe/releases/latest");
    public string VersionText => $"v{Version.ToString(Version.Revision == 0 ? 3 : 4)}";

    public static bool TryParseVersion(string value, out Version version)
    {
        version = new Version(0, 0, 0);
        var match = Regex.Match(value, @"^[vV]?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$", RegexOptions.CultureInvariant);
        if (!match.Success || !Version.TryParse(value.TrimStart('v', 'V'), out var parsed))
            return false;
        version = new Version(parsed.Major, parsed.Minor, Math.Max(0, parsed.Build), Math.Max(0, parsed.Revision));
        return true;
    }

    public static bool IsDownloadUri(Uri uri, string name) =>
        Regex.IsMatch(name, @"^FingVibe-\d+\.\d+\.\d+(?:\.\d+)?-win-x64(?:-Setup\.exe|\.zip)$", RegexOptions.CultureInvariant)
        && uri.Scheme == Uri.UriSchemeHttps && uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
        && uri.IsDefaultPort && uri.UserInfo.Length == 0 && uri.Query.Length == 0 && uri.Fragment.Length == 0
        && uri.AbsolutePath.StartsWith("/iricigor/fingvibe/releases/download/", StringComparison.Ordinal)
        && Uri.UnescapeDataString(uri.Segments.Last()) == name
        && uri.Segments.Length == 7;

    public static StableRelease Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()
            || !TryParseVersion(tag, out var version))
            throw new InvalidDataException("The response is not a published stable numeric release.");
        if (!Uri.TryCreate(root.GetProperty("html_url").GetString(), UriKind.Absolute, out var page)
            || page != new Uri($"https://github.com/iricigor/fingvibe/releases/tag/{Uri.EscapeDataString(tag)}"))
            throw new InvalidDataException("The release page does not belong to this repository.");
        ReleaseAsset? setup = null, portable = null;
        var assetVersion = tag.TrimStart('v', 'V');
        foreach (var item in root.GetProperty("assets").EnumerateArray())
        {
            var name = item.GetProperty("name").GetString() ?? "";
            var isSetup = name == $"FingVibe-{assetVersion}-win-x64-Setup.exe";
            var isPortable = name == $"FingVibe-{assetVersion}-win-x64.zip";
            if (!isSetup && !isPortable)
                continue;
            if (!Uri.TryCreate(item.GetProperty("browser_download_url").GetString(), UriKind.Absolute, out var uri)
                || !IsDownloadUri(uri, name) || uri.Segments[^2] != $"{Uri.EscapeDataString(tag)}/")
                throw new InvalidDataException("The release asset URL is not the expected repository download.");
            var size = item.GetProperty("size").GetInt64();
            if (size <= 0 || size > 2L * 1024 * 1024 * 1024)
                throw new InvalidDataException("The release asset size is invalid.");
            string? digest = item.TryGetProperty("digest", out var digestValue) ? digestValue.GetString() : null;
            if (digest is not null && !Regex.IsMatch(digest, "^sha256:[a-fA-F0-9]{64}$", RegexOptions.CultureInvariant))
                throw new InvalidDataException("The published asset digest is unsupported.");
            var asset = new ReleaseAsset(name, uri, size, digest?[7..]);
            if (isSetup)
            {
                if (setup is not null) throw new InvalidDataException("The release has duplicate Setup assets.");
                setup = asset;
            }
            else
            {
                if (portable is not null) throw new InvalidDataException("The release has duplicate portable assets.");
                portable = asset;
            }
        }
        return new StableRelease(version, page, setup, portable);
    }
}

public sealed class ReleaseCheckException(string message, DateTimeOffset? retryAfter = null) : IOException(message)
{
    public DateTimeOffset? RetryAfter { get; } = retryAfter;
}

public sealed class GitHubReleaseSource(HttpClient http, TimeProvider clock)
{
    public async Task<StableRelease> GetLatestAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var request = new HttpRequestMessage(HttpMethod.Get,
            "https://api.github.com/repos/iricigor/fingvibe/releases/latest");
        request.Headers.UserAgent.ParseAdd("FingVibe-Updates/1.0");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var now = clock.GetUtcNow();
            DateTimeOffset? retry = response.Headers.RetryAfter?.Date;
            if (response.Headers.RetryAfter?.Delta is { } delta)
                retry = now.Add(delta);
            if (response.Headers.TryGetValues("X-RateLimit-Reset", out var resets)
                && long.TryParse(resets.FirstOrDefault(), CultureInfo.InvariantCulture, out var seconds)
                && seconds is >= 0 and <= 253402300799)
            {
                var reset = DateTimeOffset.FromUnixTimeSeconds(seconds);
                if (retry is null || reset > retry) retry = reset;
            }
            if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests)
                retry = retry is { } future && future > now ? future : now.AddMinutes(15);
            throw new ReleaseCheckException($"GitHub returned HTTP {(int)response.StatusCode}.", retry);
        }
        if (response.Content.Headers.ContentLength > 1024 * 1024)
            throw new InvalidDataException("The release response is too large.");
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var bytes = new byte[16384];
        int read;
        while ((read = await stream.ReadAsync(bytes, timeout.Token).ConfigureAwait(false)) != 0)
        {
            if (buffer.Length + read > 1024 * 1024)
                throw new InvalidDataException("The release response is too large.");
            buffer.Write(bytes, 0, read);
        }
        return StableRelease.Parse(System.Text.Encoding.UTF8.GetString(buffer.ToArray()));
    }
}
