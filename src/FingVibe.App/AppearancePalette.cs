using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed record AppearancePalette(
    bool IsDark, uint Page, uint Header, uint Border, uint Card, uint Control, uint Hover, uint Pressed)
{
    public static AppearancePalette For(ThemeVariant theme) => theme switch
    {
        ThemeVariant.WarmLight => new(false, 0xFFF8EE, 0xF3E8D8, 0xD8C8B4, 0xFFFCF5, 0xFFF4E4, 0xF3E4CF, 0xE8D7BE),
        ThemeVariant.StandardDark => new(true, 0x111318, 0x20242B, 0x3A414B, 0x1B1E24, 0x292D35, 0x343944, 0x20242B),
        ThemeVariant.OledDark => new(true, 0x000000, 0x101010, 0x343434, 0x000000, 0x151515, 0x252525, 0x080808),
        _ => new(false, 0xF6F7F9, 0xECEFF3, 0xD5DAE2, 0xFFFFFF, 0xFFFFFF, 0xF0F2F5, 0xE5E8ED)
    };
}
