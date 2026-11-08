using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private void UpdateDeviceActivity()
    {
        if (_selectedDeviceRow is not { } row) return;
        var network = NetworkPicker.SelectedItem as LanNetwork;
        string? identityError = null;
        var networkId = network is null ? null : ResolveNetworkIdentity(network, out identityError);
        var id = row.UsageIdentity;
        var revision = _inventory.Revision;
        var key = $"{revision}|{id}|{networkId}|{network?.Cidr}|{_inventoryReady}|{_inventoryUnavailable}";
        var unavailable = !_inventoryReady ? "Loading saved inventory..."
            : _inventoryUnavailable ? $"Activity is unavailable: {_inventoryError}"
            : networkId is null || network is null ? $"Select a network with a reliable identity. {identityError}"
            : id is null ? "A stable saved device identity is required for activity."
            : row.VirtualDevice is { } slot && (slot.NetworkId != networkId || slot.Subnet != network.Cidr)
                ? "This virtual identity belongs to a different network. Select its network to view activity."
            : null;
        if (unavailable is not null)
        {
            DevicePage.ConfigureActivity(key, null, unavailable, loading: !_inventoryReady);
            return;
        }
        var subnet = network!.Cidr;
        DevicePage.ConfigureActivity(key, async (days, hours, cancellation) =>
        {
            if (IsUiReview && !string.IsNullOrEmpty(ReviewInventoryPath)
                && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_ACTIVITY_HOLD") is { Length: > 0 } holdPath)
                await DeviceActivityReviewHold.WaitAsync(holdPath, cancellation);
            var now = DateTimeOffset.UtcNow;
            var zone = TimeZoneInfo.Local;
            AnalyticsEvidence evidence;
            if (revision == Guid.Empty || IsUiReview && string.IsNullOrEmpty(ReviewInventoryPath))
            {
                var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
                evidence = new(revision, networkId!, subnet, now, zone.Id, date.AddDays(1 - days), date, now,
                    [new(id!, null, false)], [], null);
            }
            else evidence = await _inventoryStore.QueryAnalyticsAsync(
                new(networkId!, subnet, now, days, zone, revision, [id!]), cancellation);
            return DeviceActivity.Group(evidence, hours, cancellation);
        });
    }
}
