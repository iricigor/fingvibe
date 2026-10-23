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
}
