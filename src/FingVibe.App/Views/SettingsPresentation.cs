using FingVibe.Core.Models;

namespace FingVibe.App.Views;

public static class SettingsPresentation
{
    public static int ColumnCount(double width) =>
        Math.Clamp((int)((width + 16) / (200 + 16)), 1, 3);

    public static string AppearanceSummary(AppearanceSettings settings, string? materialStatus)
    {
        var (mode, theme) = settings.Theme switch
        {
            ThemeVariant.StandardLight => ("Light", "Standard"),
            ThemeVariant.WarmLight => ("Light", "Warm"),
            ThemeVariant.ColorfulLight => ("Light", "Colorful"),
            ThemeVariant.StandardDark => ("Dark", "Standard"),
            ThemeVariant.OledDark => ("Dark", "True Black (OLED)"),
            ThemeVariant.ColorfulDark => ("Dark", "Colorful"),
            _ => throw new ArgumentOutOfRangeException(nameof(settings))
        };
        var backdrop = settings.Backdrop == WindowBackdrop.MicaAlt ? "Mica Alt" : settings.Backdrop.ToString();
        var summary = $"{mode} mode \u00b7 {theme} theme \u00b7 {backdrop} backdrop";
        return materialStatus is null ? summary : $"{summary}. {materialStatus}";
    }

    public static string DevicesSummary(bool compactRows, bool hoverPreviews, int visibleColumns) =>
        $"Compact rows {(compactRows ? "on" : "off")} \u00b7 Cell hover previews {(hoverPreviews ? "on" : "off")} \u00b7 {visibleColumns} visible columns";

    // One line for the collapsed header; scheduledState is the shell's paused/retrying wording, and the
    // detailed status sentences stay in the expanded section and the header's help text.
    public static string BackgroundSummary(
        PeriodicScanSettings scheduled,
        string? scheduledState,
        NetworkMonitorSettings monitor) =>
        (scheduled.IsEnabled
            ? scheduledState ?? $"Scheduled every {PeriodicScanPresentation.IntervalLabel(scheduled.IntervalMinutes)} while app is open"
            : "Scheduled scans off") +
        $" \u00b7 Network monitoring {(monitor.IsEnabled ? "on" : "off")}";

    public static string AppearanceStatus(string? saveError, string? materialStatus)
    {
        var status = saveError ?? (materialStatus is null
            ? "Appearance changes apply immediately and save automatically, with material effects depending on Windows transparency settings."
            : "Appearance changes apply immediately and save automatically.");
        return materialStatus is null ? status : $"{status} {materialStatus}";
    }
}
