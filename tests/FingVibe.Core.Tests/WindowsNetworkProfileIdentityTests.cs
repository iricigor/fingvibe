using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class WindowsNetworkProfileIdentityTests
{
    [Fact]
    public void SelectedAdapterUsesItsOwnNetworkProfileRatherThanAnotherAdaptersProfile()
    {
        var homeAdapter = Guid.NewGuid();
        var workAdapter = Guid.NewGuid();
        var homeProfile = Guid.NewGuid();
        var workProfile = Guid.NewGuid();
        var profiles = new[] { (homeAdapter, homeProfile), (workAdapter, workProfile) };
        Assert.Equal(homeProfile, WindowsNetworkProfileIdentity.FindNetworkId(homeAdapter, profiles));
        Assert.Equal(workProfile, WindowsNetworkProfileIdentity.FindNetworkId(workAdapter, profiles));
        Assert.Equal(homeProfile, WindowsNetworkProfileIdentity.FindNetworkId(homeAdapter, profiles.Reverse()));
    }

    [Fact]
    public void ReturningToSameAdapterOnAnotherNetworkDoesNotReusePreviousProfile()
    {
        var adapter = Guid.NewGuid();
        var home = Guid.NewGuid();
        var work = Guid.NewGuid();
        Assert.Equal(home, WindowsNetworkProfileIdentity.FindNetworkId(adapter, [(adapter, home)]));
        Assert.Equal(work, WindowsNetworkProfileIdentity.FindNetworkId(adapter, [(adapter, work)]));
        Assert.Equal(home, WindowsNetworkProfileIdentity.FindNetworkId(adapter, [(adapter, home)]));
    }

    [Fact]
    public void MissingEmptyOrAmbiguousProfilesFailInsteadOfUsingGlobalFallback()
    {
        var adapter = Guid.NewGuid();
        Assert.Throws<InvalidOperationException>(() => WindowsNetworkProfileIdentity.FindNetworkId(adapter, []));
        Assert.Throws<InvalidOperationException>(() => WindowsNetworkProfileIdentity.FindNetworkId(adapter, [(adapter, Guid.Empty)]));
        Assert.Throws<InvalidOperationException>(() => WindowsNetworkProfileIdentity.FindNetworkId(adapter, [(adapter, Guid.NewGuid()), (adapter, Guid.NewGuid())]));
        Assert.Throws<InvalidOperationException>(() => WindowsNetworkProfileIdentity.FindNetworkId(Guid.Empty, [(Guid.Empty, Guid.NewGuid())]));
    }
}
