using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class DiscoveryPopup : UserControl
{
    public event EventHandler? DismissRequested;
    public event EventHandler<string>? DetailsRequested;

    public DiscoveryPopup() => InitializeComponent();

    internal void SetDiscoveries(IReadOnlyList<DiscoveryPopupItem> devices, bool deferred)
    {
        TitleText.Text = DiscoveryNotificationPresentation.Count(devices.Count);
        ContextText.Text = deferred ? "Discovered while FingVibe was minimized" : "Discovered on your network";
        Entries.ItemsSource = devices;
    }

    private void Dismiss_Click(object sender, RoutedEventArgs e) => DismissRequested?.Invoke(this, EventArgs.Empty);

    private void Device_Click(object sender, RoutedEventArgs e) =>
        DetailsRequested?.Invoke(this, (string)((Button)sender).Tag);
}
