using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class SpeedGauge : UserControl
{
    private readonly SpeedGaugeMotion _motion = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Stopwatch _clock = new();
    private readonly Windows.UI.ViewManagement.UISettings _uiSettings = new();
    private SpeedDirection _direction = SpeedDirection.Download;

    public SpeedGauge()
    {
        InitializeComponent();
        _timer.Tick += OnTick;
        Unloaded += (_, _) => Stop();
        ApplyDirection();
    }

    public string Direction
    {
        get => TitleText.Text;
        set
        {
            TitleText.Text = value;
            _direction = value == "Upload" ? SpeedDirection.Upload : SpeedDirection.Download;
            ApplyDirection();
        }
    }

    public void SetMeasuring(bool measuring) =>
        StateText.Text = measuring ? "Measuring - provisional" : ValueText.Text == "--"
            ? "Waiting for measurements"
            : "Latest estimate - provisional";

    public void ShowSample(double bps)
    {
        _motion.SetBandwidth(bps);
        var mbps = SpeedRating.DisplayMbps(bps);
        var level = SpeedRating.Rate(_direction, mbps);
        var rating = SpeedRating.Label(level);
        ValueText.Text = SpeedRating.FormatMbps(mbps);
        RatingText.Text = rating;
        RatingText.Style = SpeedRatingStyle(level);
        RatingText.Visibility = Visibility.Visible;
        AutomationProperties.SetName(ValueText, $"{Direction} provisional speed: {ValueText.Text} Mbps, {rating}");
        if (!_uiSettings.AnimationsEnabled)
        {
            _motion.Advance(0, false);
            Needle.Angle = _motion.Angle;
            Stop();
            return;
        }

        if (!_timer.IsEnabled)
        {
            _clock.Restart();
            _timer.Start();
        }
    }

    public void Reset()
    {
        Stop();
        _motion.Reset();
        Needle.Angle = _motion.Angle;
        ValueText.Text = "--";
        RatingText.Text = string.Empty;
        RatingText.Visibility = Visibility.Collapsed;
        SetMeasuring(false);
        AutomationProperties.SetName(ValueText, $"{Direction} provisional speed: no sample");
    }

    internal static Style SpeedRatingStyle(SpeedRatingLevel level) =>
        (Style)Application.Current.Resources[level switch
        {
            SpeedRatingLevel.Good => "SpeedRatingGoodTextStyle",
            SpeedRatingLevel.Fair => "SpeedRatingFairTextStyle",
            _ => "SpeedRatingSlowTextStyle"
        }];

    private void ApplyDirection()
    {
        DirectionIcon.Glyph = _direction == SpeedDirection.Upload ? "\uE898" : "\uE896";
        var (slow, middle, good) = SpeedRating.GradientFractions(_direction);
        SlowStop.Offset = SpeedGaugeMotion.ArcHorizontalOffset(slow);
        FairStop.Offset = SpeedGaugeMotion.ArcHorizontalOffset(middle);
        GoodStop.Offset = SpeedGaugeMotion.ArcHorizontalOffset(good);
        ScaleCaption.Text = SpeedRating.ScaleCaption(_direction);
        if (ValueText.Text == "--")
        {
            AutomationProperties.SetName(ValueText, $"{Direction} provisional speed: no sample");
        }
    }

    private void OnTick(object? sender, object e)
    {
        var seconds = _clock.Elapsed.TotalSeconds;
        _clock.Restart();
        var moving = _motion.Advance(seconds, _uiSettings.AnimationsEnabled);
        Needle.Angle = _motion.Angle;
        if (!moving)
        {
            Stop();
        }
    }

    private void Stop()
    {
        _timer.Stop();
        _clock.Stop();
    }
}
