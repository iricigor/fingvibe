using System.Collections.ObjectModel;
using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class InventoryPresentationTests
{
    [Fact]
    public void AutomaticUsageRefreshCoalescesCompletedStateButRetainsChangesAndExplicitRetry()
    {
        Assert.False(InventoryPresentation.ShouldStartUsageRefresh("current", "current", false, false));
        Assert.True(InventoryPresentation.ShouldStartUsageRefresh("current", "changed", true, false));
        Assert.True(InventoryPresentation.ShouldStartUsageRefresh("current", "current", true, false));
        Assert.True(InventoryPresentation.ShouldStartUsageRefresh("current", "current", false, true));
    }

    [Fact]
    public void UnchangedVisibleSequenceAvoidsCollectionChangesAndStillAppliesPresentation()
    {
        var values = new ObservableCollection<int>([1, 2, 3]);
        var changes = 0;
        var presented = new List<(int Item, int Index)>();
        values.CollectionChanged += (_, _) => changes++;

        InventoryPresentation.Reconcile(values, [1, 2, 3],
            (item, index) => presented.Add((item, index)));

        Assert.Equal(0, changes);
        Assert.Equal([(1, 0), (2, 1), (3, 2)], presented);
        Assert.Equal([1, 2, 3], values);
    }

    [Fact]
    public void ChangedVisibleSequencePreservesReconciliationSemantics()
    {
        var values = new ObservableCollection<int>([1, 2, 3, 4]);

        InventoryPresentation.Reconcile(values, [4, 2, 5, 1]);

        Assert.Equal([4, 2, 5, 1], values);
    }
}
