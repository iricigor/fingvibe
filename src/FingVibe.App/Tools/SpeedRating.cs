using System.Globalization;

namespace FingVibe.App;

public enum SpeedDirection
{
    Download,
    Upload
}

public enum SpeedRatingLevel
{
    Slow,
    Fair,
    Good
}

// Fixed speed-quality bands from the US FCC 100/20 Mbps broadband benchmark and its earlier 25 Mbps download floor.
internal static class SpeedRating
{
    public const double DownloadFairMbps = 25;
    public const double DownloadGoodMbps = 100;
    public const double UploadFairMbps = 5;
    public const double UploadGoodMbps = 20;

    public static (double Fair, double Good) Thresholds(SpeedDirection direction) => direction == SpeedDirection.Upload
        ? (UploadFairMbps, UploadGoodMbps)
        : (DownloadFairMbps, DownloadGoodMbps);

    public static SpeedRatingLevel Rate(SpeedDirection direction, double mbps)
    {
        if (!double.IsFinite(mbps) || mbps < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(mbps));
        }

        var (fair, good) = Thresholds(direction);
        return mbps >= good ? SpeedRatingLevel.Good : mbps >= fair ? SpeedRatingLevel.Fair : SpeedRatingLevel.Slow;
    }

    // Ratings use the same two-decimal value that is displayed, so a shown "25" is never rated Slow.
    public static double DisplayMbps(double bps)
    {
        if (!double.IsFinite(bps) || bps < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(bps));
        }

        return Math.Round(bps / 1_000_000, 2, MidpointRounding.AwayFromZero);
    }

    public static string FormatMbps(double mbps) => mbps.ToString("0.##", CultureInfo.CurrentCulture);

    public static string Label(SpeedRatingLevel level) => level switch
    {
        SpeedRatingLevel.Good => "Good",
        SpeedRatingLevel.Fair => "Fair",
        _ => "Slow"
    };

    // Scale fractions for the arc gradient: red up to the Fair threshold, yellow at the logarithmic midpoint
    // between the thresholds, and green from the Good threshold to the end of the scale.
    public static (double Slow, double Middle, double Good) GradientFractions(SpeedDirection direction)
    {
        var (fair, good) = Thresholds(direction);
        return (SpeedGaugeMotion.ScaleFraction(fair),
            SpeedGaugeMotion.ScaleFraction(Math.Sqrt(fair * good)),
            SpeedGaugeMotion.ScaleFraction(good));
    }

    public static string ScaleCaption(SpeedDirection direction)
    {
        var (fair, good) = Thresholds(direction);
        return $"Logarithmic scale: each labeled mark is 10 times the previous one. Slow below {FormatMbps(fair)} Mbps; Good from {FormatMbps(good)} Mbps.";
    }
}
