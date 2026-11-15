using System.IO;
using System.Net;
using System.Text.RegularExpressions;

namespace Ex220Inspector;

public enum ClientSource { Clients, Wired, Arp }

public sealed record RouterClient(string Name, string Mac, string Ip);
public sealed record ClientDisplay(string Name, string Mac, string Ip, string Connection,
    string Sources, string ArpComparison, string DbComparison = "DB not loaded",
    string DbName = "", string DbIp = "", string DbDetails = "");

public sealed class ClientCapture
{
    private readonly Dictionary<ClientSource, Dictionary<string, RouterClient>> _captures = [];

    public void Add(ClientSource source, IEnumerable<RouterClient> clients)
    {
        var normalized = clients.Select(Normalize).ToArray();
        if (!_captures.TryGetValue(source, out var table))
            _captures[source] = table = new(StringComparer.OrdinalIgnoreCase);
        foreach (var client in normalized) table[client.Mac] = client;
    }

    public bool Has(ClientSource source) => _captures.ContainsKey(source);
    public int Count(ClientSource source) => _captures.GetValueOrDefault(source)?.Count ?? 0;
    public void Clear() => _captures.Clear();

    public void ReplaceSource(ClientSource source, ClientCapture completed)
    {
        if (!completed._captures.TryGetValue(source, out var table))
            throw new InvalidOperationException("The replacement source has not been captured.");
        _captures[source] = new(table, StringComparer.OrdinalIgnoreCase);
    }

    public IReadOnlyList<ClientDisplay> Rows(bool wiredComplete)
    {
        var all = _captures.Values.SelectMany(table => table.Keys)
            .Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase);
        return all.Select(mac =>
        {
            var client = _captures.GetValueOrDefault(ClientSource.Clients)?.GetValueOrDefault(mac);
            var wired = _captures.GetValueOrDefault(ClientSource.Wired)?.GetValueOrDefault(mac);
            var arp = _captures.GetValueOrDefault(ClientSource.Arp)?.GetValueOrDefault(mac);
            var preferred = client ?? wired ?? arp!;
            var sources = new List<string>();
            if (client is not null) sources.Add("Client List");
            if (wired is not null) sources.Add("Wired Clients");
            if (arp is not null) sources.Add("ARP");
            var connection = wired is not null ? "Wired"
                : client is not null && Has(ClientSource.Wired) && wiredComplete ? "Wireless" : "Unknown";
            var comparison = arp is null ? "No captured ARP entry"
                : client is null ? "No Client List entry"
                : client.Ip.Length == 0 || arp.Ip.Length == 0 ? "IP unavailable"
                : client.Ip == arp.Ip ? "Same IP" : $"Different IP: ARP {arp.Ip}";
            return new ClientDisplay(preferred.Name, mac, preferred.Ip, connection,
                string.Join(", ", sources), comparison);
        }).ToArray();
    }

    private static RouterClient Normalize(RouterClient client)
    {
        var mac = NormalizeMac(client.Mac);
        var ip = client.Ip.Trim();
        if (ip.Length > 0 && (!IPAddress.TryParse(ip, out var address)
            || address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork))
            throw new InvalidDataException("A captured row has an invalid IPv4 address.");
        return client with
        {
            Name = client.Name.Trim(),
            Mac = mac,
            Ip = ip
        };
    }

    public static string NormalizeMac(string value)
    {
        var mac = value.Replace(":", "").Replace("-", "").ToUpperInvariant();
        if (!Regex.IsMatch(mac, "^[0-9A-F]{12}$"))
            throw new InvalidDataException("A captured row has an invalid MAC address.");
        return string.Join(":", Enumerable.Range(0, 6).Select(index => mac.Substring(index * 2, 2)));
    }
}
