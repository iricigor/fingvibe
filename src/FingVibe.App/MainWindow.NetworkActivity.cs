using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private void UpdateNetworkActivity()
    {
        var network = NetworkPicker.SelectedItem as LanNetwork;
        string? identityError = null;
        var networkId = network is null ? null : ResolveNetworkIdentity(network, out identityError);
        var data = CurrentDeviceData;
        var key = $"{data.Revision}|{networkId}|{network?.Cidr}|{_inventoryReady}|{_inventoryUnavailable}";
        var unavailable = !_inventoryReady ? "Loading saved inventory..."
            : _inventoryUnavailable ? $"Activity is unavailable: {_inventoryError}"
            : networkId is null || network is null ? $"Select a network with a reliable identity. {identityError}" : null;
        if (unavailable is not null)
        {
            NetworkPage.ConfigureActivity(key, null, data.PeopleRooms.Rooms, unavailable,
                loading: !_inventoryReady, error: _inventoryUnavailable);
            return;
        }
        var subnet = network!.Cidr;
        NetworkPage.ConfigureActivity(key, async (days, hours, weekdays, filter, cancellation) =>
        {
            if (IsUiReview && !string.IsNullOrEmpty(ReviewInventoryPath)
                && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_NETWORK_ACTIVITY_HOLD") is { Length: > 0 } holdPath)
                await DeviceActivityReviewHold.WaitAsync(holdPath, cancellation);
            var now = DateTimeOffset.UtcNow;
            var zone = TimeZoneInfo.Local;
            AnalyticsEvidence evidence;
            if (data.Revision == Guid.Empty || IsUiReview && string.IsNullOrEmpty(ReviewInventoryPath))
            {
                var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
                evidence = new(data.Revision, networkId!, subnet, now, zone.Id, date.AddDays(1 - days), date, now, [], [], null);
            }
            else evidence = await _inventoryStore.QueryAnalyticsAsync(
                new(networkId!, subnet, now, days, zone, data.Revision), cancellation);
            return NetworkActivityPresentation.Create(evidence, data, hours, weekdays, filter, cancellation);
        }, data.PeopleRooms.Rooms);
    }
}
