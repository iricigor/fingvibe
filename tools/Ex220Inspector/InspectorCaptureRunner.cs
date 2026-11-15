using System.IO;

namespace Ex220Inspector;

public sealed record RouterTablePage(RouterClient[] Clients, int PageNumber, int PageCount, string Title);
public sealed record InspectorCaptureProgress(ClientSource Source, int Page, int Pages,
    int Attempt = 1, int MaximumAttempts = 1, string? Failure = null);
public sealed record InspectorCaptureRetryPolicy(int MaximumAttempts, TimeSpan Delay);
public sealed class InspectorTransientCaptureException(string message, Exception? inner = null)
    : IOException(message, inner);

public sealed class InspectorClickPacer(TimeProvider? timeProvider = null)
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private long? _lastClick;

    public TimeSpan Delay { get; set; } = TimeSpan.FromMilliseconds(500);

    public async Task WaitAsync(CancellationToken token)
    {
        await _gate.WaitAsync(token);
        try
        {
            if (_lastClick is { } last)
            {
                var remaining = Delay - _time.GetElapsedTime(last);
                if (remaining > TimeSpan.Zero) await Task.Delay(remaining, _time, token);
            }
            token.ThrowIfCancellationRequested();
            _lastClick = _time.GetTimestamp();
        }
        finally { _gate.Release(); }
    }
}

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
        IProgress<InspectorCaptureProgress>? progress, CancellationToken cancellationToken,
        InspectorCaptureRetryPolicy? retryPolicy = null) =>
        CaptureSourcesAsync(browser, Enum.GetValues<ClientSource>(), progress, cancellationToken, retryPolicy);

    public static Task<ClientCapture> CaptureSourceAsync(IInspectorCaptureBrowser browser, ClientSource source,
        IProgress<InspectorCaptureProgress>? progress, CancellationToken cancellationToken,
        InspectorCaptureRetryPolicy? retryPolicy = null) =>
        CaptureSourcesAsync(browser, [source], progress, cancellationToken, retryPolicy);

    private static async Task<ClientCapture> CaptureSourcesAsync(IInspectorCaptureBrowser browser,
        IEnumerable<ClientSource> sources, IProgress<InspectorCaptureProgress>? progress,
        CancellationToken cancellationToken, InspectorCaptureRetryPolicy? retryPolicy)
    {
        var policy = retryPolicy ?? new InspectorCaptureRetryPolicy(1, TimeSpan.Zero);
        if (policy.MaximumAttempts is < 1 or > 5 || policy.Delay < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(retryPolicy), "Use one to five attempts and a nonnegative retry delay.");
        var capture = new ClientCapture();
        foreach (var source in sources)
        {
            for (var attempt = 1; attempt <= policy.MaximumAttempts; attempt++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                progress?.Report(new(source, 0, 0, attempt, policy.MaximumAttempts));
                try
                {
                    var completed = await CaptureOnceAsync(browser, source, progress,
                        cancellationToken, attempt, policy.MaximumAttempts);
                    capture.ReplaceSource(source, completed);
                    break;
                }
                catch (Exception exception) when (exception is TimeoutException or InspectorTransientCaptureException)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (attempt == policy.MaximumAttempts)
                        throw new InspectorTransientCaptureException(
                            $"{source} capture failed after {attempt} attempt(s): {exception.Message}", exception);
                    progress?.Report(new(source, 0, 0, attempt, policy.MaximumAttempts, exception.Message));
                    await Task.Delay(policy.Delay, cancellationToken);
                }
            }
        }
        cancellationToken.ThrowIfCancellationRequested();
        return capture;
    }

    private static async Task<ClientCapture> CaptureOnceAsync(IInspectorCaptureBrowser browser,
        ClientSource source, IProgress<InspectorCaptureProgress>? progress,
        CancellationToken token, int attempt, int maximumAttempts)
    {
        var capture = new ClientCapture();
        await browser.EnsureSignedInAsync(token);
        await browser.NavigateAsync(source, token);
        await browser.GoToPageAsync(source, 1, token);
        var first = await browser.ReadPageAsync(source, token);
        if (first.PageCount is < 1 or > 1_000)
            throw new InvalidDataException("The router page count is missing or exceeds the 1,000-page safety limit.");
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pages = new HashSet<string>(StringComparer.Ordinal);
        for (var page = 1; page <= first.PageCount; page++)
        {
            token.ThrowIfCancellationRequested();
            if (page > 1) await browser.GoToPageAsync(source, page, token);
            var current = page == 1 ? first : await browser.ReadPageAsync(source, token);
            if (string.IsNullOrWhiteSpace(current.Title))
                throw new InvalidDataException("The client table title is missing.");
            if (current.PageNumber != page || current.PageCount != first.PageCount || current.Title != first.Title)
                throw new InspectorTransientCaptureException("The selected router page, title or page count changed during capture.");
            if (current.PageCount > 1 && current.Clients.Length == 0)
                throw new InspectorTransientCaptureException("A paginated table unexpectedly returned an empty page.");
            var signature = System.Text.Json.JsonSerializer.Serialize(current.Clients
                .Select(client => client with { Mac = ClientCapture.NormalizeMac(client.Mac) })
                .OrderBy(client => client.Mac).ThenBy(client => client.Ip).ThenBy(client => client.Name));
            if (!pages.Add(signature))
                throw new InspectorTransientCaptureException("A router page repeated the same client contents.");
            foreach (var client in current.Clients)
                if (!seen.Add(ClientCapture.NormalizeMac(client.Mac)) && source != ClientSource.Arp)
                    throw new InspectorTransientCaptureException("A MAC appeared on multiple client pages; the table may have changed.");
            capture.Add(source, current.Clients);
            progress?.Report(new(source, page, first.PageCount, attempt, maximumAttempts));
        }
        token.ThrowIfCancellationRequested();
        return capture;
    }
}
