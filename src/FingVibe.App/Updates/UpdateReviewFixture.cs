using System.ComponentModel;
using System.Net;
using System.Text;
using System.Text.Json;
using FingVibe.Core.Updates;

namespace FingVibe.App;

internal sealed class UpdateReviewFixture(string path) : TimeProvider
{
    private sealed record Settings
    {
        public required DateTimeOffset Now { get; init; }
        public required string Outcome { get; init; }
        public required string Deployment { get; init; }
        public required string Download { get; init; }
        public string Notes { get; init; } = "default";
    }

    private Settings Read()
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        return JsonSerializer.Deserialize<Settings>(reader.ReadToEnd(),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidDataException("The update review fixture is empty.");
    }

    public override DateTimeOffset GetUtcNow() => Read().Now;
    public string DownloadRoot => Path.Combine(Path.GetDirectoryName(Path.GetFullPath(path))
        ?? throw new InvalidDataException("The update fixture needs a parent directory."), "downloads");
    public HttpMessageHandler CreateHandler() => new Handler(this);
    public UpdateDeployment Deployment => Read().Deployment switch
    {
        "installed" => new(true, "Controlled review fixture: installed deployment; launching always rejects safely."),
        "portable" => new(false, "Controlled review fixture: portable copy; ZIP/manual replacement only."),
        "uncertain" => new(false, "Controlled review fixture: uncertain deployment; ZIP/manual replacement only."),
        _ => throw new InvalidDataException("Unknown update review deployment.")
    };

    // Long enough to exercise truncation; includes HTML and links that must render as inert text.
    private static string? ReleaseBody(string notes, string version) => notes switch
    {
        "empty" => "",
        "default" => $"Controlled review notes for FingVibe {version}.\n\n## Highlights\n\n" +
            "- **Release notes in About:** see [#695](https://github.com/iricigor/fingvibe/pull/695). <script>alert('x')</script>\n" +
            string.Join("\n", Enumerable.Range(1, 40).Select(index =>
                $"- Controlled change {index}: a short description that keeps the fixture realistic and readable.")),
        _ => throw new InvalidDataException("Unknown update review notes mode.")
    };

    public static void RejectLaunch() => throw new Win32Exception(1223, "Controlled installer launch rejection; no installer was executed.");

    private sealed class Handler(UpdateReviewFixture owner) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var settings = owner.Read();
            if (request.RequestUri?.Host == "api.github.com")
            {
                while (settings.Outcome == "held")
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken);
                    settings = owner.Read();
                }
                await Task.Delay(TimeSpan.FromMilliseconds(300), cancellationToken);
                if (settings.Outcome == "offline") throw new HttpRequestException("Controlled offline response.");
                if (settings.Outcome == "rate-limit")
                {
                    var limited = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
                    limited.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromMinutes(10));
                    return limited;
                }
                if (settings.Outcome == "none") return new(HttpStatusCode.NotFound);
                if (settings.Outcome == "invalid")
                    return new(HttpStatusCode.OK) { Content = new StringContent("{}") };
                var version = settings.Outcome switch
                {
                    "current" => "1.2.99",
                    "older" => "1.2.98",
                    "newer" => "1.2.130",
                    "missing-assets" => "1.2.130",
                    _ => throw new InvalidDataException("Unknown update review outcome.")
                };
                var assets = settings.Outcome == "missing-assets" ? Array.Empty<object>() : new[] { "Setup.exe", ".zip" }
                    .Select(suffix =>
                    {
                        var name = suffix == ".zip" ? $"FingVibe-{version}-win-x64.zip" : $"FingVibe-{version}-win-x64-Setup.exe";
                        return (object)new { name, size = 17, browser_download_url = $"https://github.com/iricigor/fingvibe/releases/download/v{version}/{name}" };
                    }).ToArray();
                return new(HttpStatusCode.OK)
                {
                    Content = new StringContent(JsonSerializer.Serialize(new
                    {
                        tag_name = $"v{version}", draft = false, prerelease = false,
                        html_url = $"https://github.com/iricigor/fingvibe/releases/tag/v{version}", assets,
                        body = ReleaseBody(settings.Notes, version)
                    }))
                };
            }
            if (request.RequestUri?.Host != "github.com")
                throw new InvalidDataException("The update review fixture refuses an unexpected host.");
            if (settings.Download == "fail") throw new HttpRequestException("Controlled download failure.");
            if (settings.Download == "slow") await Task.Delay(TimeSpan.FromSeconds(10), cancellationToken);
            if (settings.Download is not ("success" or "slow" or "interrupted"))
                throw new InvalidDataException("Unknown update review download mode.");
            return new(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(Encoding.ASCII.GetBytes(settings.Download == "interrupted" ? "short" : "controlled-update"))
            };
        }
    }
}
