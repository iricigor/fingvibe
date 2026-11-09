namespace FingVibe.App;

internal enum AsyncSurfaceState { Idle, Loading, Ready, Empty, Error }

/// <summary>
/// Owns the request lifecycle of one asynchronously loaded UI surface without depending on WinUI, so
/// cancellation, replacement, stale completion and Retry are tested deterministically in Core tests.
/// The view publishes <see cref="Status"/> through UI Automation for native tests and assistive technology.
/// </summary>
internal sealed class AsyncSurfaceSession : IDisposable
{
    private CancellationTokenSource? _cancellation;
    private bool _closed;

    internal sealed record Request(int Number, string Selection, CancellationToken CancellationToken);

    public Request? Current { get; private set; }
    public int Number { get; private set; }
    public string Selection { get; private set; } = "";
    public AsyncSurfaceState State { get; private set; }

    // Stable, parseable format: "<State> (request <Number>): <Selection>", or "Idle" when inactive.
    public string Status => State == AsyncSurfaceState.Idle ? "Idle" : $"{State} (request {Number}): {Selection}";

    public event EventHandler? StateChanged;

    public Request? Start(string selection)
    {
        if (_closed) return null;
        CancelCurrent();
        _cancellation = new CancellationTokenSource();
        Current = new Request(++Number, selection, _cancellation.Token);
        Selection = selection;
        SetState(AsyncSurfaceState.Loading);
        return Current;
    }

    public bool IsCurrent(Request request) =>
        !_closed && ReferenceEquals(Current, request) && !request.CancellationToken.IsCancellationRequested;

    /// <summary>
    /// Renders a current request's outcome, then reports it. A stale or cancelled request neither renders
    /// nor changes the state, and Ready is never reported before its content is rendered.
    /// </summary>
    public bool Complete(Request request, AsyncSurfaceState state, Action render)
    {
        if (state is not (AsyncSurfaceState.Ready or AsyncSurfaceState.Empty or AsyncSurfaceState.Error))
            throw new ArgumentOutOfRangeException(nameof(state), state, "Only Ready, Empty or Error complete a request.");
        if (!IsCurrent(request)) return false;
        render();
        if (!IsCurrent(request)) return false;
        _cancellation?.Dispose();
        _cancellation = null;
        Current = null;
        SetState(state);
        return true;
    }

    public void Cancel()
    {
        CancelCurrent();
        SetState(AsyncSurfaceState.Idle);
    }

    public void Dispose()
    {
        if (_closed) return;
        _closed = true;
        Cancel();
    }

    private void CancelCurrent()
    {
        _cancellation?.Cancel();
        _cancellation?.Dispose();
        _cancellation = null;
        Current = null;
    }

    private void SetState(AsyncSurfaceState state)
    {
        State = state;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }
}
