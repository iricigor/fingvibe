using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class AppearanceModesTests
{
    [Theory]
    [InlineData(ThemeVariant.StandardLight, ThemeVariant.StandardDark)]
    [InlineData(ThemeVariant.WarmLight, ThemeVariant.OledDark)]
    [InlineData(ThemeVariant.ColorfulLight, ThemeVariant.ColorfulDark)]
    public void SwitchingModeKeepsThePairedThemeAndBackdropInBothDirections(ThemeVariant light, ThemeVariant dark)
    {
        foreach (var backdrop in Enum.GetValues<WindowBackdrop>())
        {
            Assert.Equal(new AppearanceSettings(backdrop, dark), AppearanceModes.WithMode(new AppearanceSettings(backdrop, light), dark: true));
            Assert.Equal(new AppearanceSettings(backdrop, light), AppearanceModes.WithMode(new AppearanceSettings(backdrop, dark), dark: false));
        }

        Assert.False(AppearanceModes.IsDark(light));
        Assert.True(AppearanceModes.IsDark(dark));
    }

    [Theory]
    [InlineData(ThemeVariant.WarmLight, false)]
    [InlineData(ThemeVariant.OledDark, true)]
    public void ChoosingTheCurrentModeLeavesSettingsUnchanged(ThemeVariant theme, bool dark)
    {
        var settings = new AppearanceSettings(WindowBackdrop.MicaAlt, theme);
        Assert.Equal(settings, AppearanceModes.WithMode(settings, dark));
    }

    [Fact]
    public void RejectsUnknownThemes()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            AppearanceModes.WithMode(new AppearanceSettings(Theme: (ThemeVariant)99), dark: true));
    }
}
