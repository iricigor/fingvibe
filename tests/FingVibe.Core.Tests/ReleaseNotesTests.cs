using System.Text.Json;
using FingVibe.Core.Updates;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ReleaseNotesTests
{
    [Fact]
    public void HeadingsBulletsAndParagraphsBecomePlainTextBlocks()
    {
        var notes = ReleaseNotes.Parse(
            "FingVibe 1.5 adds **release notes**\r\nin About.\r\n\r\n## Major changes\r\n\r\n" +
            "- **Room map:** see [#559](https://github.com/iricigor/fingvibe/pull/559) and <https://example.test/x>.\r\n" +
            "* Second ![diagram](https://example.test/d.png) item\r\n1. Ordered `code` item\r\n---\r\n### Notes ###\r\nTail");

        Assert.NotNull(notes);
        Assert.False(notes.IsTruncated);
        Assert.Equal(new ReleaseNoteBlock[]
        {
            new(ReleaseNoteKind.Paragraph, "FingVibe 1.5 adds release notes in About."),
            new(ReleaseNoteKind.Heading, "Major changes"),
            new(ReleaseNoteKind.Bullet, "Room map: see #559 and https://example.test/x."),
            new(ReleaseNoteKind.Bullet, "Second diagram item"),
            new(ReleaseNoteKind.Bullet, "Ordered code item"),
            new(ReleaseNoteKind.Heading, "Notes"),
            new(ReleaseNoteKind.Paragraph, "Tail")
        }, notes.Blocks);
    }

    [Fact]
    public void HtmlScriptsAndCommentsNeverSurviveAsMarkup()
    {
        var notes = ReleaseNotes.Parse(
            "<!-- hidden -->Safe <b>bold</b> <img src=\"https://example.test/a.png\" onerror=\"x()\">\n" +
            "<script>alert('x')</script>\n<iframe src=\"https://example.test\"></iframe>\n- &lt;script&gt; stays text");

        Assert.NotNull(notes);
        var text = string.Join("\n", notes.Blocks.Select(block => block.Text));
        Assert.Equal("Safe bold\n<script> stays text", text);
        Assert.DoesNotContain("alert", text);
        Assert.DoesNotContain("hidden", text);
        Assert.DoesNotContain("example.test", text);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("  \r\n\t")]
    [InlineData("<!-- only a comment -->\n---\n<script>x()</script>")]
    public void EmptyOrMarkupOnlyBodiesHaveNoNotes(string? body) => Assert.Null(ReleaseNotes.Parse(body));

    [Fact]
    public void LongNotesAreTruncatedAtTheCharacterLimit()
    {
        var body = string.Join("\n", Enumerable.Range(1, 80).Select(index => $"- Change number {index} with a short description of the work."));
        var notes = ReleaseNotes.Parse(body);

        Assert.NotNull(notes);
        Assert.True(notes.IsTruncated);
        Assert.True(notes.Blocks.Sum(block => block.Text.Length) <= ReleaseNotes.MaximumCharacters + 1);
        Assert.Equal("- Change number 1 with a short description of the work.", "- " + notes.Blocks[0].Text);

        var single = ReleaseNotes.Parse(new string('a', 40) + " " + new string('b', ReleaseNotes.MaximumCharacters));
        Assert.NotNull(single);
        Assert.True(single.IsTruncated);
        Assert.EndsWith("…", single.Blocks.Single().Text);
        Assert.Equal(ReleaseNotes.MaximumCharacters + 1, single.Blocks.Single().Text.Length);
    }

    [Fact]
    public void NotesThatFitExactlyAreNotTruncated()
    {
        var text = new string('x', ReleaseNotes.MaximumCharacters);
        var notes = ReleaseNotes.Parse(text);

        Assert.NotNull(notes);
        Assert.False(notes.IsTruncated);
        Assert.Equal(text, notes.Blocks.Single().Text);
    }

    [Fact]
    public void StableReleaseKeepsTheBodyFromTheSameResponse()
    {
        static string Json(object? body) => JsonSerializer.Serialize(new
        {
            tag_name = "v1.2.130", draft = false, prerelease = false,
            html_url = "https://github.com/iricigor/fingvibe/releases/tag/v1.2.130",
            body,
            assets = Array.Empty<object>()
        });

        var release = StableRelease.Parse(Json("## What's new\n- Faster scans"));
        Assert.Equal("## What's new\n- Faster scans", release.Body);
        Assert.Equal(new ReleaseNoteBlock(ReleaseNoteKind.Bullet, "Faster scans"), release.Notes!.Blocks[^1]);
        Assert.Null(StableRelease.Parse(Json(null)).Notes);
        Assert.Null(StableRelease.Parse(Json(42)).Body);
    }
}
