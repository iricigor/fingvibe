using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed record DeviceMatchCard(string Name, string Status, string Addresses, string Description);

public sealed record DeviceMatchItem(string OtherMac, DeviceMatchCard Other, string ShortReason, string Explanation);

public sealed partial class DeviceDetailsPageView
{
    private IReadOnlyList<DeviceMatchItem> _matches = [];
    private string? _selectedMatchMac;
    private bool _matchExpansionApplied;

    public event EventHandler<string>? MatchDeclineRequested;

    internal string? SelectedMatchMac => _selectedMatchMac;

    /// <summary>Shows the device's suggestions. Opening a device expands the section once; refreshes keep the user's choice.</summary>
    internal void ShowMatchSuggestions(DeviceMatchCard device, IReadOnlyList<DeviceMatchItem> matches, bool opening)
    {
        if (opening)
        {
            _matchExpansionApplied = false;
            _selectedMatchMac = null;
            MergeMacError.IsOpen = false;
        }
        _matches = matches;
        if (matches.Count == 0)
        {
            MergeMacExpander.Visibility = Visibility.Collapsed;
            _selectedMatchMac = null;
            return;
        }
        if (!matches.Any(item => item.OtherMac == _selectedMatchMac)) _selectedMatchMac = matches[0].OtherMac;
        MergeMacExpander.Visibility = Visibility.Visible;
        if (!_matchExpansionApplied)
        {
            MergeMacExpander.IsExpanded = true;
            _matchExpansionApplied = true;
        }
        var count = matches.Count == 1 ? "1 possible match" : $"{matches.Count} possible matches";
        MergeMacCount.Text = count;
        AutomationProperties.SetHelpText(MergeMacExpander, count);
        MergeMacThisName.Text = device.Name;
        MergeMacThisStatus.Text = device.Status;
        MergeMacThisAddresses.Text = device.Addresses;
        MergeMacThisDescription.Text = device.Description;
        ShowSelectedMatch();
        MergeMacChoices.Items.Clear();
        foreach (var item in matches)
        {
            var choice = new MenuFlyoutItem
            {
                Text = $"{item.Other.Name} · {item.Other.Addresses} · {item.ShortReason}",
                Tag = item.OtherMac
            };
            choice.Click += (sender, _) =>
            {
                _selectedMatchMac = (string)((MenuFlyoutItem)sender).Tag;
                MergeMacError.IsOpen = false;
                ShowSelectedMatch();
            };
            MergeMacChoices.Items.Add(choice);
        }
        MergeMacChangeDevice.Visibility = matches.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Selects Overview, expands the section and brings it into view, as requested from a Devices row.</summary>
    internal void RevealMatchSuggestions()
    {
        if (MergeMacExpander.Visibility != Visibility.Visible) return;
        DetailsTabs.SelectedItem = OverviewTab;
        ShowTab(OverviewTab);
        MergeMacExpander.IsExpanded = true;
        _matchExpansionApplied = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            MergeMacExpander.UpdateLayout();
            MergeMacExpander.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 0 });
        });
    }

    internal void ShowMatchError(string message)
    {
        MergeMacError.Message = message;
        MergeMacError.IsOpen = true;
        MergeMacDecline.IsEnabled = true;
    }

    private void ShowSelectedMatch()
    {
        var index = Math.Max(0, _matches.ToList().FindIndex(item => item.OtherMac == _selectedMatchMac));
        var match = _matches[index];
        MergeMacOtherHeading.Text = $"Selected other MAC address · suggestion {index + 1} of {_matches.Count}";
        MergeMacOtherName.Text = match.Other.Name;
        MergeMacOtherStatus.Text = match.Other.Status;
        MergeMacOtherAddresses.Text = match.Other.Addresses;
        MergeMacOtherDescription.Text = match.Other.Description;
        MergeMacReason.Text = $"Suggested because {match.Explanation}. This does not establish physical identity.";
        MergeMacDecline.IsEnabled = true;
        AutomationProperties.SetName(MergeMacDecline, $"Decline suggestion: {match.Other.Name}");
    }

    private void MergeMacDecline_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMatchMac is not { } other) return;
        MergeMacError.IsOpen = false;
        MergeMacDecline.IsEnabled = false;
        MatchDeclineRequested?.Invoke(this, other);
    }
}
