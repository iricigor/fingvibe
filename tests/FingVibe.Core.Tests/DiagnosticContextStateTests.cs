using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DiagnosticContextStateTests
{
    private static readonly LanNetwork Network = new("Ethernet", IPAddress.Parse("192.0.2.10"),
        IPAddress.Parse("192.0.2.0"), 24, true, IPAddress.Parse("192.0.2.1"),
        "11111111-1111-1111-1111-111111111111");
    private static readonly Guid Profile = Guid.Parse("22222222-2222-2222-2222-222222222222");

    [Fact]
    public void RepeatedNotificationsAndDisplayNameChangesPreserveContext()
    {
        var renamed = Network with { InterfaceName = "Renamed adapter" };
        for (var index = 0; index < 100; index++)
            Assert.True(DiagnosticContextState.Matches(Network, Profile, renamed, Profile));
        Assert.True(DiagnosticContextState.Matches(null, null, null, null));
    }

    [Fact]
    public void GenuineAdapterAddressSubnetGatewayAndProfileChangesInvalidateContext()
    {
        var changes = new[]
        {
            Network with { InterfaceId = Guid.NewGuid().ToString() },
            Network with { LocalAddress = IPAddress.Parse("192.0.2.11") },
            Network with { NetworkAddress = IPAddress.Parse("192.0.0.0") },
            Network with { PrefixLength = 16 },
            Network with { GatewayAddress = IPAddress.Parse("192.0.2.2") },
            Network with { HasGateway = false, GatewayAddress = null }
        };
        foreach (var changed in changes)
            Assert.False(DiagnosticContextState.Matches(Network, Profile, changed, Profile));
        Assert.False(DiagnosticContextState.Matches(Network, Profile, Network, Guid.NewGuid()));
        Assert.False(DiagnosticContextState.Matches(Network, Profile, Network, null));
        Assert.False(DiagnosticContextState.Matches(Network, Profile, null, null));
        Assert.False(DiagnosticContextState.Matches(null, null, Network, Profile));
    }

    [Fact]
    public void ReorderingOtherAdaptersDoesNotChangeTheSelectedContext()
    {
        var other = Network with { InterfaceId = Guid.NewGuid().ToString(), LocalAddress = IPAddress.Parse("198.51.100.10") };
        Assert.Equal(Network, DiagnosticContextState.Select([other, Network], Network));
        Assert.Equal(Network, DiagnosticContextState.Select([Network, other], Network));
        Assert.Equal(other, DiagnosticContextState.Select([other], Network));
        Assert.Null(DiagnosticContextState.Select([], Network));
    }

    [Fact]
    public void AddressChangeKeepsTheSelectedAdapterRatherThanSwitchingToAnother()
    {
        var changed = Network with { LocalAddress = IPAddress.Parse("192.0.2.11") };
        var other = Network with { InterfaceId = Guid.NewGuid().ToString() };
        Assert.Equal(changed, DiagnosticContextState.Select([other, changed], Network));
        Assert.False(DiagnosticContextState.Matches(Network, Profile, changed, Profile));
    }

    [Fact]
    public void MissingAdapterIdsDoNotConflateDifferentInterfaces()
    {
        var before = Network with { InterfaceId = null };
        Assert.True(DiagnosticContextState.Matches(before, null, before, null));
        Assert.False(DiagnosticContextState.Matches(before, null, before with { InterfaceName = "Other adapter" }, null));
    }

    [Fact]
    public void DeferredProgrammaticWanNotificationsDoNotLookLikeUserEdits()
    {
        var context = new DiagnosticContextState();
        Assert.False(context.AcceptWanEdit("203.0.113.1", updating: true));
        context.RecordWanText("203.0.113.1");
        Assert.False(context.AcceptWanEdit("203.0.113.1", updating: false));
        Assert.False(context.AcceptWanEdit("203.0.113.1", updating: false));
        Assert.True(context.AcceptWanEdit("203.0.113.2", updating: false));
        Assert.False(context.AcceptWanEdit("203.0.113.2", updating: false));
        Assert.True(context.AcceptWanEdit(string.Empty, updating: false));
        context.RecordWanText(string.Empty);
        Assert.False(context.AcceptWanEdit(string.Empty, updating: false));
    }

    [Fact]
    public async Task AwaitedNetworkChangeCannotOverrideAResetOrNewRun()
    {
        var context = new DiagnosticContextState();
        var revision = context.Revision;
        var stoppedRun = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<bool> IsStillCurrentAsync()
        {
            await stoppedRun.Task;
            return revision == context.Revision;
        }
        var refresh = IsStillCurrentAsync();
        context.Invalidate();
        stoppedRun.SetResult();
        Assert.False(await refresh);
    }
}
