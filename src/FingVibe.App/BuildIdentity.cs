using System.Diagnostics;
using System.Globalization;
using System.Reflection;

namespace FingVibe.App;

internal enum BuildKind
{
    Development,
    PullRequest,
    Test,
    Release
}

internal sealed class BuildIdentity
{
    public static BuildIdentity Current { get; } = FromAssembly(typeof(BuildIdentity).Assembly);

    public string Version { get; }
    public BuildKind Kind { get; }
    public int? PullRequestNumber { get; }
    public string? Commit { get; }
    public Uri? BuildUri { get; }
    public Uri? PullRequestUri => PullRequestNumber is int number
        ? new Uri($"https://github.com/iricigor/fingvibe/pull/{number}")
        : null;
    public string Label => Kind switch
    {
        BuildKind.Release => "Official release",
        BuildKind.PullRequest => $"PR #{PullRequestNumber} - Test build",
        BuildKind.Test => "TEST - Non-release build",
        _ => "DEV - Local build"
    };
    public string RibbonText => Kind switch
    {
        BuildKind.PullRequest => $"PR #{PullRequestNumber} - TEST BUILD",
        BuildKind.Test => "TEST BUILD",
        _ => "DEV BUILD"
    };
    public string WindowTitle => $"FingVibe LAN Scanner - {Version}" + (Kind switch
    {
        BuildKind.Release => "",
        BuildKind.PullRequest => $" - PR #{PullRequestNumber}",
        BuildKind.Test => " - TEST",
        _ => " - DEV"
    });
    public string Summary => $"{Version} - {Label}";
    public bool IsRibbonVisible => Kind != BuildKind.Release && !_acknowledged;
    private bool _acknowledged;

    internal BuildIdentity(string? version, string? kind, string? pullRequest, string? commit, string? buildUrl)
    {
        Version = System.Version.TryParse(version?.Split('+')[0], out var parsedVersion)
            ? $"v{parsedVersion.Major}.{parsedVersion.Minor}.{Math.Max(0, parsedVersion.Build)}"
            : "Version unavailable";
        Kind = kind switch
        {
            "Release" => BuildKind.Release,
            "PullRequest" => BuildKind.PullRequest,
            "Test" => BuildKind.Test,
            _ => BuildKind.Development
        };
        if (int.TryParse(pullRequest, NumberStyles.None, CultureInfo.InvariantCulture, out var number)
            && number > 0)
        {
            PullRequestNumber = number;
        }
        if (Kind == BuildKind.PullRequest && PullRequestNumber is null)
        {
            Trace.TraceError("PR build metadata has no valid PR number; identifying as TEST.");
            Kind = BuildKind.Test;
        }
        if (!string.IsNullOrEmpty(kind) && kind is not ("Release" or "PullRequest" or "Test" or "Development"))
        {
            Trace.TraceError("Unrecognized build kind: {0}. Identifying as DEV.", kind);
        }
        if (parsedVersion is null)
        {
            Trace.TraceError("App version metadata is missing or invalid.");
        }
        Commit = string.IsNullOrWhiteSpace(commit) ? null : commit;
        if (!string.IsNullOrWhiteSpace(buildUrl))
        {
            if (Uri.TryCreate(buildUrl, UriKind.Absolute, out var uri)
                && uri.Scheme == Uri.UriSchemeHttps && uri.Host == "github.com"
                && uri.AbsolutePath.StartsWith("/iricigor/fingvibe/actions/runs/", StringComparison.Ordinal))
            {
                BuildUri = uri;
            }
            else
            {
                Trace.TraceError("Invalid build run URL in app metadata.");
            }
        }
    }

    public void Acknowledge() => _acknowledged = true;

    private static BuildIdentity FromAssembly(Assembly assembly)
    {
        var metadata = assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .ToDictionary(attribute => attribute.Key, attribute => attribute.Value);
        string? Read(string key) => metadata.GetValueOrDefault(key);
        return new BuildIdentity(
            assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion,
            Read("BuildKind"), Read("PullRequestNumber"), Read("BuildCommit"), Read("BuildUrl"));
    }
}
