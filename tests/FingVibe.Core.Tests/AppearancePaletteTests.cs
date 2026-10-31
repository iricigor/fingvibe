using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class AppearancePaletteTests
{
    [Theory]
    [InlineData(ThemeVariant.StandardLight, false)]
    [InlineData(ThemeVariant.WarmLight, false)]
    [InlineData(ThemeVariant.StandardDark, true)]
    [InlineData(ThemeVariant.OledDark, true)]
    public void For_SelectsExpectedRootTheme(ThemeVariant theme, bool isDark)
    {
        Assert.Equal(isDark, AppearancePalette.For(theme).IsDark);
    }

    [Fact]
    public void For_AllVariantsHaveDistinctPageAndControlColors()
    {
        var palettes = Enum.GetValues<ThemeVariant>().Select(AppearancePalette.For).ToArray();

        Assert.Equal(4, palettes.Select(palette => palette.Page).Distinct().Count());
        Assert.Equal(4, palettes.Select(palette => palette.Header).Distinct().Count());
        Assert.Equal(4, palettes.Select(palette => palette.Hover).Distinct().Count());
    }

    [Fact]
    public void For_Oled_UsesTrueBlackPageAndCards()
    {
        var palette = AppearancePalette.For(ThemeVariant.OledDark);

        Assert.Equal(0u, palette.Page);
        Assert.Equal(0u, palette.Card);
    }

    [Theory]
    [InlineData(ThemeVariant.StandardLight)]
    [InlineData(ThemeVariant.WarmLight)]
    [InlineData(ThemeVariant.StandardDark)]
    [InlineData(ThemeVariant.OledDark)]
    public void AlternateRow_IsSubtleAndDistinctFromCardAndHover(ThemeVariant theme)
    {
        var palette = AppearancePalette.For(theme);

        Assert.NotEqual(palette.Card, palette.AlternateRow);
        Assert.NotEqual(palette.Hover, palette.AlternateRow);
        foreach (var shift in new[] { 0, 8, 16 })
        {
            var difference = Math.Abs((int)((palette.Card >> shift) & 255)
                - (int)((palette.AlternateRow >> shift) & 255));
            Assert.InRange(difference, 0, 32);
        }
    }

    [Theory]
    [InlineData(ThemeVariant.StandardLight, 0xF5F7FAu)]
    [InlineData(ThemeVariant.WarmLight, 0xFFF5E7u)]
    [InlineData(ThemeVariant.StandardDark, 0x22262Du)]
    [InlineData(ThemeVariant.OledDark, 0x101010u)]
    public void AlternateRow_IsMoreDistinctThanInitialPreview(ThemeVariant theme, uint initialPreview)
    {
        var palette = AppearancePalette.For(theme);
        var channels = new[] { 0, 8, 16 };
        int Distance(uint color) => channels.Sum(shift =>
            Math.Abs((int)((palette.Card >> shift) & 255) - (int)((color >> shift) & 255)));

        Assert.True(Distance(palette.AlternateRow) > Distance(initialPreview));
    }
}
