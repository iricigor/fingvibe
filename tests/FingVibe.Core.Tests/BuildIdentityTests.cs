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

    [Theory]
    [InlineData("Release", null)]
    [InlineData("PullRequest", "67")]
    [InlineData("Test", null)]
    [InlineData("Development", null)]
    public void ShowsUtcTimestampWithoutChangingIdentity(string kind, string? pr)
    {
        var build = new BuildIdentity("1.0.123", kind, pr, "abc123", null, "2026-11-01T12:20:35Z");
        Assert.Equal(TimeSpan.Zero, build.BuildTimestamp?.Offset);
        Assert.Equal(new DateTimeOffset(2026, 11, 1, 12, 20, 35, TimeSpan.Zero), build.BuildTimestamp);
        Assert.Equal("Built Nov 1, 12:20 UTC", build.RibbonTimestampText);
        Assert.Equal("Built Nov 1, 2026, 12:20:35 UTC", build.TimestampText);
        Assert.Contains(build.TimestampText, build.RibbonToolTip);
        Assert.Contains("Commit: abc123", build.RibbonToolTip);
        Assert.Contains(build.Summary, build.RibbonToolTip);
        Assert.Contains("hide ribbon until the app closes", build.RibbonToolTip);
        Assert.Contains(build.TimestampText, build.RibbonAccessibleName);
        Assert.Equal(kind != "Release", build.IsRibbonVisible);
        build.Acknowledge();
        Assert.False(build.IsRibbonVisible);
        Assert.Equal("Built Nov 1, 2026, 12:20:35 UTC", build.TimestampText);
    }

    [Fact]
    public void PreservesFractionalSecondsAndUsesInvariantEnglishFormatting()
    {
        var previousCulture = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("cs-CZ");
            var build = new BuildIdentity("1.0.0", "Test", null, null, null, "2026-11-01T12:20:35.1234567Z");
            Assert.Equal("Built Nov 1, 12:20 UTC", build.RibbonTimestampText);
            Assert.Equal("Built Nov 1, 2026, 12:20:35.1234567 UTC", build.TimestampText);
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentCulture = previousCulture;
        }
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("invalid")]
    [InlineData("2026-02-30T12:20:35Z")]
    [InlineData("2026-11-01T12:20:35")]
    [InlineData("2026-11-01T12:20:35+02:00")]
    [InlineData("Nov 1, 2026")]
    public void ShowsUnavailableRatherThanInventingBuildTime(string? timestamp)
    {
        var build = new BuildIdentity("1.0.0", "Test", null, null, null, timestamp);
        Assert.Null(build.BuildTimestamp);
        Assert.Equal("Build time unavailable", build.RibbonTimestampText);
        Assert.Equal("Build time unavailable", build.TimestampText);
        Assert.Contains("Build time unavailable", build.RibbonToolTip);
        Assert.Contains("Commit not recorded", build.RibbonToolTip);
        Assert.Contains("Build time unavailable", build.RibbonAccessibleName);
        Assert.True(build.IsRibbonVisible);
    }
}
