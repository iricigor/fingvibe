using System.Net;
using System.Net.NetworkInformation;
using System.Xml.Linq;
using FingVibe.App;
using FingVibe.Core.Models;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DiscoveryNotificationTests
{
    private static readonly DiscoveryDevice First = new("001122334455", "001122334455", "Laptop", "192.168.1.2", "\uE7F8");
    private static readonly DiscoveryDevice Second = new("001122334466", "001122334466", "Phone", "192.168.1.3", "\uE8EA");

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void EachQualifyingScanRequestsOneNotificationAndRestoreDoesNotResend(bool minimized)
    {
        var shown = new List<(IReadOnlyList<DiscoveryDevice> Devices, bool Deferred)>();
        var sent = new List<DiscoveryNotificationBatch>();
        var state = new DiscoveryNotificationState((devices, deferred) => shown.Add((devices, deferred)), sent.Add);

        state.CompleteScan([], minimized);
        state.CompleteScan([First], minimized);
        state.CompleteScan([Second], minimized);

        Assert.Equal(2, sent.Count);
        Assert.NotEqual(sent[0].Id, sent[1].Id);
        Assert.Equal(new[] { First }, sent[0].Devices);
        Assert.Equal(new[] { Second }, sent[1].Devices);
        Assert.Equal(minimized ? 0 : 2, shown.Count);
        state.Restore();
        state.Restore();
        Assert.Equal(2, sent.Count);
        if (minimized)
        {
            Assert.True(Assert.Single(shown).Deferred);
            Assert.Equal(new[] { First, Second }, shown[0].Devices);
        }
    }

    [Fact]
    public void MinimizedSnapshotsDeduplicateByLogicalIdentityAndActivationOpensItsOwnScan()
    {
        var shown = new List<IReadOnlyList<DiscoveryDevice>>();
        var sent = new List<DiscoveryNotificationBatch>();
        var state = new DiscoveryNotificationState((devices, _) => shown.Add(devices), sent.Add);
        var virtualDevice = First with { IdentityKey = Guid.NewGuid().ToString("D") };
        state.CompleteScan([virtualDevice, Second], true);
        state.CompleteScan([virtualDevice with { Mac = "001122334477" }], true);

        state.Activate([Second]);
        Assert.Equal(new[] { Second }, Assert.Single(shown));
        state.Restore();
        Assert.Equal(new[] { virtualDevice }, shown[1]);
        Assert.Equal(2, sent.Count);
    }

    [Fact]
    public void DeliveryFailureDoesNotLoseImmediateOrDeferredInAppDiscoveries()
    {
        var shown = new List<IReadOnlyList<DiscoveryDevice>>();
        var state = new DiscoveryNotificationState((devices, _) => shown.Add(devices),
            _ => throw new IOException("Registration/delivery unavailable"));
        Assert.Throws<IOException>(() => state.CompleteScan([First], false));
        Assert.Equal(new[] { First }, Assert.Single(shown));
        Assert.Throws<IOException>(() => state.CompleteScan([Second], true));
        state.Restore();
        Assert.Equal(new[] { Second }, shown[1]);
    }

    [Fact]
    public void CapturedNamesAndAddressesSurviveUnavailableDetails()
    {
        var result = new ScanResult(IPAddress.Parse("192.168.1.2"), HostStatus.Alive, 1, TimeSpan.Zero)
        {
            MacAddress = PhysicalAddress.Parse(First.Mac)
        };
        var row = new ScanResultRow(result, 24);
        var discovery = new DeviceDiscovery(First.Mac);
        var unnamed = DiscoveryDevice.Capture(discovery, row);
        Assert.Equal("Unnamed device", unnamed.Name);
        Assert.Contains("192.168.1.2", unnamed.Addresses);
        var named = DiscoveryDevice.Capture(discovery, new ScanResultRow(result, 24, "Friendly laptop"));
        var unavailable = new DiscoveryPopupItem(named, false);
        Assert.Contains("Friendly laptop", unavailable.AccessibleName);
        Assert.Contains("Details unavailable", unavailable.AccessibleName);
        Assert.Contains("00-11-22-33-44-55", unavailable.AccessibleName);
    }

    [Fact]
    public void ToastHasBoundedEscapedPreviewCountCautionImageAndMatchingActivationActions()
    {
        var devices = Enumerable.Range(0, 100).Select(_ => First with
        {
            Name = string.Concat(Enumerable.Repeat("<&\U0001F4BB", 100))
        }).ToArray();
        var batch = new DiscoveryNotificationBatch(Guid.NewGuid(), DateTimeOffset.UtcNow.AddDays(1), devices);
        var xml = DiscoveryNotificationPresentation.ToastXml(batch, Path.GetFullPath("caution.png"));
        var toast = XElement.Parse(xml);
        Assert.Equal("100 new devices", toast.Descendants("text").First().Value);
        Assert.Contains("(+97 more)", toast.Descendants("text").Last().Value);
        Assert.Contains("<&\U0001F4BB", toast.Descendants("text").Last().Value);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(xml) < 5000);
        Assert.Equal(DiscoveryNotificationPresentation.Argument(batch.Id), toast.Attribute("launch")!.Value);
        Assert.Equal(toast.Attribute("launch")!.Value, toast.Descendants("action").Single().Attribute("arguments")!.Value);
        Assert.Contains("Unfamiliar", toast.Descendants("image").Single().Attribute("alt")!.Value);
        var single = XElement.Parse(DiscoveryNotificationPresentation.ToastXml(batch with { Devices = [First] },
            Path.GetFullPath("caution.png")));
        Assert.Contains("1 new device", single.Descendants("text").Last().Value);
    }

    [Fact]
    public async Task ActivationPayloadSurvivesRestartButExpiredCorruptAndInvalidLinksFailExplicitly()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-discovery-{Guid.NewGuid():N}");
        var time = new FakeTimeProvider();
        var batch = new DiscoveryNotificationBatch(Guid.NewGuid(), time.GetUtcNow().AddDays(1), [First, Second]);
        try
        {
            await new DiscoveryNotificationStore(directory, time).SaveAsync(batch);
            var restarted = new DiscoveryNotificationStore(directory, time);
            var restored = await restarted.LoadAsync(DiscoveryNotificationPresentation.ParseArgument(
                DiscoveryNotificationPresentation.Argument(batch.Id)));
            Assert.Equal(batch.Devices, restored.Devices);
            time.Advance(TimeSpan.FromDays(1));
            await Assert.ThrowsAsync<InvalidDataException>(() => restarted.LoadAsync(batch.Id));
            await File.WriteAllTextAsync(Path.Combine(directory, $"{batch.Id:D}.json"), "{");
            await Assert.ThrowsAsync<System.Text.Json.JsonException>(() => restarted.LoadAsync(batch.Id));
            Assert.Throws<InvalidDataException>(() => DiscoveryNotificationPresentation.ParseArgument("discovery=..\\inventory"));
            await Assert.ThrowsAsync<FileNotFoundException>(() => restarted.LoadAsync(Guid.NewGuid()));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }
}
