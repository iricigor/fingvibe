namespace FingVibe.App;

internal sealed class IspLogoSession : IDisposable
{
    private Uri? _uri;
    private CancellationTokenSource? _cancellation;
    private bool _closed;

    internal sealed record Request(Uri Uri, CancellationToken CancellationToken);

    public Request? Current { get; private set; }

    public static Uri? CreateUri(string? ispName, string? publishableKey)
    {
        if (string.IsNullOrWhiteSpace(ispName) || string.IsNullOrWhiteSpace(publishableKey))
        {
            return null;
        }

        if (!publishableKey.StartsWith("pk_", StringComparison.Ordinal) || publishableKey.Length <= 3)
        {
            throw new ArgumentException("ISP logos require a Logo.dev publishable key.", nameof(publishableKey));
        }

        return new Uri($"https://img.logo.dev/name/{Uri.EscapeDataString(ispName)}"
            + $"?token={Uri.EscapeDataString(publishableKey)}&format=png&size=128&fallback=404");
    }

    public bool Update(string? ispName, string? publishableKey)
    {
        if (_closed)
        {
            return false;
        }

        var uri = CreateUri(ispName, publishableKey);
        if (_uri == uri)
        {
            return false;
        }

        CancelCurrent();
        _uri = uri;
        if (uri is not null)
        {
            _cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            Current = new Request(uri, _cancellation.Token);
        }

        return true;
    }

    public bool IsCurrent(Request request) => !_closed && ReferenceEquals(Current, request);

    public void Dispose()
    {
        _closed = true;
        CancelCurrent();
    }

    private void CancelCurrent()
    {
        _cancellation?.Cancel();
        _cancellation?.Dispose();
        _cancellation = null;
        Current = null;
    }
}
