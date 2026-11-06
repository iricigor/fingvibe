using FingVibe.App.Views;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SettingsPresentationTests
{
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
