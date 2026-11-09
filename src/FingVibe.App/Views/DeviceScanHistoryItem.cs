using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed class DeviceScanHistoryItem : ContentControl
{
    protected override AutomationPeer OnCreateAutomationPeer() => new HistoryItemPeer(this);

    private sealed class HistoryItemPeer(DeviceScanHistoryItem owner)
        : FrameworkElementAutomationPeer(owner), IScrollItemProvider
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.DataItem;
        protected override string GetClassNameCore() => nameof(DeviceScanHistoryItem);
        protected override object GetPatternCore(PatternInterface patternInterface) =>
            patternInterface == PatternInterface.ScrollItem ? this : base.GetPatternCore(patternInterface);

        public void ScrollIntoView() =>
            owner.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
    }
}
