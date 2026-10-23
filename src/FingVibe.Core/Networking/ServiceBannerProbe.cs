using System.Net;
using System.Net.Sockets;
using System.Text;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class ServiceBannerProbe
{
    private readonly TimeSpan _timeout;

    public ServiceBannerProbe(TimeSpan? timeout = null) =>
        _timeout = timeout ?? TimeSpan.FromMilliseconds(600);

    public async Task<IReadOnlyList<ServiceBanner>> ProbeAsync(
        IPAddress address, IReadOnlyList<OpenPort> ports, CancellationToken cancellationToken)
    {
        var probes = ports.Where(port => port.Port is 22 or 80 or 8080)
            .Select(port => ProbePortAsync(address, port.Port, port.Port == 22, cancellationToken));
        var results = await Task.WhenAll(probes).ConfigureAwait(false);
        return results.OfType<ServiceBanner>().ToArray();
    }

    internal async Task<ServiceBanner?> ProbePortAsync(
        IPAddress address, int port, bool ssh, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_timeout == TimeSpan.Zero)
        {
            return null;
        }

        using var client = new TcpClient(address.AddressFamily);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);
        try
        {
            await client.ConnectAsync(address, port, timeout.Token).ConfigureAwait(false);
            using var stream = client.GetStream();
            if (!ssh)
            {
                var request = Encoding.ASCII.GetBytes(
                    $"HEAD / HTTP/1.0\r\nHost: {address}\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(request, timeout.Token).ConfigureAwait(false);
            }

            var buffer = new byte[8192];
            var length = 0;
            while (length < buffer.Length)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(length), timeout.Token).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }

                length += read;
                var text = Encoding.ASCII.GetString(buffer, 0, length);
                var lineEnd = text.LastIndexOf('\n');
                if (ssh && lineEnd >= 0
                    && ParseBanner(text[..(lineEnd + 1)], true, port) is { } sshBanner)
                {
                    return sshBanner;
                }
                if (!ssh && (text.Contains("\r\n\r\n", StringComparison.Ordinal)
                        || text.Contains("\n\n", StringComparison.Ordinal)))
                {
                    return ParseBanner(text, ssh, port);
                }
            }

            return null;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception exception) when (exception is SocketException or IOException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return null;
        }
    }

    internal static ServiceBanner? ParseBanner(string response, bool ssh, int port)
    {
        var lines = response.Split('\n');
        if (ssh)
        {
            var line = lines.FirstOrDefault(value => value.StartsWith("SSH-2.0-", StringComparison.Ordinal)
                || value.StartsWith("SSH-1.99-", StringComparison.Ordinal));
            return line is null ? null : new ServiceBanner($"SSH banner (TCP {port})", Clean(line));
        }

        if (!response.StartsWith("HTTP/1.", StringComparison.Ordinal))
        {
            return null;
        }

        foreach (var line in lines.Skip(1))
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                break;
            }
            if (line.StartsWith("Server:", StringComparison.OrdinalIgnoreCase))
            {
                var value = Clean(line[7..]);
                return value.Length == 0 ? null : new ServiceBanner($"HTTP Server header (TCP {port})", value);
            }
        }

        return null;
    }

    private static string Clean(string value) =>
        new(value.Trim().Where(character => !char.IsControl(character)).Take(256).ToArray());
}
