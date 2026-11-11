using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private void UpdateEquipmentActivity()
    {
        if (PersonDetailPage is null) return;
        var person = PersonDetailPage.SelectedPerson;
        var network = NetworkPicker.SelectedItem as LanNetwork;
        string? identityError = null;
        var networkId = network is null ? null : ResolveNetworkIdentity(network, out identityError);
        var data = CurrentDeviceData;
        var key = $"{data.Revision}|{person?.Id}|{networkId}|{network?.Cidr}|{_inventoryReady}|{_inventoryUnavailable}";
        var unavailable = !_inventoryReady ? "Loading saved inventory..."
            : _inventoryUnavailable ? $"Activity is unavailable: {_inventoryError}"
            : person is null ? "Select a person."
            : networkId is null || network is null ? $"Select a network with a reliable identity. {identityError}" : null;
        var label = network is null ? "No selected network" : $"{networkId ?? network.InterfaceName} | {network.Cidr}";
        if (unavailable is not null)
        {
            PersonDetailPage.ConfigureActivity(key, label, null, unavailable,
                loading: !_inventoryReady, error: _inventoryUnavailable);
            return;
        }
        var personId = person!.Id;
        var subnet = network!.Cidr;
        PersonDetailPage.ConfigureActivity(key, label, async (days, hours, weekdays, cancellation) =>
        {
            if (IsUiReview && !string.IsNullOrEmpty(ReviewInventoryPath)
                && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_EQUIPMENT_ACTIVITY_HOLD") is { Length: > 0 } holdPath)
                await DeviceActivityReviewHold.WaitAsync(holdPath, cancellation);
            var now = DateTimeOffset.UtcNow;
            var zone = TimeZoneInfo.Local;
            if (data.Revision == Guid.Empty || IsUiReview && string.IsNullOrEmpty(ReviewInventoryPath))
            {
                var selection = EquipmentActivity.Select(data, personId, networkId!, subnet);
                var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
                var evidence = new AnalyticsEvidence(data.Revision, networkId!, subnet, now, zone.Id,
                    date.AddDays(1 - days), date, now,
                    selection.QueryDevices.Select(id => new AnalyticsDevice(id, null, false)).ToArray(), [], null);
                return EquipmentActivityPresentation.Create(EquipmentActivity.IncludeUnavailable(evidence, selection),
                    data, hours, weekdays, cancellation);
            }
            return await EquipmentActivityPresentation.LoadAsync(_inventoryStore, data, personId,
                new(networkId!, subnet, now, days, zone, data.Revision), hours, weekdays, cancellation);
        });
    }
}
