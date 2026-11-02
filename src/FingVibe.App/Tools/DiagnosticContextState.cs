using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed class DiagnosticContextState
{
    private string _wanText = string.Empty;
    public long Revision { get; private set; }

    public void Invalidate() => Revision++;

    public void RecordWanText(string text) => _wanText = text;

    public bool AcceptWanEdit(string text, bool updating)
    {
        if (updating || string.Equals(text, _wanText, StringComparison.Ordinal)) return false;
        _wanText = text;
        return true;
    }

    public static bool Matches(LanNetwork? before, Guid? beforeProfile, LanNetwork? after, Guid? afterProfile)
    {
        if (before is null || after is null) return before is null && after is null;
        return SameAdapter(before, after)
            && before.LocalAddress.Equals(after.LocalAddress)
            && before.NetworkAddress.Equals(after.NetworkAddress)
            && before.PrefixLength == after.PrefixLength
            && before.HasGateway == after.HasGateway
            && Equals(before.GatewayAddress, after.GatewayAddress)
            && beforeProfile == afterProfile;
    }

    public static LanNetwork? Select(IReadOnlyList<LanNetwork> networks, LanNetwork? preferred) =>
        networks.FirstOrDefault(item => preferred is not null && SameAdapter(item, preferred)
            && item.LocalAddress.Equals(preferred.LocalAddress))
        ?? networks.FirstOrDefault(item => preferred is not null && SameAdapter(item, preferred))
        ?? networks.FirstOrDefault();

    private static bool SameAdapter(LanNetwork before, LanNetwork after) =>
        !string.IsNullOrWhiteSpace(before.InterfaceId) || !string.IsNullOrWhiteSpace(after.InterfaceId)
            ? string.Equals(before.InterfaceId, after.InterfaceId, StringComparison.OrdinalIgnoreCase)
            : string.Equals(before.InterfaceName, after.InterfaceName, StringComparison.Ordinal);
}
