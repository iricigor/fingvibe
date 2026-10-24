using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class BuildIdentityTests
{
    [Theory]
    [InlineData("Release", null, "Release", false, "Official release")]
    [InlineData("PullRequest", "67", "PullRequest", true, "PR #67 - Test build")]
    [InlineData("Test", null, "Test", true, "TEST - Non-release build")]
    [InlineData("Development", null, "Development", true, "DEV - Local build")]
    [InlineData(null, null, "Development", true, "DEV - Local build")]
    [InlineData("unexpected", null, "Development", true, "DEV - Local build")]
    [InlineData("PullRequest", "0", "Test", true, "TEST - Non-release build")]
    [InlineData("PullRequest", "invalid", "Test", true, "TEST - Non-release build")]
    [InlineData("PullRequest", null, "Test", true, "TEST - Non-release build")]
    public void ClassifiesBuilds(string? kind, string? pr, string expected, bool ribbon, string label)
    {
        var build = new BuildIdentity("1.0.123+abc", kind, pr, null, null);
        Assert.Equal(expected, build.Kind.ToString());
        Assert.Equal(ribbon, build.IsRibbonVisible);
        Assert.Equal(label, build.Label);
        Assert.Equal("v1.0.123", build.Version);
        Assert.Contains(build.Version, build.WindowTitle);
        Assert.Contains(build.Version, build.Summary);
    }

    [Theory]
    [InlineData(null, "Version unavailable")]
    [InlineData("invalid", "Version unavailable")]
    [InlineData("1.2", "v1.2.0")]
    [InlineData("0.0.456", "v0.0.456")]
    public void HandlesVersionMetadata(string? version, string expected)
    {
        Assert.Equal(expected, new BuildIdentity(version, null, null, null, null).Version);
    }

    [Fact]
    public void AcknowledgmentHidesOnlyRibbonAndDoesNotSurviveNewSession()
    {
        var build = new BuildIdentity("0.0.456", "PullRequest", "67", "abc123", null);
        var title = build.WindowTitle;
        var summary = build.Summary;
        build.Acknowledge();
        build.Acknowledge();
        Assert.False(build.IsRibbonVisible);
        Assert.Equal(title, build.WindowTitle);
        Assert.Equal(summary, build.Summary);
        Assert.Contains("PR #67", title);
        Assert.Contains("PR #67", build.RibbonText);
        Assert.True(new BuildIdentity("0.0.456", "PullRequest", "67", null, null).IsRibbonVisible);
    }

    [Fact]
    public void ExposesTraceableBuildLinks()
    {
        const string run = "https://github.com/iricigor/fingvibe/actions/runs/123";
        var build = new BuildIdentity("0.0.456", "PullRequest", "67", "abc123", run);
        Assert.Equal(run, build.BuildUri?.AbsoluteUri);
        Assert.Equal("https://github.com/iricigor/fingvibe/pull/67", build.PullRequestUri?.AbsoluteUri);
        Assert.Equal("abc123", build.Commit);
    }

    [Theory]
    [InlineData("http://github.com/iricigor/fingvibe/actions/runs/123")]
    [InlineData("https://example.com/iricigor/fingvibe/actions/runs/123")]
    [InlineData("not a URL")]
    public void RejectsInvalidRunLinks(string url)
    {
        Assert.Null(new BuildIdentity("1.0.0", "Test", null, null, url).BuildUri);
    }
}
