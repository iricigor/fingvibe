using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceFilterSelectionTests
{
    [Fact]
    public void AnyRequiresTwoDistinctKnownChoicesRatherThanTwoDevicesOrPlaceholders()
    {
        var selection = new DeviceFilterSelection<string>("Unknown", StringComparer.OrdinalIgnoreCase,
            DeviceVendorPresentation.IsKnown);
        selection.SetChoices([("Unknown", "Unknown"), ("Private/Randomized", "Randomized MAC"), ("Acme", "Acme")]);
        Assert.False(selection.ShowAnyChoice);
        selection.SetChoices([("Unknown", "Unknown"), ("Acme", "Acme"), ("ACME", "Acme")]);
        Assert.False(selection.ShowAnyChoice);
        selection.SetChoices([("Unknown", "Unknown"), ("Acme", "Acme"), ("Example", "Example")]);
        Assert.True(selection.ShowAnyChoice);
    }

    [Fact]
    public void AnyReplacesSpecificAndMissingSelectionsAndIsNotASnapshot()
    {
        var selection = new DeviceFilterSelection<string>("Unknown");
        selection.SetChoices([("Unknown", "Unknown"), ("A", "A"), ("B", "B")]);
        selection.SelectOnly(["Unknown", "A"]);
        Assert.True(selection.SetAnyKnown(true));
        Assert.True(selection.AnyKnown);
        Assert.True(selection.HasRestriction);
        Assert.Empty(selection.Selected);

        selection.SetChoices([("Unknown", "Unknown"), ("B", "B"), ("C", "C")]);
        Assert.True(selection.AnyKnown);
        Assert.Empty(selection.Selected);
        Assert.Contains(selection.Choices, choice => choice.Value == "C");
    }

    [Theory]
    [InlineData("Unknown")]
    [InlineData("A")]
    public void IndividualChoiceReplacesAnyAndOrdinaryMultiSelectionStillWorks(string first)
    {
        var selection = new DeviceFilterSelection<string>("Unknown");
        selection.SetAnyKnown(true);
        Assert.True(selection.SetSelected(first, true));
        Assert.False(selection.AnyKnown);
        Assert.Equal([first], selection.Selected);
        selection.SetSelected("B", true);
        Assert.Equal(2, selection.Selected.Count);
        selection.SetSelected(first, false);
        Assert.Equal(["B"], selection.Selected);
    }

    [Fact]
    public void RefreshHidesUnavailableAnyChoiceWithoutSilentlyClearingItsRestriction()
    {
        var selection = new DeviceFilterSelection<Guid?>(null);
        var first = Guid.NewGuid();
        selection.SetChoices([(null, "Unassigned"), (first, "First"), (Guid.NewGuid(), "Second")]);
        Assert.True(selection.ShowAnyChoice);
        selection.SetAnyKnown(true);
        selection.SetChoices([(null, "Unassigned"), (first, "First")]);
        Assert.False(selection.ShowAnyChoice);
        Assert.True(selection.AnyKnown);
        Assert.True(selection.HasRestriction);
        selection.Clear();
        Assert.False(selection.AnyKnown);
        Assert.False(selection.HasRestriction);
    }

    [Fact]
    public void SelectedValuesSurviveRefreshUntilExplicitlyCleared()
    {
        var selection = new DeviceFilterSelection<string>("Unknown");
        selection.SetChoices([("Unknown", "Unknown"), ("A", "A"), ("B", "B")]);
        selection.SelectOnly(["A"]);
        selection.SetChoices([("Unknown", "Unknown"), ("B", "B")]);
        Assert.Contains("A", selection.Selected);
        Assert.Contains(selection.Choices, choice => choice.Value == "A");
        selection.Clear();
        Assert.False(selection.HasRestriction);
        selection.SetChoices([("Unknown", "Unknown"), ("B", "B")]);
        Assert.DoesNotContain(selection.Choices, choice => choice.Value == "A");
    }

    [Fact]
    public void UncheckingAnyRestoresUnrestrictedRatherThanSelectingUnknown()
    {
        var selection = new DeviceFilterSelection<string>("Unknown");
        selection.SetAnyKnown(true);
        Assert.True(selection.SetAnyKnown(false));
        Assert.Empty(selection.Selected);
        Assert.False(selection.HasRestriction);
        Assert.False(selection.SetAnyKnown(false));
    }
}
