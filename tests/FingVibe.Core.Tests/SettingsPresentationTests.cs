using FingVibe.App.Views;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SettingsPresentationTests
{
    [Theory]
    [InlineData(ThemeVariant.WarmLight, WindowBackdrop.MicaAlt, "Light mode", "Warm theme", "Mica Alt backdrop")]
    [InlineData(ThemeVariant.OledDark, WindowBackdrop.Solid, "Dark mode", "True Black (OLED) theme", "Solid backdrop")]
    [InlineData(ThemeVariant.ColorfulDark, WindowBackdrop.Acrylic, "Dark mode", "Colorful theme", "Acrylic backdrop")]
    public void AppearanceSummary_ReflectsSelectionAndMaterialLimits(
        ThemeVariant theme, WindowBackdrop backdrop, string modeText, string themeText, string backdropText)
    {
        const string material = "High contrast is active; Windows system colors are used instead of materials.";
        var summary = SettingsPresentation.AppearanceSummary(new(backdrop, theme), material);
        Assert.Contains(modeText, summary);
        Assert.Contains(themeText, summary);
        Assert.Contains(backdropText, summary);
        Assert.EndsWith(material, summary);
    }

    [Fact]
    public void DevicesSummary_ReflectsBothSwitchesAndVisibleChoices()
    {
        Assert.Equal("Compact rows on \u00b7 Cell hover previews off \u00b7 13 visible columns",
            SettingsPresentation.DevicesSummary(true, false, 13));
        Assert.Equal("Compact rows off \u00b7 Cell hover previews on \u00b7 2 visible columns",
            SettingsPresentation.DevicesSummary(false, true, 2));
    }

    [Theory]
    [InlineData(true, "Paused: The selected LAN is unavailable.")]
    [InlineData(true, "Paused while Windows sleeps.")]
    [InlineData(true, "Scheduled-scan changes apply now but could not be saved for the next launch.")]
    [InlineData(false, "Off. Scans run only when you select Scan LAN.")]
    public void ScheduledSummary_SeparatesConfigurationFromActualExecution(bool enabled, string status)
    {
        var summary = SettingsPresentation.ScheduledSummary(new(enabled, 60), status);
        Assert.StartsWith(enabled ? "Enabled" : "Disabled", summary);
        Assert.Contains("Every 1 hour", summary);
        Assert.Contains("While FingVibe is open", summary);
        Assert.EndsWith(status, summary);
        Assert.DoesNotContain("in progress", summary);
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(200, 1)]
    [InlineData(415.9, 1)]
    [InlineData(416, 2)]
    [InlineData(631.9, 2)]
    [InlineData(632, 3)]
    [InlineData(1400, 3)]
    public void ColumnCount_UsesMatchingResponsiveThresholds(double width, int expected) =>
        Assert.Equal(expected, SettingsPresentation.ColumnCount(width));

    [Fact]
    public void AppearanceStatus_NormalFeedbackIsOneSentence() =>
        Assert.Equal(
            "Appearance changes apply immediately and save automatically, with material effects depending on Windows transparency settings.",
            SettingsPresentation.AppearanceStatus(null, null));

    [Theory]
    [InlineData(null)]
    [InlineData("High contrast is active; Windows system colors are used instead of materials.")]
    [InlineData("This material is unavailable. A solid background is used; your choice is kept.")]
    public void AppearanceStatus_SaveFailureNeverClaimsSaved(string? material)
    {
        const string error = "Appearance applied, but could not be saved for the next launch.";
        var status = SettingsPresentation.AppearanceStatus(error, material);
        Assert.StartsWith(error, status);
        Assert.DoesNotContain("save automatically", status);
        if (material is not null) Assert.EndsWith(material, status);
        Assert.Equal(error, SettingsPresentation.AppearanceStatus(error, null));
    }

    [Theory]
    [InlineData("High contrast is active; Windows system colors are used instead of materials.")]
    [InlineData("This material is unavailable. A solid background is used; your choice is kept.")]
    public void AppearanceStatus_PreservesMaterialFeedbackWithoutNormalDisclaimer(string material)
    {
        Assert.Equal($"Appearance changes apply immediately and save automatically. {material}",
            SettingsPresentation.AppearanceStatus(null, material));
        Assert.DoesNotContain("transparency settings", SettingsPresentation.AppearanceStatus(null, material));
    }
}
