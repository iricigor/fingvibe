using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed class DiagnosticDiagramMotion
{
    internal const double DotSize = 8;
    internal const double Speed = 480;
    internal const double PulseSeconds = 0.4;
    internal const double FadeSeconds = 0.35;
    private static readonly Dictionary<DiagnosticCheckpoint, Span[]> Routes =
        Enum.GetValues<DiagnosticCheckpoint>().ToDictionary(checkpoint => checkpoint, CreateRoute);
    private readonly Queue<Entry> _queue = new();
    private double _elapsed;
    private double _pulseElapsed;

    private readonly record struct Span(double X1, double Y1, double X2, double Y2, bool Visible)
    {
        public double Length => Math.Sqrt(Math.Pow(X2 - X1, 2) + Math.Pow(Y2 - Y1, 2));
    }

    private sealed class Entry(DiagnosticCheckpoint checkpoint)
    {
        public DiagnosticCheckpoint Checkpoint { get; } = checkpoint;
        public DiagnosticState State { get; set; } = DiagnosticState.Running;
    }

    public DiagnosticCheckpoint? Checkpoint => _queue.TryPeek(out var entry) ? entry.Checkpoint : null;
    public bool HasWork => _queue.Count != 0;
    public bool IsLocal => Checkpoint is DiagnosticCheckpoint.Loopback or DiagnosticCheckpoint.LocalAddress
        or DiagnosticCheckpoint.ConfiguredDns;
    public double TravelSeconds => Checkpoint is { } checkpoint ? TravelTime(checkpoint) : 0;
    public DiagnosticState State => _elapsed < TravelSeconds || !_queue.TryPeek(out var entry)
        ? DiagnosticState.Running : entry.State;
    public bool AtTarget => HasWork && _elapsed >= TravelSeconds;
    public bool Returning => AtTarget && !IsLocal && State == DiagnosticState.Responded
        && _elapsed >= TravelSeconds + PulseSeconds;
    public bool ShowPulse => HasWork && (IsLocal || AtTarget && !Returning);
    public double Pulse => State == DiagnosticState.Running
        ? 0.5 - 0.5 * Math.Cos(_pulseElapsed * 2 * Math.PI / 0.9)
        : Math.Clamp((_elapsed - TravelSeconds) / PulseSeconds, 0, 1);
    public double EndpointSize => DotSize + (State == DiagnosticState.Running
        ? 4 * Pulse : 10 * Math.Sin(Math.PI * Pulse));
    public double Opacity => State is DiagnosticState.Unanswered or DiagnosticState.Error
        ? 1 - Math.Clamp((_elapsed - TravelSeconds - PulseSeconds) / FadeSeconds, 0, 1) : 1;
    public double Progress
    {
        get
        {
            if (!HasWork) return 0;
            return _elapsed < TravelSeconds ? _elapsed / TravelSeconds
                : State == DiagnosticState.Responded
                    ? 1 - Math.Clamp((_elapsed - TravelSeconds - PulseSeconds) / TravelSeconds, 0, 1)
                    : 1;
        }
    }

    public void Observe(DiagnosticCheckpoint checkpoint, DiagnosticState state)
    {
        var entry = _queue.FirstOrDefault(item => item.Checkpoint == checkpoint);
        if (state == DiagnosticState.Running)
        {
            if (entry is null) _queue.Enqueue(new(checkpoint));
        }
        else if (entry is not null)
        {
            entry.State = state;
        }
    }

    public void Advance(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0)
            throw new ArgumentOutOfRangeException(nameof(seconds));
        if (!_queue.TryPeek(out var entry)) return;
        _pulseElapsed += seconds;
        _elapsed += seconds;
        if (entry.State == DiagnosticState.Running)
            _elapsed = Math.Min(_elapsed, TravelSeconds);
        else if (_elapsed >= TravelSeconds + PulseSeconds + (entry.State == DiagnosticState.Responded
            ? IsLocal ? 0 : TravelSeconds : FadeSeconds))
        {
            _queue.Dequeue();
            _elapsed = 0;
            _pulseElapsed = 0;
        }
    }

    public void Reset()
    {
        _queue.Clear();
        _elapsed = 0;
        _pulseElapsed = 0;
    }

    internal static double TravelTime(DiagnosticCheckpoint checkpoint) => checkpoint is
        DiagnosticCheckpoint.Loopback or DiagnosticCheckpoint.LocalAddress or DiagnosticCheckpoint.ConfiguredDns
            ? 0.3 : Routes[checkpoint].Sum(span => span.Length) / Speed;

    internal static (double X, double Y, bool Visible) Position(DiagnosticCheckpoint checkpoint, double progress)
    {
        if (!double.IsFinite(progress) || progress < 0 || progress > 1)
            throw new ArgumentOutOfRangeException(nameof(progress));
        var spans = Routes[checkpoint];
        var distance = spans.Sum(span => span.Length) * progress;
        foreach (var span in spans)
        {
            var length = span.Length;
            if (distance <= length)
                return (span.X1 + (span.X2 - span.X1) * distance / length,
                    span.Y1 + (span.Y2 - span.Y1) * distance / length, span.Visible);
            distance -= length;
        }
        return (spans[^1].X2, spans[^1].Y2, spans[^1].Visible);
    }

    private static Span[] CreateRoute(DiagnosticCheckpoint checkpoint)
    {
        var spans = new List<(double X1, double Y1, double X2, double Y2)> { (165, 198, 355, 198) };
        if (checkpoint is DiagnosticCheckpoint.Hop2 or DiagnosticCheckpoint.CloudflarePing or DiagnosticCheckpoint.CloudflareDns
            or DiagnosticCheckpoint.GooglePing or DiagnosticCheckpoint.GoogleDns)
            spans.Add((435, 198, 625, 198));
        if (checkpoint is DiagnosticCheckpoint.CloudflarePing or DiagnosticCheckpoint.CloudflareDns
            or DiagnosticCheckpoint.GooglePing or DiagnosticCheckpoint.GoogleDns)
        {
            spans.Add((687, 198, 825, 198));
            if (checkpoint is DiagnosticCheckpoint.GooglePing or DiagnosticCheckpoint.GoogleDns)
                spans.Add((865, 198, 985, 198));
            else
            {
                spans.Add((865, 198, 885, 198));
                spans.Add((885, 198, 885, 138));
                Curve(885, 138, 885, 130, 893, 130);
                spans.Add((893, 130, 984, 130));
                Curve(984, 130, 992, 130, 992, 122);
                spans.Add((992, 122, 992, 55));
            }
        }
        var route = new List<Span>();
        foreach (var span in spans)
        {
            // Cross icon gaps at the same speed, but do not draw traffic over the icons.
            if (route.Count > 0 && (route[^1].X2 != span.X1 || route[^1].Y2 != span.Y1))
                route.Add(new(route[^1].X2, route[^1].Y2, span.X1, span.Y1, false));
            route.Add(new(span.X1, span.Y1, span.X2, span.Y2, true));
        }
        return route.ToArray();

        void Curve(double x1, double y1, double cx, double cy, double x2, double y2)
        {
            for (var index = 1; index <= 8; index++)
            {
                var t = index / 8d;
                var u = (index - 1) / 8d;
                spans.Add((At(x1, cx, x2, u), At(y1, cy, y2, u),
                    At(x1, cx, x2, t), At(y1, cy, y2, t)));
            }
        }

        static double At(double start, double control, double end, double t) =>
            (1 - t) * (1 - t) * start + 2 * (1 - t) * t * control + t * t * end;
    }
}
