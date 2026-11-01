using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal static class WindowsNetworkProfileIdentity
{
    [SupportedOSPlatform("windows")]
    public static Guid GetNetworkId(LanNetwork network)
    {
        if (!Guid.TryParse(network.InterfaceId, out var adapterId))
            throw new InvalidOperationException("The selected adapter has no Windows adapter identifier; network-scoped persistence is unavailable.");
        var type = Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B"), throwOnError: true)
            ?? throw new InvalidOperationException("Windows Network List Manager is unavailable.");
        var manager = (INetworkListManager)(Activator.CreateInstance(type)
            ?? throw new InvalidOperationException("Windows Network List Manager could not be created."));
        try
        {
            var connections = manager.GetNetworkConnections();
            try
            {
                var profiles = new List<(Guid AdapterId, Guid NetworkId)>();
                while (true)
                {
                    var result = connections.Next(1, out var connection, out var fetched);
                    Marshal.ThrowExceptionForHR(result);
                    if (fetched == 0) break;
                    if (connection is null) throw new InvalidOperationException("Windows returned an empty network connection.");
                    try
                    {
                        if (!connection.IsConnected()) continue;
                        var profile = connection.GetNetwork();
                        try { profiles.Add((connection.GetAdapterId(), profile.GetNetworkId())); }
                        finally { Marshal.ReleaseComObject(profile); }
                    }
                    finally { Marshal.ReleaseComObject(connection); }
                }
                return FindNetworkId(adapterId, profiles);
            }

            finally { Marshal.ReleaseComObject(connections); }
        }
        finally { Marshal.ReleaseComObject(manager); }
    }

    internal static Guid FindNetworkId(Guid adapterId, IEnumerable<(Guid AdapterId, Guid NetworkId)> connectedProfiles)
    {
        var identities = connectedProfiles.Where(profile => profile.AdapterId == adapterId)
            .Select(profile => profile.NetworkId).Distinct().ToArray();
        if (adapterId == Guid.Empty || identities.Length != 1 || identities[0] == Guid.Empty)
            throw new InvalidOperationException("Windows cannot uniquely identify this adapter's network. Network-scoped persistence is unavailable; no other network's value will be reused.");
        return identities[0];
    }

    // Declare the native vtable prefixes through the methods used here. GUID return
    // values require typed COM interop rather than IDispatch/dynamic automation.
    [ComImport, Guid("DCB00000-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetworkListManager
    {
        [return: MarshalAs(UnmanagedType.Interface)] object GetNetworks(int flags);
        INetwork GetNetwork(Guid id);
        IEnumNetworkConnections GetNetworkConnections();
    }

    [ComImport, Guid("DCB00006-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface IEnumNetworkConnections
    {
        [return: MarshalAs(UnmanagedType.Interface)] object GetNewEnum();
        [PreserveSig] int Next(uint count, [MarshalAs(UnmanagedType.Interface)] out INetworkConnection? connection, out uint fetched);
    }

    [ComImport, Guid("DCB00005-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetworkConnection
    {
        INetwork GetNetwork();
        [return: MarshalAs(UnmanagedType.VariantBool)] bool IsConnectedToInternet();
        [return: MarshalAs(UnmanagedType.VariantBool)] bool IsConnected();
        int GetConnectivity();
        Guid GetConnectionId();
        Guid GetAdapterId();
    }

    [ComImport, Guid("DCB00002-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetwork
    {
        [return: MarshalAs(UnmanagedType.BStr)] string GetName();
        void SetName([MarshalAs(UnmanagedType.BStr)] string name);
        [return: MarshalAs(UnmanagedType.BStr)] string GetDescription();
        void SetDescription([MarshalAs(UnmanagedType.BStr)] string description);
        Guid GetNetworkId();
    }
}
