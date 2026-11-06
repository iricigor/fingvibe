using System.Text.Json;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PeriodicScanSettingsStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"FingVibe-periodic-{Guid.NewGuid():N}");
    private string FilePath => Path.Combine(_directory, "periodic-scan.json");

    [Fact]
    public void DefaultsAreOffWithAConservativeInterval()
    {
        Assert.False(PeriodicScanSettings.Default.IsEnabled);
        Assert.Equal(60, PeriodicScanSettings.Default.IntervalMinutes);
        Assert.Equal(new[] { 15, 30, 60, 120, 240 }, PeriodicScanSettings.IntervalChoices);
        Assert.Contains(PeriodicScanSettings.DefaultIntervalMinutes, PeriodicScanSettings.IntervalChoices);
    }

    [Fact]
    public void MissingFileReturnsNothing()
    {
        Assert.Null(new PeriodicScanSettingsStore(FilePath).Load());
    }

    [Fact]
    public void RoundTripReplacesAtomically()
    {
        var store = new PeriodicScanSettingsStore(FilePath);
        store.Save(new PeriodicScanSettings(true, 15));
        store.Save(new PeriodicScanSettings(true, 240));

        Assert.Equal(new PeriodicScanSettings(true, 240), store.Load());
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Theory]
    [InlineData("{}", false, 60)]
    [InlineData("{\"isEnabled\":true}", true, 60)]
    [InlineData("{\"isEnabled\":true,\"intervalMinutes\":7}", true, 60)]
    [InlineData("{\"isEnabled\":false,\"intervalMinutes\":120}", false, 120)]
    public void SavedValuesAreNormalized(string json, bool enabled, int minutes)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);

        Assert.Equal(new PeriodicScanSettings(enabled, minutes), new PeriodicScanSettingsStore(FilePath).Load());
    }

    [Theory]
    [InlineData("null")]
    [InlineData("not json")]
    [InlineData("{\"isEnabled\":\"yes\"}")]
    [InlineData("{\"intervalMinutes\":\"hourly\"}")]
    public void InvalidContentReportsFailureWithoutOverwriting(string json)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);

        Assert.Throws<JsonException>(() => new PeriodicScanSettingsStore(FilePath).Load());
        Assert.Equal(json, File.ReadAllText(FilePath));
    }

    [Fact]
    public void UnsupportedIntervalsAreNotSaved()
    {
        Assert.Throws<ArgumentException>(() => new PeriodicScanSettingsStore(FilePath).Save(new PeriodicScanSettings(true, 5)));
        Assert.False(File.Exists(FilePath));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, true);
    }
}
