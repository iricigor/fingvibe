using System.IO;
using System.Net;
using System.Text;
using System.Text.Json;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using SQLitePCL;

namespace Ex220Inspector;

public sealed record DatabaseNetwork(string NetworkId, string Subnet)
{
    public string Label => $"{Subnet} | {NetworkId}";
}

public sealed record DatabaseMatch(string Status, string Name, string Ip, string Details);

public sealed class FingVibeDatabaseComparison(string path)
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public Task<IReadOnlyList<DatabaseNetwork>> NetworksAsync(CancellationToken token) =>
        Task.Run<IReadOnlyList<DatabaseNetwork>>(() =>
        {
            using var connection = Open();
            using var deadline = new CancellationTokenSource(InventoryQueryService.ExecutionTimeout);
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
            using var interrupt = Interrupt(connection, stop.Token);
            using var transaction = connection.BeginTransaction(deferred: true);
            Validate(connection, transaction);
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                SELECT DISTINCT json_extract(o.value,'$.networkId'), json_extract(o.value,'$.subnet')
                FROM devices d, json_each(d.data,'$.observations') o
                WHERE json_extract(o.value,'$.networkId') IS NOT NULL
                UNION
                SELECT json_extract(data,'$.networkId'), json_extract(data,'$.subnet') FROM virtual_devices
                """;
            using var reader = command.ExecuteReader();
            var networks = new List<DatabaseNetwork>();
            while (reader.Read())
            {
                stop.Token.ThrowIfCancellationRequested();
                if (reader.IsDBNull(0) || reader.IsDBNull(1) || string.IsNullOrWhiteSpace(reader.GetString(0)))
                    throw new InvalidDataException("A saved network identity is incomplete.");
                networks.Add(new(reader.GetString(0), reader.GetString(1)));
            }
            return networks.OrderBy(item => item.Subnet).ThenBy(item => item.NetworkId).ToArray();
        }, token);

    public Task<IReadOnlyDictionary<string, DatabaseMatch>> CompareAsync(
        IReadOnlyList<ClientDisplay> clients, DatabaseNetwork network, CancellationToken token) =>
        Task.Run<IReadOnlyDictionary<string, DatabaseMatch>>(() =>
        {
            using var connection = Open();
            using var deadline = new CancellationTokenSource(InventoryQueryService.ExecutionTimeout);
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
            using var interrupt = Interrupt(connection, stop.Token);
            using var transaction = connection.BeginTransaction(deferred: true);
            Validate(connection, transaction);
            var result = new Dictionary<string, DatabaseMatch>(StringComparer.OrdinalIgnoreCase);
            foreach (var batch in clients.Chunk(20))
            {
                stop.Token.ThrowIfCancellationRequested();
                var keys = batch.Select(client => ClientCapture.NormalizeMac(client.Mac).Replace(":", "")).ToArray();
                using var command = connection.CreateCommand();
                command.Transaction = transaction;
                var parameters = string.Join(",", keys.Select((_, index) => $"$mac{index}"));
                for (var index = 0; index < keys.Length; index++)
                    command.Parameters.AddWithValue($"$mac{index}", keys[index]);
                command.Parameters.AddWithValue("$network", network.NetworkId);
                command.Parameters.AddWithValue("$subnet", network.Subnet);
                command.CommandText = $"""
                    SELECT 'device',id,data FROM devices WHERE id IN ({parameters})
                    UNION ALL SELECT 'name',id,data FROM names WHERE id IN ({parameters})
                    UNION ALL SELECT 'classification',id,data FROM classifications WHERE id IN ({parameters})
                    UNION ALL SELECT 'virtual',v.id,v.data FROM virtual_devices v
                    WHERE json_extract(v.data,'$.networkId')=$network AND json_extract(v.data,'$.subnet')=$subnet
                      AND EXISTS (SELECT 1 FROM json_each(v.data,'$.history') h
                                  WHERE json_extract(h.value,'$.mac') IN ({parameters}))
                    """;
                var devices = new Dictionary<string, InventoryDevice>();
                var names = new Dictionary<string, string>();
                var classifications = new Dictionary<string, DeviceClassificationOverride>();
                var slots = new List<PrivateVirtualDevice>();
                using (var reader = command.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        stop.Token.ThrowIfCancellationRequested();
                        var id = reader.GetString(1);
                        var json = reader.GetString(2);
                        if (Encoding.UTF8.GetByteCount(json) > InventoryQueryService.MaximumValueBytes)
                            throw new InvalidDataException("A saved database entity exceeds the supported 8 MiB limit.");
                        switch (reader.GetString(0))
                        {
                            case "device": devices.Add(id, Deserialize<InventoryDevice>(json)); break;
                            case "name": names.Add(id, Deserialize<string>(json)); break;
                            case "classification": classifications.Add(id, Deserialize<DeviceClassificationOverride>(json)); break;
                            case "virtual": slots.Add(Deserialize<PrivateVirtualDevice>(json)); break;
                        }
                    }
                }
                var data = new DeviceInventoryData(Guid.Empty, devices, names, classifications, new PeopleRoomsData())
                {
                    VirtualDevices = slots
                };
                foreach (var client in batch)
                {
                    stop.Token.ThrowIfCancellationRequested();
                    var key = ClientCapture.NormalizeMac(client.Mac).Replace(":", "");
                    result.Add(client.Mac, Match(client, key, data, network));
                }
            }
            return result;
        }, token);

    private SqliteConnection Open()
    {
        if (!File.Exists(path)) throw new FileNotFoundException("The FingVibe SQLite database was not found.", path);
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 5
        }.ToString());
        try
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY;";
            command.ExecuteNonQuery();
            return connection;
        }
        catch { connection.Dispose(); throw; }
    }

    private static void Validate(SqliteConnection connection, SqliteTransaction transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT id,version,revision FROM inventory";
        using var reader = command.ExecuteReader();
        if (!reader.Read() || reader.GetInt32(0) != 1 || reader.GetInt32(1) is not (2 or 3) ||
            !Guid.TryParse(reader.GetString(2), out var revision) || revision == Guid.Empty || reader.Read())
            throw new InvalidDataException("The saved inventory has an unsupported or incomplete format. Open it in FingVibe first.");
    }

    private static CancellationTokenRegistration Interrupt(SqliteConnection connection, CancellationToken token)
    {
        var handle = connection.Handle!;
        raw.sqlite3_progress_handler(handle, 1_000, _ => token.IsCancellationRequested ? 1 : 0, null);
        return token.Register(() => raw.sqlite3_interrupt(handle));
    }

    private static T Deserialize<T>(string json) => JsonSerializer.Deserialize<T>(json, Options)
        ?? throw new InvalidDataException("A saved database entity is empty.");

    private static DatabaseMatch Match(ClientDisplay client, string key, DeviceInventoryData data, DatabaseNetwork network)
    {
        if (!data.Devices.TryGetValue(key, out var saved))
            return new("Not in DB", "", "", "No saved MAC identity.");
        if (saved.Mac != key || saved.Imported is null || saved.Observations is null)
            throw new InvalidDataException("A saved MAC identity or observation record is invalid.");
        var scoped = saved with
        {
            Observations = saved.Observations.Where(item =>
                item.NetworkId == network.NetworkId && item.Subnet == network.Subnet).ToArray()
        };
        var observation = scoped.LatestObservation;
        var ip = observation?.Address ?? "";
        var hostname = !string.IsNullOrWhiteSpace(observation?.Hostname)
            ? observation.Hostname : saved.Imported.Hostname;
        var name = data.Names.GetValueOrDefault(key)?.Trim() ?? saved.Imported.Name ??
            (!string.IsNullOrWhiteSpace(hostname) ? hostname : ip);
        var scopedData = data with { Devices = new Dictionary<string, InventoryDevice>(data.Devices) { [key] = scoped } };
        if (PrivateVirtualDeviceAllocator.IsEligible(scopedData, scoped))
        {
            var slots = data.VirtualDevices.Where(slot => slot.History.Any(item => item.Mac == key)).ToArray();
            var active = slots.Where(slot => slot.LastActiveMac == key).ToArray();
            if (active.Length > 1)
                return new("Cannot compare", "", "", "Multiple virtual devices use this saved MAC.");
            if (active.Length == 1)
            {
                name = active[0].Name ?? active[0].AutomaticName;
                ip = active[0].LatestConnection.Observation.Address;
            }
            else if (slots.Length > 0)
                return new("Cannot compare", "", "", "This MAC is a historical virtual-device connection, not its current displayed MAC.");
        }
        if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(client.Name) ||
            string.IsNullOrWhiteSpace(ip) || string.IsNullOrWhiteSpace(client.Ip))
            return new("Cannot compare", name, ip, "A name or selected-network IP is unavailable; imported IPs are not a local baseline.");
        if (!IPAddress.TryParse(ip, out var dbIp) || !IPAddress.TryParse(client.Ip, out var routerIp))
            throw new InvalidDataException("A compared IP address is invalid.");
        var differences = new List<string>();
        if (!string.Equals(client.Name.Trim(), name.Trim(), StringComparison.OrdinalIgnoreCase))
            differences.Add("Name differs");
        if (!dbIp.Equals(routerIp)) differences.Add("IP differs");
        return new(differences.Count == 0 ? "Same in DB" : "Different in DB", name, dbIp.ToString(),
            differences.Count == 0 ? "Name and IP match." : string.Join("; ", differences));
    }
}
