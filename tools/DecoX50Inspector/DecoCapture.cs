using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Ex220Inspector;

namespace DecoX50Inspector;

public static class DecoFailurePolicy
{
    public static bool IsBrowserError(Exception exception) =>
        exception is InvalidDataException or COMException or InvalidOperationException
            or JsonException or TimeoutException or ArgumentException;
}

public sealed record DecoClient(string Name, string Mac, string Ip, string Connection);
public sealed record DecoProbe(string State, string Error, int ClientCount, DecoClient[] Clients);

public sealed record DecoSnapshot(int SchemaVersion, string Router, string SourceUrl,
    DateTimeOffset CapturedAtUtc, int ClientCount, IReadOnlyList<DecoClient> Clients)
{
    public static DecoSnapshot Create(IEnumerable<DecoClient> clients, DateTimeOffset capturedAt)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var normalized = clients.Select(client =>
        {
            var mac = ClientCapture.NormalizeMac(client.Mac);
            if (!seen.Add(mac)) throw new InvalidDataException("The Deco list contains a duplicate MAC.");
            var ip = client.Ip.Trim();
            if (ip.Length > 0 && (!IPAddress.TryParse(ip, out var address) ||
                address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork ||
                address.Equals(IPAddress.Any)))
                throw new InvalidDataException("A Deco client has an invalid IPv4 address.");
            if (client.Connection is not ("Wired" or "Wireless (2.4G)" or "Wireless (5G)" or
                "Wireless (6G)" or "Wireless (MLO)" or "Zigbee" or "Bluetooth" or "Unknown"))
                throw new InvalidDataException("A Deco client has an unsupported connection type.");
            return client with { Name = client.Name.Trim(), Mac = mac, Ip = ip };
        }).OrderBy(client => client.Mac, StringComparer.Ordinal).ToArray();
        return new(1, "TP-Link Deco X50", DecoRouterPolicy.SourceUrl, capturedAt.ToUniversalTime(),
            normalized.Length, Array.AsReadOnly(normalized));
    }

    public IReadOnlyList<ClientDisplay> ComparisonRows() => Clients.Select(client =>
        new ClientDisplay(client.Name, client.Mac, client.Ip, client.Connection,
            "Deco Connected Clients", "Not collected")).ToArray();

    public async Task ExportAsync(string path, CancellationToken token)
    {
        var fullPath = Path.GetFullPath(path);
        var temporary = fullPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 4096, FileOptions.Asynchronous))
                await JsonSerializer.SerializeAsync(stream, this,
                    new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }, token);
            token.ThrowIfCancellationRequested();
            File.Move(temporary, fullPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}

public static class DecoRouterPolicy
{
    public const string SourceUrl = "https://192.168.0.100/webpages/index.html#networkMap";

    public static bool IsRouter(string value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == Uri.UriSchemeHttps && uri.Host == "192.168.0.100" &&
        uri.Port == 443 && uri.UserInfo.Length == 0;

    public static string Fingerprint(string pem)
    {
        using var certificate = X509Certificate2.CreateFromPem(pem);
        return certificate.GetCertHashString(HashAlgorithmName.SHA256);
    }

    public static bool IsTrusted(string uri, string fingerprint, string? approved) =>
        IsRouter(uri) && approved is not null &&
        string.Equals(fingerprint, approved, StringComparison.Ordinal);
}

public static class DecoCaptureRunner
{
    public static async Task<DecoSnapshot> CaptureAsync(
        Func<CancellationToken, Task> prepare,
        Func<CancellationToken, Task<DecoProbe>> read,
        Action<int, string> progress, CancellationToken token,
        TimeProvider? timeProvider = null)
    {
        var time = timeProvider ?? TimeProvider.System;
        for (var attempt = 1; attempt <= 5; attempt++)
        {
            token.ThrowIfCancellationRequested();
            progress(attempt, "Opening Connected Clients (All Decos)...");
            try
            {
                await prepare(token);
                var start = time.GetTimestamp();
                DecoSnapshot? previous = null;
                while (time.GetElapsedTime(start) < TimeSpan.FromSeconds(15))
                {
                    token.ThrowIfCancellationRequested();
                    var probe = await read(token);
                    token.ThrowIfCancellationRequested();
                    if (probe.Error.Length > 0) throw new InvalidDataException(probe.Error);
                    if (probe.State == "Login")
                        throw new InspectorTransientCaptureException("The Deco session expired.");
                    if (probe.State == "Ready")
                    {
                        var current = DecoSnapshot.Create(probe.Clients, time.GetUtcNow());
                        if (probe.ClientCount != current.ClientCount)
                            throw new InvalidDataException("The Deco count does not match the extracted client list.");
                        if (previous is not null && previous.Clients.SequenceEqual(current.Clients))
                            return current;
                        previous = current;
                    }
                    else previous = null;
                    progress(attempt, "Waiting for two complete, consistent client observations...");
                    await Task.Delay(TimeSpan.FromMilliseconds(300), time, token);
                }
                throw new TimeoutException("The complete Deco list did not settle within 15 seconds.");
            }
            catch (Exception exception) when (exception is TimeoutException or InspectorTransientCaptureException)
            {
                token.ThrowIfCancellationRequested();
                if (attempt == 5)
                    throw new InspectorTransientCaptureException(
                        $"Deco capture failed after five attempts: {exception.Message}", exception);
                progress(attempt, $"{exception.Message} Retrying Clients navigation in two seconds...");
                await Task.Delay(TimeSpan.FromSeconds(2), time, token);
            }

        }
        throw new InvalidOperationException("The capture finished without a snapshot.");
    }
}

public static class DecoClientNavigation
{
    public static async Task OpenAsync(
        Func<string, CancellationToken, Task<bool>> click,
        Func<CancellationToken, Task<bool>> visible,
        CancellationToken token, TimeProvider? timeProvider = null)
    {
        var time = timeProvider ?? TimeProvider.System;
        token.ThrowIfCancellationRequested();
        if (!await click("clients", token))
            throw new InspectorTransientCaptureException("The Clients map control is not ready.");
        if (await WaitForGridAsync(TimeSpan.FromSeconds(3))) return;
        if (!await click("internet", token))
            throw new InspectorTransientCaptureException("The Internet fallback control is not ready.");
        token.ThrowIfCancellationRequested();
        if (!await click("clients", token))
            throw new InspectorTransientCaptureException("Internet -> Clients navigation controls are not ready.");
        if (!await WaitForGridAsync(TimeSpan.FromSeconds(15)))
            throw new TimeoutException("Clients did not open after direct and Internet -> Clients navigation.");

        async Task<bool> WaitForGridAsync(TimeSpan timeout)
        {
            var start = time.GetTimestamp();
            while (time.GetElapsedTime(start) < timeout)
            {
                token.ThrowIfCancellationRequested();
                var ready = await visible(token);
                token.ThrowIfCancellationRequested();
                if (ready) return true;
                await Task.Delay(TimeSpan.FromMilliseconds(300), time, token);
            }
            return false;
        }
    }
}
