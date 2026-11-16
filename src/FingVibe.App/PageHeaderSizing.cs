using Microsoft.UI.Xaml;
using Windows.Foundation;

namespace FingVibe.App;

public sealed class PageHeaderSizing : DependencyObject
{
    public static readonly DependencyProperty ReferenceWidthProperty = DependencyProperty.Register(
        nameof(ReferenceWidth), typeof(double), typeof(PageHeaderSizing), new PropertyMetadata(0d));

    public static readonly DependencyProperty ReferenceHeightProperty = DependencyProperty.Register(
        nameof(ReferenceHeight), typeof(double), typeof(PageHeaderSizing), new PropertyMetadata(0d));

    public double ReferenceWidth
    {
        get => (double)GetValue(ReferenceWidthProperty);
        private set => SetValue(ReferenceWidthProperty, value);
    }

    public double ReferenceHeight
    {
        get => (double)GetValue(ReferenceHeightProperty);
        private set => SetValue(ReferenceHeightProperty, value);
    }

    internal void MeasureReference(FrameworkElement overviewTab)
    {
        // Details can be collapsed when a tool opens first; measure the real item, not its padded host.
        overviewTab.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        SetReferenceSize(overviewTab.DesiredSize);
    }

    internal void SetReferenceSize(Size size)
    {
        if (!double.IsFinite(size.Width) || !double.IsFinite(size.Height) || size.Width <= 0 || size.Height <= 0)
            throw new InvalidOperationException("The Overview tab must provide a non-empty Back-button reference size.");
        ReferenceWidth = size.Width;
        ReferenceHeight = size.Height;
    }
}
