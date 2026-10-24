using System.Diagnostics;
using System.Globalization;
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

    public SpeedGauge()
    {
        InitializeComponent();
        _timer.Tick += OnTick;
        Unloaded += (_, _) => Stop();
    }

    public string Direction
    {
        get => TitleText.Text;
        set
        {
            TitleText.Text = value;
            DirectionIcon.Glyph = value == "Upload" ? "\uE898" : "\uE896";
            AutomationProperties.SetName(ValueText, $"{value} provisional speed: no sample");
        }
    }

    public void SetMeasuring(bool measuring) =>
        StateText.Text = measuring ? "Measuring - provisional" : ValueText.Text == "--"
            ? "Waiting for measurements"
            : "Latest estimate - provisional";

    public void ShowSample(double bps)
    {
        _motion.SetBandwidth(bps);
        ValueText.Text = (bps / 1_000_000).ToString("0.##", CultureInfo.CurrentCulture);
        AutomationProperties.SetName(ValueText, $"{Direction} provisional speed: {ValueText.Text} Mbps");
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
        SetMeasuring(false);
        AutomationProperties.SetName(ValueText, $"{Direction} provisional speed: no sample");
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
