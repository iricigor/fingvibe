namespace FingVibe.App;

internal sealed class SpeedGaugeMotion
{
    private double _target = -90;

    public double Angle { get; private set; } = -90;

    public void SetBandwidth(double bps)
    {
        if (!double.IsFinite(bps) || bps <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(bps));
        }

        // A fixed logarithmic scale avoids needle jumps caused by changing ranges.
        _target = -90 + 36 * Math.Clamp(Math.Log10(bps / 1_000_000), 0, 5);
    }

    public bool Advance(double seconds, bool animate)
    {
        if (!double.IsFinite(seconds) || seconds < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(seconds));
        }

        Angle = animate
            ? Angle + (_target - Angle) * (1 - Math.Exp(-Math.Min(seconds, 0.1) / 0.2))
            : _target;
        if (Math.Abs(_target - Angle) < 0.05)
        {
            Angle = _target;
            return false;
        }

        return true;
    }

    public void Reset()
    {
        Angle = _target = -90;
    }
}
