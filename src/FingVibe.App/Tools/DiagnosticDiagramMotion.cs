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
    private readonly List<Entry> _sequence = [];
    private double _elapsed;
    private double _pulseElapsed;
    private Entry? _request;
    private double _requestElapsed;
    private bool _finished;
    public int PassNumber { get; private set; } = 1;
    public int TotalPasses { get; private set; } = 1;

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
    public DiagnosticCheckpoint? RequestCheckpoint => Returning ? _request?.Checkpoint : null;
    public double RequestProgress => _request is null ? 0 : _requestElapsed / TravelTime(_request.Checkpoint);
    public bool ShowPulse => HasWork && (IsLocal || AtTarget && !Returning);
    public double Pulse => State is DiagnosticState.Running or DiagnosticState.Untested
        ? 0.5 - 0.5 * Math.Cos(_pulseElapsed * 2 * Math.PI / 0.9)
        : Math.Clamp((_elapsed - TravelSeconds) / PulseSeconds, 0, 1);
    public double EndpointSize => DotSize + (State is DiagnosticState.Running or DiagnosticState.Untested
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
        var entry = _sequence.FirstOrDefault(item => item.Checkpoint == checkpoint);
        if (state == DiagnosticState.Running)
        {
            if (entry is null)
            {
                entry = new(checkpoint);
                _sequence.Add(entry);
                _queue.Enqueue(entry);
            }
            entry.State = state;
        }
        else if (entry is not null)
        {
            entry.State = state;
        }
    }

    public void BeginRun(int totalPasses, IEnumerable<DiagnosticObservation> checkpoints)
    {
        if (totalPasses is < 3 or > 5) throw new ArgumentOutOfRangeException(nameof(totalPasses));
        Reset();
        TotalPasses = totalPasses;
        foreach (var observation in checkpoints.OrderBy(item => Order(item.Checkpoint)))
        {
            if (observation.State is DiagnosticState.Unavailable or DiagnosticState.Cancelled) continue;
            var entry = new Entry(observation.Checkpoint) { State = observation.State };
            _sequence.Add(entry);
            _queue.Enqueue(entry);
        }
    }

    public void CompleteRun(IEnumerable<DiagnosticObservation> observations)
    {
        foreach (var observation in observations.OrderBy(item => Order(item.Checkpoint)))
        {
            if (!_sequence.Any(item => item.Checkpoint == observation.Checkpoint))
            {
                if (!CanReplay(observation.State)) continue;
                Observe(observation.Checkpoint, DiagnosticState.Running);
            }
            Observe(observation.Checkpoint, observation.State);
        }
        _finished = true;
        if (!HasWork) StartNextPass();
    }

    public void Advance(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0)
            throw new ArgumentOutOfRangeException(nameof(seconds));
        if (!_queue.TryPeek(out var entry)) return;
        if (entry.State is DiagnosticState.Unavailable or DiagnosticState.Cancelled)
        {
            FinishEntry();
            return;
        }
        var previousElapsed = _elapsed;
        var travel = TravelSeconds;
        _pulseElapsed += seconds;
        _elapsed += seconds;
        if (entry.State is DiagnosticState.Running or DiagnosticState.Untested)
            _elapsed = Math.Min(_elapsed, TravelSeconds);
        if (Returning && _queue.Count > 1)
        {
            var next = _queue.ElementAt(1);
            if (next.State is not (DiagnosticState.Unavailable or DiagnosticState.Cancelled)
                && next.Checkpoint is not (DiagnosticCheckpoint.Loopback or DiagnosticCheckpoint.LocalAddress
                    or DiagnosticCheckpoint.ConfiguredDns))
            {
                _request = next;
                var returnStart = travel + PulseSeconds;
                var secondsReturning = Math.Clamp(_elapsed - returnStart, 0, travel)
                    - Math.Clamp(previousElapsed - returnStart, 0, travel);
                _requestElapsed = Math.Min(TravelTime(next.Checkpoint), _requestElapsed + secondsReturning);
            }
            else
            {
                _request = null;
                _requestElapsed = 0;
            }
        }
        if (entry.State is not (DiagnosticState.Running or DiagnosticState.Untested)
            && _elapsed >= TravelSeconds + PulseSeconds + (entry.State == DiagnosticState.Responded
            ? IsLocal ? 0 : TravelSeconds : FadeSeconds))
        {
            FinishEntry();
        }
    }

    private void FinishEntry()
    {
        _queue.Dequeue();
        _elapsed = _queue.TryPeek(out var next) && ReferenceEquals(next, _request) ? _requestElapsed : 0;
        _pulseElapsed = 0;
        _request = null;
        _requestElapsed = 0;
        if (!HasWork) StartNextPass();
    }

    public void Reset()
    {
        _queue.Clear();
        _sequence.Clear();
        _elapsed = 0;
        _pulseElapsed = 0;
        _request = null;
        _requestElapsed = 0;
        _finished = false;
        PassNumber = TotalPasses = 1;
    }

    private void StartNextPass()
    {
        if (!_finished || PassNumber >= TotalPasses) return;
        foreach (var entry in _sequence.Where(item => CanReplay(item.State)).OrderBy(item => Order(item.Checkpoint)))
            _queue.Enqueue(entry);
        if (HasWork) PassNumber++;
    }

    private static bool CanReplay(DiagnosticState state) =>
        state is DiagnosticState.Responded or DiagnosticState.Unanswered or DiagnosticState.Error;

    private static int Order(DiagnosticCheckpoint checkpoint) => checkpoint switch
    {
        DiagnosticCheckpoint.Loopback => 0,
        DiagnosticCheckpoint.LocalAddress => 1,
        DiagnosticCheckpoint.ConfiguredDns => 2,
        DiagnosticCheckpoint.Gateway => 3,
        DiagnosticCheckpoint.RouterWan => 4,
        DiagnosticCheckpoint.Hop2 => 5,
        DiagnosticCheckpoint.CloudflarePing => 6,
        DiagnosticCheckpoint.CloudflareDns => 7,
        DiagnosticCheckpoint.GooglePing => 8,
        DiagnosticCheckpoint.GoogleDns => 9,
        _ => throw new ArgumentOutOfRangeException(nameof(checkpoint))
    };

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
