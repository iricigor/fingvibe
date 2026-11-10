using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class UsageCategoryCellTests
{
    private static ScanResultRow Row() => new(new ScanResult(
        IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1, TimeSpan.Zero), 24);

    private static DeviceUsageInference Inference(DeviceUsageCategory category, bool limited = true) => new(
        LogicalDeviceId.Mac("001122334455"), category, new(12, 14), new(8, 10), new(4, 4),
        2, limited, new(2026, 11, 1), new(2026, 11, 7), "test-network", "192.0.2.0/24", "UTC");

    [Fact]
    public void AutomaticCategoryHasAProvisionalIndicatorAndAccessibleReasonsRatherThanRepeatedInlineText()
    {
        var row = Row();
        row.SetUsageCategory(null, Inference(DeviceUsageCategory.Permanent), "");
        Assert.Equal("Permanent", row.UsageCategoryCellText);
        Assert.True(row.HasUsageCategoryIndicator);
        Assert.Equal("\uE946", row.UsageCategoryIndicatorGlyph);
        Assert.Contains("Auto - limited evidence", row.UsageCategoryCellName);
        Assert.Contains("12 of 14 eligible scans", row.UsageCategoryDescription);
        Assert.Contains("2 of 7 observed dates", row.UsageCategoryDescription);
        Assert.Contains("14 of 30 eligible scans", row.UsageCategoryDescription);
        Assert.Contains("test-network", row.UsageCategoryDescription);
        Assert.Equal(1, row.UsageCategoryOpacity);
    }

    [Fact]
    public void ManualChoiceIsNotMarkedProvisionalAndReusedRowsRefreshEveryCellProperty()
    {
        var row = Row();
        var changes = new List<string?>();
        row.PropertyChanged += (_, args) => changes.Add(args.PropertyName);
        row.SetUsageCategory(DeviceUsageCategory.Personal, Inference(DeviceUsageCategory.Permanent), "");
        Assert.Equal("Personal", row.UsageCategoryCellText);
        Assert.Equal("\uE718", row.UsageCategoryIndicatorGlyph);
        Assert.Contains("Manual override", row.UsageCategoryCellName);
        Assert.Contains("Automatic recommendation: Permanent", row.UsageCategoryDescription);
        row.SetUsageCategory(null, Inference(DeviceUsageCategory.Guest, limited: false), "");
        Assert.Equal("Guest", row.UsageCategoryCellText);
        Assert.False(row.HasUsageCategoryIndicator);
        foreach (var property in new[]
        {
            nameof(row.UsageCategoryCellText), nameof(row.UsageCategoryCellName), nameof(row.UsageCategoryOpacity),
            nameof(row.HasUsageCategoryIndicator), nameof(row.UsageCategoryIndicatorGlyph), nameof(row.UsageCategoryDescription)
        })
            Assert.Contains(property, changes);
    }

    [Fact]
    public void UnclassifiedNoEvidenceLoadingAndFailureRemainDistinct()
    {
        var row = Row();
        row.SetUsageCategory(null, null, "Loading completed usage evidence...", loading: true);
        Assert.Equal("Loading", row.UsageCategoryCellText);
        Assert.Contains("Loading completed usage evidence", row.UsageCategoryDescription);
        row.SetUsageCategory(null, null, "Usage evidence could not be loaded: unavailable database.");
        Assert.Equal("Unavailable", row.UsageCategoryCellText);
        Assert.Contains("could not be loaded", row.UsageCategoryCellName);
        Assert.DoesNotContain("%", row.UsageCategoryDescription);
        Assert.True(row.HasUsageCategoryIndicator);

        row.SetUsageCategory(null, Inference(DeviceUsageCategory.Unclassified) with
        {
            Total = new(0, 0), OvernightWeekend = new(0, 0), WeekdayDaytime = new(0, 0), ObservedDates = 0
        }, "");
        Assert.Equal("Unclassified", row.UsageCategoryCellText);
        Assert.Equal(0.65, row.UsageCategoryOpacity);
        Assert.Contains("No eligible scans", row.UsageCategoryDescription);
        Assert.DoesNotContain("%", row.UsageCategoryDescription);
    }

    [Fact]
    public void PersonalEvidenceExplainsTheMissingComparatorCount()
    {
        var description = UsageCategoryPresentation.Description(null, Inference(DeviceUsageCategory.Personal), "");
        Assert.Contains("4 of 10 weekday daytime scans", description);
        Assert.DoesNotContain("10 of 10 overnight/weekend scans", description);
    }
}
