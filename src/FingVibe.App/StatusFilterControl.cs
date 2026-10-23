using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Input;

namespace FingVibe.App;

public sealed class StatusFilterControl : Segmented
{
    protected override AutomationPeer OnCreateAutomationPeer() => new StatusFilterAutomationPeer(this);

    protected override void OnGotFocus(RoutedEventArgs e)
    {
        base.OnGotFocus(e);
        // Toolkit arrow navigation moves focus programmatically, bypassing selection-follows-focus.
        if (SingleSelectionFollowsFocus && FocusManager.GetFocusedElement(XamlRoot) is SegmentedItem item
            && Items.Contains(item))
        {
            SelectedItem = item;
        }
    }

    private sealed class StatusFilterAutomationPeer(StatusFilterControl owner) : ListViewBaseAutomationPeer(owner)
    {
        protected override string GetClassNameCore() => nameof(StatusFilterControl);

        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.List;

        protected override ItemAutomationPeer OnCreateItemAutomationPeer(object item) =>
            new ListViewItemDataAutomationPeer(item, this);
    }
}
