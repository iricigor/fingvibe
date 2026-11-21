namespace FingVibe.App;

internal sealed class SpeedGaugeMotion
{
    public const double MinimumMbps = 1;
    public const double MaximumMbps = 10_000;
    private const double Decades = 4;
    private double _target = -90;

    public double Angle { get; private set; } = -90;

    // Position on the fixed 1 Mbps-10 Gbps logarithmic scale; readings outside it pin to the ends.
    public static double ScaleFraction(double mbps) =>
        mbps <= MinimumMbps ? 0 : Math.Clamp(Math.Log10(mbps / MinimumMbps) / Decades, 0, 1);

    // The arc is a semicircle drawn left to right, so a horizontal gradient offset follows the arc position.
    public static double ArcHorizontalOffset(double fraction) =>
        (1 - Math.Cos(Math.PI * Math.Clamp(fraction, 0, 1))) / 2;

    public void SetBandwidth(double bps)
    {
        if (!double.IsFinite(bps) || bps <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(bps));
        }

        // A fixed logarithmic scale avoids needle jumps caused by changing ranges.
        _target = -90 + 180 * ScaleFraction(bps / 1_000_000);
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
