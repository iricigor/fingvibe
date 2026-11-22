using System.Text;
using System.Text.RegularExpressions;

namespace FingVibe.Core.Updates;

public enum ReleaseNoteKind { Heading, Bullet, Paragraph }

public sealed record ReleaseNoteBlock(ReleaseNoteKind Kind, string Text);

/// <summary>
/// Reduces an untrusted GitHub release body to plain-text headings, bullets and paragraphs.
/// Markup, links, HTML and images never survive as anything but inert text.
/// </summary>
public sealed record ReleaseNotes(IReadOnlyList<ReleaseNoteBlock> Blocks, bool IsTruncated)
{
    public const int MaximumCharacters = 1500;
    private const int MaximumSourceCharacters = 64 * 1024;

    private static readonly Regex Heading = new(@"^#{1,6}\s+(.*?)\s*#*\s*$", RegexOptions.CultureInvariant);
    private static readonly Regex Bullet = new(@"^(?:[-*+]|\d{1,3}[.)])\s+(.*)$", RegexOptions.CultureInvariant);
    private static readonly Regex Rule = new(@"^(?:[-*_]\s*){3,}$", RegexOptions.CultureInvariant);
    private static readonly Regex Fence = new(@"^(?:```|~~~)", RegexOptions.CultureInvariant);
    private static readonly Regex Comment = new(@"<!--.*?(?:-->|$)", RegexOptions.CultureInvariant | RegexOptions.Singleline);
    private static readonly Regex DangerousElement = new(@"<(script|style|iframe|object|embed|template)\b[^>]*>.*?(?:</\1\s*>|$)",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase | RegexOptions.Singleline);
    private static readonly Regex Image = new(@"!\[([^\]]*)\]\([^)]*\)", RegexOptions.CultureInvariant);
    private static readonly Regex Link = new(@"\[([^\]]+)\]\([^)]*\)", RegexOptions.CultureInvariant);
    private static readonly Regex AutoLink = new(@"<((?:https?|mailto):[^>\s]+)>", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
    private static readonly Regex Tag = new(@"</?[A-Za-z][^<>]*>", RegexOptions.CultureInvariant);
    private static readonly Regex Emphasis = new(@"(\*\*|__|`)", RegexOptions.CultureInvariant);
    private static readonly Regex Space = new(@"\s+", RegexOptions.CultureInvariant);

    public static ReleaseNotes? Parse(string? body)
    {
        if (string.IsNullOrWhiteSpace(body)) return null;
        var source = body.Length > MaximumSourceCharacters ? body[..MaximumSourceCharacters] : body;
        source = DangerousElement.Replace(Comment.Replace(source, " "), " ");
        var blocks = new List<ReleaseNoteBlock>();
        var paragraph = new StringBuilder();
        var used = 0;
        var truncated = false;

        bool Add(ReleaseNoteKind kind, string raw)
        {
            var text = Inline(raw);
            if (text.Length == 0) return true;
            var remaining = MaximumCharacters - used;
            if (remaining <= 0) return false;
            if (text.Length > remaining)
            {
                var cut = text.LastIndexOf(' ', Math.Max(0, remaining - 1));
                text = (cut > remaining / 2 ? text[..cut] : text[..remaining]).TrimEnd() + "…";
                blocks.Add(new(kind, text));
                used = MaximumCharacters;
                return false;
            }
            blocks.Add(new(kind, text));
            used += text.Length;
            return true;
        }

        bool Flush()
        {
            if (paragraph.Length == 0) return true;
            var ok = Add(ReleaseNoteKind.Paragraph, paragraph.ToString());
            paragraph.Clear();
            return ok;
        }

        foreach (var rawLine in source.ReplaceLineEndings("\n").Split('\n'))
        {
            var line = rawLine.Trim();
            bool ok;
            if (line.Length == 0 || Rule.IsMatch(line) || Fence.IsMatch(line))
                ok = Flush();
            else if (Heading.Match(line) is { Success: true } heading)
                ok = Flush() && Add(ReleaseNoteKind.Heading, heading.Groups[1].Value);
            else if (Bullet.Match(line) is { Success: true } bullet)
                ok = Flush() && Add(ReleaseNoteKind.Bullet, bullet.Groups[1].Value);
            else
            {
                paragraph.Append(paragraph.Length == 0 ? "" : " ").Append(line.TrimStart('>').Trim());
                ok = true;
            }
            if (!ok)
            {
                truncated = true;
                break;
            }
        }
        if (!truncated && !Flush()) truncated = true;
        truncated |= body.Length > MaximumSourceCharacters;
        return blocks.Count == 0 ? null : new ReleaseNotes(blocks, truncated);
    }

    private static string Inline(string value)
    {
        var text = Image.Replace(value, "$1");
        text = Link.Replace(text, "$1");
        text = AutoLink.Replace(text, "$1");
        text = Tag.Replace(text, " ");
        text = Emphasis.Replace(text, "");
        text = System.Net.WebUtility.HtmlDecode(text);
        text = new string(text.Where(character => !char.IsControl(character) || character == ' ').ToArray());
        return Space.Replace(text, " ").Trim();
    }
}
