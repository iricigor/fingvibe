using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private void ResultsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ScanResultRow row)
        {
            return;
        }

        var result = row.Result;
        DeviceTitleText.Text = result.NameText;
        DeviceAddressText.Text = result.AddressText;
        DeviceMacText.Text = result.MacAddressText;
        DeviceVendorText.Text = result.VendorText;
        DeviceStatusText.Text = row.IsOnline ? "Online" : "Offline (no ICMP response)";
        DeviceResponseText.Text = result.RoundtripText;
        DeviceProbeText.Text = $"{result.ProbeDuration.TotalMilliseconds:N0} ms";
        DevicePortsList.ItemsSource = result.OpenPortItems;
        DeviceNoPortsText.Visibility = result.OpenPortItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowPage(DevicePage);
    }
}
