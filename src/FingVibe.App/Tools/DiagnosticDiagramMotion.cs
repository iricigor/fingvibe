using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed class DiagnosticDiagramMotion
{
    internal const double DotSize = 6;
    internal const double OutboundSeconds = 0.4;
    internal const double PulseSeconds = 0.16;
    internal const double ReturnSeconds = 0.4;
    private static readonly Dictionary<DiagnosticCheckpoint, (double X1, double Y1, double X2, double Y2)[]> Routes =
        Enum.GetValues<DiagnosticCheckpoint>().ToDictionary(checkpoint => checkpoint, CreateRoute);
    private readonly Queue<Entry> _queue = new();
    private double _elapsed;
    private double _pulseElapsed;

    private sealed class Entry(DiagnosticCheckpoint checkpoint)
    {
        public DiagnosticCheckpoint Checkpoint { get; } = checkpoint;
        public DiagnosticState State { get; set; } = DiagnosticState.Running;
    }

    public DiagnosticCheckpoint? Checkpoint => _queue.TryPeek(out var entry) ? entry.Checkpoint : null;
    public bool HasWork => _queue.Count != 0;
    public bool IsLocal => Checkpoint is DiagnosticCheckpoint.Loopback or DiagnosticCheckpoint.LocalAddress
        or DiagnosticCheckpoint.ConfiguredDns;
    public DiagnosticState State => _elapsed < OutboundSeconds || !_queue.TryPeek(out var entry)
        ? DiagnosticState.Running : entry.State;
    public bool AtTarget => _elapsed >= OutboundSeconds;
    public bool ShowPulse => IsLocal || AtTarget && (State != DiagnosticState.Responded
        || _elapsed <= OutboundSeconds + PulseSeconds);
    public double Pulse => State == DiagnosticState.Running
        ? 0.5 - 0.5 * Math.Cos(_pulseElapsed * 2 * Math.PI / 0.9)
        : Math.Clamp((_elapsed - OutboundSeconds) / PulseSeconds, 0, 1);
    public double Opacity => State is DiagnosticState.Unanswered or DiagnosticState.Error
        ? 1 - Math.Clamp((_elapsed - OutboundSeconds) / ReturnSeconds, 0, 1) : 1;
    public double Progress
    {
        get
        {
            var value = _elapsed < OutboundSeconds ? _elapsed / OutboundSeconds
                : State == DiagnosticState.Responded
                    ? 1 - Math.Clamp((_elapsed - OutboundSeconds - PulseSeconds) / ReturnSeconds, 0, 1)
                    : 1;
            return value * value * (3 - 2 * value);
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
        _elapsed += Math.Min(seconds, 0.1);
        if (entry.State == DiagnosticState.Running)
            _elapsed = Math.Min(_elapsed, OutboundSeconds);
        else if (_elapsed >= OutboundSeconds + (entry.State == DiagnosticState.Responded
            ? PulseSeconds + ReturnSeconds : ReturnSeconds))
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

    // Only the drawn connector spans participate: icons and logical port gaps are skipped.
    internal static (double X, double Y) Position(DiagnosticCheckpoint checkpoint, double progress)
    {
        if (!double.IsFinite(progress) || progress < 0 || progress > 1)
            throw new ArgumentOutOfRangeException(nameof(progress));
        var spans = Routes[checkpoint];
        var distance = spans.Sum(Length) * progress;
        foreach (var span in spans)
        {
            var length = Length(span);
            if (distance <= length)
                return (span.X1 + (span.X2 - span.X1) * distance / length,
                    span.Y1 + (span.Y2 - span.Y1) * distance / length);
            distance -= length;
        }
        return (spans[^1].X2, spans[^1].Y2);
    }

    private static double Length((double X1, double Y1, double X2, double Y2) span) =>
        Math.Sqrt(Math.Pow(span.X2 - span.X1, 2) + Math.Pow(span.Y2 - span.Y1, 2));

    private static (double X1, double Y1, double X2, double Y2)[] CreateRoute(DiagnosticCheckpoint checkpoint)
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
        return spans.ToArray();

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
