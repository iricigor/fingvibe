using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Windows.UI.ViewManagement;
using Path = Microsoft.UI.Xaml.Shapes.Path;
using Colors = Microsoft.UI.Colors;

namespace FingVibe.App.Views;

internal static class ActivityGridRenderer
{
    internal static void RenderCountLegend(TextBlock target, string legend, decimal? maximum,
        ElementTheme theme, UISettings colors)
    {
        target.Inlines.Clear();
        if (maximum is { } max)
        {
            var contrast = new AccessibilitySettings().HighContrast;
            foreach (var fraction in max == 0 ? new[] { 0m } : new[] { 0m, .25m, .5m, .75m, 1m })
            {
                var sample = new DeviceActivityCell("", "", 0, 1, true,
                    fraction == 0 ? AnalyticsResponse.DidNotRespond : AnalyticsResponse.Responded, fraction, false, "", "");
                target.Inlines.Add(new Run { Text = "\u25A0 ", Foreground = new SolidColorBrush(contrast
                    ? colors.GetColorValue(UIColorType.Foreground) : CellColor(sample, false, theme, colors)) });
                target.Inlines.Add(new Run { Text = $"{max * fraction:0.#}  " });
            }
        }
        target.Inlines.Add(new Run { Text = legend });
    }

    internal static void RenderLoading(Grid grid, int hours, UISettings colors)
    {
        grid.Children.Clear();
        grid.RowDefinitions.Clear();
        grid.ColumnDefinitions.Clear();
        grid.MinWidth = 0;
        for (var column = 0; column < 24 / hours; column++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var row = 0; row < 3; row++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(24) });
            for (var column = 0; column < 24 / hours; column++)
            {
                var placeholder = new Border { Background = new SolidColorBrush(colors.GetColorValue(UIColorType.Foreground)), Opacity = .12 };
                Grid.SetRow(placeholder, row);
                Grid.SetColumn(placeholder, column);
                grid.Children.Add(placeholder);
            }
        }
    }

    internal static void Render(Grid grid, IReadOnlyList<DeviceActivityCell> cells, ElementTheme theme,
        UISettings colors, string idPrefix, Action<string> select, bool deviceStyle = false)
    {
        var focusedIndex = deviceStyle && grid.XamlRoot is { } root
            && FocusManager.GetFocusedElement(root) is Button { Tag: int focusedCellIndex } focused
            && grid.Children.Contains(focused) ? focusedCellIndex : (int?)null;
        grid.Children.Clear();
        grid.RowDefinitions.Clear();
        grid.ColumnDefinitions.Clear();
        if (cells.Count == 0) { grid.MinWidth = 0; return; }
        var columns = 24 / cells[0].Hours;
        var rows = cells.Count / columns;
        var scale = colors.TextScaleFactor;
        grid.MinWidth = (124 + columns * (deviceStyle ? 28 : 36)) * scale;
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120 * scale) });
        for (var column = 0; column < columns; column++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var row = 0; row <= rows; row++)
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var header = new Grid { MinHeight = 24 * scale };
        for (var column = 0; column < columns; column++)
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var column = 0; column < columns; column++)
        {
            var hour = column * cells[0].Hours;
            if (hour % 3 != 0 && columns > 12) continue;
            var label = new TextBlock { Text = $"{hour:00}:00", FontSize = 11 };
            Grid.SetColumn(label, column);
            header.Children.Add(label);
        }
        var end = new TextBlock { Text = "24:00", FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right };
        Grid.SetColumn(end, columns - 1);
        header.Children.Add(end);
        Grid.SetColumn(header, 1);
        Grid.SetColumnSpan(header, columns);
        grid.Children.Add(header);
        var contrast = new AccessibilitySettings().HighContrast;
        var buttons = new List<Button>();
        for (var row = 0; row < rows; row++)
        {
            var first = cells[row * columns];
            var label = new TextBlock { Text = $"{first.RowLabel} {first.RowTotal}".TrimEnd(),
                FontSize = rows > 7 ? 11 : 13, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
            Grid.SetRow(label, row + 1);
            grid.Children.Add(label);
            for (var column = 0; column < columns; column++)
            {
                var index = row * columns + column;
                var cell = cells[index];
                var background = CellColor(cell, contrast, theme, colors, deviceStyle);
                var foreground = contrast ? colors.GetColorValue(UIColorType.Foreground) : TextColor(background);
                var content = new Grid { MinWidth = 28, MinHeight = rows > 7 ? 22 : 32,
                    Background = new SolidColorBrush(background) };
                if (cell.Hatched)
                    content.Children.Add(new Path
                    {
                        Stretch = Stretch.Fill, Opacity = contrast ? 1 : .45,
                        Stroke = new SolidColorBrush(foreground), StrokeThickness = .7, Data = HatchGeometry(deviceStyle ? 12 : 6)
                    });
                var glyph = new TextBlock
                {
                    Text = deviceStyle
                        ? !cell.IsApplicable ? "N/A" : cell.IsFuture ? "\u00B7" : !string.IsNullOrEmpty(cell.Value)
                            ? cell.Value + (cell.Response == AnalyticsResponse.DidNotRespond ? "\u2212" : "")
                            : cell.Response == AnalyticsResponse.Responded ? "R" : cell.Response == AnalyticsResponse.DidNotRespond ? "\u2212" : "?"
                        : contrast && cell.IsApplicable && string.IsNullOrEmpty(cell.Value)
                        ? cell.Response == AnalyticsResponse.Responded ? "R" : cell.Response == AnalyticsResponse.DidNotRespond ? "N" : "?"
                        : cell.Value,
                    FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                    Foreground = new SolidColorBrush(foreground)
                };
                AutomationProperties.SetAccessibilityView(glyph, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                content.Children.Add(glyph);
                var button = new Button
                {
                    Content = content, Padding = new Thickness(0), CornerRadius = new CornerRadius(0),
                    HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch,
                    Tag = index, Opacity = deviceStyle && cell.IsFuture && !contrast ? .45 : 1
                };
                AutomationProperties.SetAutomationId(button, $"{idPrefix}-{row}-{column}");
                AutomationProperties.SetName(button, cell.Details);
                ToolTipService.SetToolTip(button, cell.Details);
                button.Click += (_, _) => select(cell.Details);
                button.GotFocus += (_, _) =>
                {
                    select(cell.Details);
                    button.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
                };
                button.KeyDown += (_, e) => MoveFocus(index, columns, buttons, e);
                buttons.Add(button);
                Grid.SetRow(button, row + 1);
                Grid.SetColumn(button, column + 1);
                grid.Children.Add(button);
            }
        }
        if (focusedIndex is { } selected && selected < buttons.Count)
            buttons[selected].Focus(FocusState.Programmatic);
    }

    internal static Color CellColor(DeviceActivityCell cell, bool contrast, ElementTheme theme, UISettings colors,
        bool deviceStyle = false)
    {
        if (contrast) return colors.GetColorValue(UIColorType.Background);
        if (!cell.IsApplicable) return theme == ElementTheme.Dark ? Color.FromArgb(255, 32, 32, 32) : Colors.White;
        if (cell.Response == AnalyticsResponse.Unknown)
            return deviceStyle ? theme == ElementTheme.Dark ? Color.FromArgb(255, 32, 32, 32) : Colors.White
                : theme == ElementTheme.Dark ? Color.FromArgb(255, 55, 60, 67) : Color.FromArgb(255, 233, 237, 241);
        if (cell.Response == AnalyticsResponse.DidNotRespond)
            return deviceStyle ? Color.FromArgb(255, 230, 174, 66) : Color.FromArgb(255, 100, 116, 139);
        var fraction = (double)(cell.Fraction ?? 0);
        var low = theme == ElementTheme.Dark ? Color.FromArgb(255, 38, 60, 47) : Color.FromArgb(255, 206, 232, 216);
        return Color.FromArgb(255, (byte)(low.R + (21 - low.R) * fraction),
            (byte)(low.G + (114 - low.G) * fraction), (byte)(low.B + (60 - low.B) * fraction));
    }

    private static Color TextColor(Color background)
    {
        static double Linear(byte value) => value / 255d <= .04045 ? value / 255d / 12.92 : Math.Pow((value / 255d + .055) / 1.055, 2.4);
        var luminance = .2126 * Linear(background.R) + .7152 * Linear(background.G) + .0722 * Linear(background.B);
        return luminance > .179 ? Colors.Black : Colors.White;
    }

    private static PathGeometry HatchGeometry(int step)
    {
        var geometry = new PathGeometry();
        for (var offset = -24; offset <= 24; offset += step)
        {
            var figure = new PathFigure { StartPoint = new Point(Math.Max(0, offset), Math.Max(0, -offset)), IsClosed = false };
            figure.Segments.Add(new LineSegment { Point = new Point(Math.Min(24, offset + 24), Math.Min(24, 24 - offset)) });
            geometry.Figures.Add(figure);
        }
        return geometry;
    }

    private static void MoveFocus(int index, int columns, List<Button> buttons, KeyRoutedEventArgs e)
    {
        var next = e.Key switch
        {
            VirtualKey.Left => index - 1, VirtualKey.Right => index + 1,
            VirtualKey.Up => index - columns, VirtualKey.Down => index + columns,
            VirtualKey.Home => index / columns * columns, VirtualKey.End => (index / columns + 1) * columns - 1,
            _ => index
        };
        if (next == index) return;
        e.Handled = true;
        buttons[Math.Clamp(next, 0, buttons.Count - 1)].Focus(FocusState.Keyboard);
    }
}
