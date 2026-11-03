using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed record AppearancePalette(
    bool IsDark, uint Page, uint Header, uint Border, uint Card, uint Control, uint Hover, uint Pressed, uint AlternateRow)
{
    public static AppearancePalette For(ThemeVariant theme) => theme switch
    {
        ThemeVariant.WarmLight => new(false, 0xFFF8EE, 0xF3E8D8, 0xD8C8B4, 0xFFFCF5, 0xFFF4E4, 0xF3E4CF, 0xE8D7BE, 0xF6E9D6),
        ThemeVariant.StandardDark => new(true, 0x111318, 0x20242B, 0x3A414B, 0x1B1E24, 0x292D35, 0x343944, 0x20242B, 0x2B313A),
        ThemeVariant.OledDark => new(true, 0x000000, 0x101010, 0x343434, 0x000000, 0x151515, 0x252525, 0x080808, 0x191919),
        ThemeVariant.ColorfulLight => new(false, 0xEEF0FF, 0xE1E5FA, 0xACB5DD, 0xF7F8FF, 0xE9EDFF, 0xDDE3FA, 0xCCD5F3, 0xE8ECFA),
        ThemeVariant.ColorfulDark => new(true, 0x13152B, 0x242846, 0x545E90, 0x1D213D, 0x2D3458, 0x3B456E, 0x222A4B, 0x2B3150),
        ThemeVariant.VividLight => new(false, 0xE2E9FF, 0xCCD9FF, 0x6B7CC0, 0xECF1FF, 0xE1E9FF, 0xC5D5FF, 0xB4C8FA, 0xD6E2FF),
        ThemeVariant.VividDark => new(true, 0x101D3F, 0x193665, 0x708CCF, 0x142C52, 0x1C3864, 0x244775, 0x14264B, 0x213B63),
        _ => new(false, 0xF6F7F9, 0xECEFF3, 0xD5DAE2, 0xFFFFFF, 0xFFFFFF, 0xF0F2F5, 0xE5E8ED, 0xEDF1F6)
    };
}

internal sealed record SurfacePalette(
    uint Top, uint Bottom, uint BorderTop, uint BorderBottom, double Radius, float Elevation,
    double StrokeWidth = 1, byte FillAlpha = 255, byte BorderAlpha = 255)
{
    public static SurfacePalette For(AppearancePalette palette, VisualStyle style, bool card)
    {
        var color = card ? palette.Card : palette.Control;
        var edge = palette.Border;
        return style switch
        {
            VisualStyle.Standard => new(color, color, edge, edge, card ? 8 : 4, 0),
            VisualStyle.Glass => new(color, color, 0xFFFFFF, 0xFFFFFF,
                card ? 20 : 10, card ? 4 : 0, FillAlpha: 160,
                BorderAlpha: palette.IsDark ? (byte)77 : (byte)51),
            VisualStyle.Clay => new(Mix(color, 255, palette.IsDark ? 0.06 : 0.12), Mix(color, 0, 0.15),
                Mix(color, 255, palette.IsDark ? 0.3 : 0.85), Mix(color, 0, 0.3),
                card ? 28 : 16, card ? 32 : 8, StrokeWidth: 3),
            VisualStyle.Neumorphic when card => new(
                Mix(palette.Page, 255, palette.IsDark ? 0.06 : 0.09), Mix(palette.Page, 0, 0.09),
                Mix(palette.Page, 255, palette.IsDark ? 0.3 : 0.85), Mix(palette.Page, 0, 0.4),
                18, 12, StrokeWidth: 3),
            VisualStyle.Neumorphic => new(Mix(palette.Page, 0, 0.12),
                Mix(palette.Page, 255, palette.IsDark ? 0.06 : 0.04),
                Mix(palette.Page, 0, 0.4), Mix(palette.Page, 255, palette.IsDark ? 0.3 : 0.85),
                10, 0, StrokeWidth: 3),
            _ => throw new ArgumentOutOfRangeException(nameof(style))
        };
    }

    private static uint Mix(uint color, byte target, double amount)
    {
        uint Channel(int shift)
        {
            var value = (color >> shift) & 255;
            return (uint)Math.Round(value + (target - (double)value) * amount) << shift;
        }
        return Channel(16) | Channel(8) | Channel(0);
    }
}
