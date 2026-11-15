using System.IO;

namespace Ex220Inspector;

public sealed record RouterTablePage(RouterClient[] Clients, int PageNumber, int PageCount, string Title);
public sealed record InspectorCaptureProgress(ClientSource Source, int Page, int Pages);

public interface IInspectorCaptureBrowser
{
    Task EnsureSignedInAsync(CancellationToken cancellationToken);
    Task NavigateAsync(ClientSource source, CancellationToken cancellationToken);
    Task<RouterTablePage> ReadPageAsync(ClientSource source, CancellationToken cancellationToken);
    Task GoToPageAsync(ClientSource source, int page, CancellationToken cancellationToken);
}

public static class InspectorCaptureRunner
{
    public static Task<ClientCapture> CaptureAsync(IInspectorCaptureBrowser browser,
        IProgress<InspectorCaptureProgress>? progress, CancellationToken cancellationToken) =>
        CaptureSourcesAsync(browser, Enum.GetValues<ClientSource>(), progress, cancellationToken);

    public static Task<ClientCapture> CaptureSourceAsync(IInspectorCaptureBrowser browser, ClientSource source,
        IProgress<InspectorCaptureProgress>? progress, CancellationToken cancellationToken) =>
        CaptureSourcesAsync(browser, [source], progress, cancellationToken);

    private static async Task<ClientCapture> CaptureSourcesAsync(IInspectorCaptureBrowser browser,
        IEnumerable<ClientSource> sources, IProgress<InspectorCaptureProgress>? progress,
        CancellationToken cancellationToken)
    {
        var capture = new ClientCapture();
        await browser.EnsureSignedInAsync(cancellationToken);
        foreach (var source in sources)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await browser.NavigateAsync(source, cancellationToken);
            await browser.GoToPageAsync(source, 1, cancellationToken);
            var first = await browser.ReadPageAsync(source, cancellationToken);
            if (first.PageCount is < 1 or > 1_000)
                throw new InvalidDataException("The router page count is missing or exceeds the 1,000-page safety limit.");
            var seen = new Dictionary<string, RouterClient>(StringComparer.OrdinalIgnoreCase);
            for (var page = 1; page <= first.PageCount; page++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (page > 1) await browser.GoToPageAsync(source, page, cancellationToken);
                var current = page == 1 ? first : await browser.ReadPageAsync(source, cancellationToken);
                if (current.PageNumber != page || current.PageCount != first.PageCount ||
                    current.Title != first.Title || string.IsNullOrWhiteSpace(current.Title))
                    throw new InvalidDataException("The selected router page, title or page count changed during capture.");
                if (current.PageCount > 1 && current.Clients.Length == 0)
                    throw new InvalidDataException("A paginated table unexpectedly returned an empty page.");
                foreach (var client in current.Clients)
                {
                    var mac = ClientCapture.NormalizeMac(client.Mac);
                    if (seen.ContainsKey(mac))
                        throw new InvalidDataException("A MAC appeared on multiple pages. The table may have changed during capture; retry.");
                    seen.Add(mac, client);
                }
                capture.Add(source, current.Clients);
                progress?.Report(new(source, page, first.PageCount));
            }
        }
        cancellationToken.ThrowIfCancellationRequested();
        return capture;
    }
}
