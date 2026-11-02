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
    [InlineData(ThemeVariant.ColorfulLight, false)]
    [InlineData(ThemeVariant.ColorfulDark, true)]
    [InlineData(ThemeVariant.VividLight, false)]
    [InlineData(ThemeVariant.VividDark, true)]
    public void For_SelectsExpectedRootTheme(ThemeVariant theme, bool isDark)
    {
        Assert.Equal(isDark, AppearancePalette.For(theme).IsDark);
    }

    [Fact]
    public void For_AllVariantsHaveDistinctPageAndControlColors()
    {
        var palettes = Enum.GetValues<ThemeVariant>().Select(AppearancePalette.For).ToArray();

        Assert.Equal(palettes.Length, palettes.Select(palette => palette.Page).Distinct().Count());
        Assert.Equal(palettes.Length, palettes.Select(palette => palette.Header).Distinct().Count());
        Assert.Equal(palettes.Length, palettes.Select(palette => palette.Hover).Distinct().Count());
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
    [InlineData(ThemeVariant.ColorfulLight)]
    [InlineData(ThemeVariant.ColorfulDark)]
    [InlineData(ThemeVariant.VividLight)]
    [InlineData(ThemeVariant.VividDark)]
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
    [InlineData(ThemeVariant.ColorfulLight)]
    [InlineData(ThemeVariant.ColorfulDark)]
    [InlineData(ThemeVariant.VividLight)]
    [InlineData(ThemeVariant.VividDark)]
    public void ColorfulSurfaces_HaveReadableTextContrast(ThemeVariant theme)
    {
        var palette = AppearancePalette.For(theme);
        foreach (var color in new[] { palette.Page, palette.Header, palette.Card, palette.Control,
                     palette.Hover, palette.Pressed, palette.AlternateRow })
        {
            static double Linear(uint channel)
            {
                var value = channel / 255.0;
                return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
            }
            var luminance = 0.2126 * Linear((color >> 16) & 255)
                + 0.7152 * Linear((color >> 8) & 255) + 0.0722 * Linear(color & 255);
            var contrast = palette.IsDark ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05;
            Assert.True(contrast >= 7, $"Surface {color:X6} has primary text contrast {contrast:F2}:1.");
        }
    }

    [Theory]
    [InlineData(ThemeVariant.ColorfulLight, ThemeVariant.VividLight)]
    [InlineData(ThemeVariant.ColorfulDark, ThemeVariant.VividDark)]
    public void Vivid_HasMoreSaturatedSurfacesThanColored(ThemeVariant colored, ThemeVariant vivid)
    {
        static int Chroma(uint color)
        {
            var channels = new[] { (int)(color >> 16) & 255, (int)(color >> 8) & 255, (int)color & 255 };
            return channels.Max() - channels.Min();
        }

        var subtle = AppearancePalette.For(colored);
        var strong = AppearancePalette.For(vivid);
        Assert.True(Chroma(strong.Page) > Chroma(subtle.Page));
        Assert.True(Chroma(strong.Card) > Chroma(subtle.Card));
        Assert.True(Chroma(strong.Control) > Chroma(subtle.Control));
    }

    [Fact]
    public void SurfaceTreatments_AreDistinctWithoutChangingThePalette()
    {
        foreach (var theme in Enum.GetValues<ThemeVariant>())
        {
            var palette = AppearancePalette.For(theme);
            var treatments = Enum.GetValues<VisualStyle>()
                .Select(style => SurfacePalette.For(palette, style, card: true)).ToArray();

            Assert.Equal(4, treatments.Distinct().Count());
            Assert.Equal(palette.Card, treatments[0].Top);
            Assert.Equal(palette.Card, treatments[0].Bottom);
            Assert.True(treatments[1].Acrylic);
            Assert.False(treatments[2].Acrylic);
            Assert.True(treatments[2].Radius > treatments[3].Radius);
            Assert.True(treatments[2].Elevation > treatments[3].Elevation);
            Assert.Equal(palette, AppearancePalette.For(theme));
        }
    }

    [Fact]
    public void NeumorphicFields_ReverseTheRaisedCardLighting()
    {
        var palette = AppearancePalette.For(ThemeVariant.ColorfulLight);
        var card = SurfacePalette.For(palette, VisualStyle.Neumorphic, card: true);
        var field = SurfacePalette.For(palette, VisualStyle.Neumorphic, card: false);

        Assert.True(card.BorderTop > card.BorderBottom);
        Assert.True(field.BorderTop < field.BorderBottom);
        Assert.True(card.Elevation > 0);
        Assert.Equal(0, field.Elevation);
    }

    [Fact]
    public void EverySurfaceGradient_KeepsReadablePrimaryText()
    {
        static double Linear(uint channel)
        {
            var value = channel / 255.0;
            return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }
        foreach (var theme in Enum.GetValues<ThemeVariant>())
        {
            var palette = AppearancePalette.For(theme);
            foreach (var style in Enum.GetValues<VisualStyle>())
            {
                foreach (var card in new[] { false, true })
                {
                    var surface = SurfacePalette.For(palette, style, card);
                    foreach (var color in new[] { surface.Top, surface.Bottom })
                    {
                        var luminance = 0.2126 * Linear((color >> 16) & 255)
                            + 0.7152 * Linear((color >> 8) & 255) + 0.0722 * Linear(color & 255);
                        var contrast = palette.IsDark ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05;
                        Assert.True(contrast >= 7, $"{theme}/{style}/{card}: {color:X6} has contrast {contrast:F2}:1.");
                    }
                }
            }
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
