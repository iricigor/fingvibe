using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed class DiagnosticDiagramMotion
{
    internal const double DotSize = 8;
    internal const double Speed = 480;
    internal const double PulseSeconds = 0.4;
    internal const double FadeSeconds = 0.35;
    internal const int DotCount = 3;
    internal const double MinimumDelaySeconds = 0.2;
    internal const double MaximumDelaySeconds = 1.6;
    private static readonly Dictionary<DiagnosticCheckpoint, Span[]> Routes =
        Enum.GetValues<DiagnosticCheckpoint>().ToDictionary(checkpoint => checkpoint, CreateRoute);
    private readonly Dictionary<DiagnosticCheckpoint, DiagnosticState> _states = [];
    private readonly Random _random;
    private bool _enabled;

    public DiagnosticDiagramMotion(Random? random = null)
    {
        _random = random ?? Random.Shared;
        Dots = Array.AsReadOnly(Enumerable.Range(0, DotCount).Select(_ => new Dot()).ToArray());
    }

    public IReadOnlyList<Dot> Dots { get; }
    public bool HasWork => _enabled && _states.Values.Any(IsEligible);

    private readonly record struct Span(double X1, double Y1, double X2, double Y2, bool Visible)
    {
        public double Length => Math.Sqrt(Math.Pow(X2 - X1, 2) + Math.Pow(Y2 - Y1, 2));
    }

    internal sealed class Dot
    {
        private double _elapsed;
        private double _waitingElapsed;
        private DiagnosticState? _result;
        public DiagnosticCheckpoint? Checkpoint { get; private set; }
        public double DelaySeconds { get; private set; }
        public bool IsLocal => Checkpoint is DiagnosticCheckpoint.Loopback or DiagnosticCheckpoint.LocalAddress
            or DiagnosticCheckpoint.ConfiguredDns;
        public double TravelSeconds => Checkpoint is { } checkpoint ? TravelTime(checkpoint) : 0;
        public DiagnosticState State => _result ?? DiagnosticState.Running;
        public bool AtTarget => Checkpoint is not null && _elapsed >= TravelSeconds;
        public bool Returning => AtTarget && !IsLocal && State == DiagnosticState.Responded
            && _elapsed >= TravelSeconds + PulseSeconds;
        public bool ShowPulse => AtTarget && !Returning;
        public double Pulse => _result is null
            ? 0.5 - 0.5 * Math.Cos(_waitingElapsed * 2 * Math.PI / 0.9)
            : Math.Clamp((_elapsed - TravelSeconds) / PulseSeconds, 0, 1);
        public double EndpointSize => DotSize + (_result is null ? 4 * Pulse : 10 * Math.Sin(Math.PI * Pulse));
        public double Opacity => State is DiagnosticState.Unanswered or DiagnosticState.Error
            ? 1 - Math.Clamp((_elapsed - TravelSeconds - PulseSeconds) / FadeSeconds, 0, 1) : 1;
        public double Progress => Checkpoint is null ? 0 : !AtTarget ? _elapsed / TravelSeconds
            : Returning ? 1 - Math.Clamp((_elapsed - TravelSeconds - PulseSeconds) / TravelSeconds, 0, 1) : 1;

        internal void Schedule(Random random)
        {
            Reset();
            DelaySeconds = MinimumDelaySeconds + random.NextDouble() * (MaximumDelaySeconds - MinimumDelaySeconds);
        }

        internal void Reset()
        {
            Checkpoint = null;
            DelaySeconds = _elapsed = _waitingElapsed = 0;
            _result = null;
        }

        internal void Advance(double seconds, IReadOnlyDictionary<DiagnosticCheckpoint, DiagnosticState> states, Random random)
        {
            while (true)
            {
                if (Checkpoint is null)
                {
                    if (seconds < DelaySeconds)
                    {
                        DelaySeconds -= seconds;
                        return;
                    }
                    seconds -= DelaySeconds;
                    DelaySeconds = 0;
                    var candidates = states.Where(item => IsEligible(item.Value)).Select(item => item.Key).ToArray();
                    if (candidates.Length == 0) return;
                    Checkpoint = candidates[random.Next(candidates.Length)];
                }
                if (!states.TryGetValue(Checkpoint.Value, out var state) || !IsEligible(state))
                {
                    Schedule(random);
                    continue;
                }
                var travel = TravelSeconds;
                if (_elapsed < travel)
                {
                    var step = Math.Min(seconds, travel - _elapsed);
                    _elapsed += step;
                    seconds -= step;
                    if (_elapsed < travel) return;
                }
                if (_result is null)
                {
                    if (state is DiagnosticState.Running or DiagnosticState.Untested)
                    {
                        _waitingElapsed += seconds;
                        return;
                    }
                    _result = state;
                }
                var duration = travel + PulseSeconds
                    + (State == DiagnosticState.Responded ? IsLocal ? 0 : travel : FadeSeconds);
                var consumed = Math.Min(seconds, duration - _elapsed);
                _elapsed += consumed;
                seconds -= consumed;
                if (_elapsed < duration) return;
                Schedule(random);
            }
        }
    }

    public void Observe(DiagnosticCheckpoint checkpoint, DiagnosticState state)
    {
        if (_enabled) _states[checkpoint] = state;
    }

    public void BeginRun(IEnumerable<DiagnosticObservation> checkpoints)
    {
        Reset();
        _enabled = true;
        foreach (var observation in checkpoints) Observe(observation.Checkpoint, observation.State);
        foreach (var dot in Dots) dot.Schedule(_random);
    }

    public void CompleteRun(IEnumerable<DiagnosticObservation> observations)
    {
        if (!_enabled) return;
        _states.Clear();
        foreach (var observation in observations) Observe(observation.Checkpoint, observation.State);
        Advance(0);
    }

    public void Advance(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0)
            throw new ArgumentOutOfRangeException(nameof(seconds));
        if (!_enabled) return;
        foreach (var dot in Dots)
        {
            if (HasWork) dot.Advance(seconds, _states, _random);
            else dot.Reset();
        }
    }

    public void Reset()
    {
        _enabled = false;
        _states.Clear();
        foreach (var dot in Dots) dot.Reset();
    }

    private static bool IsEligible(DiagnosticState state) =>
        state is DiagnosticState.Untested or DiagnosticState.Running or DiagnosticState.Responded
            or DiagnosticState.Unanswered or DiagnosticState.Error;

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
