namespace FingVibe.Core.Models;

// Light and Dark theme families share an index, so switching mode keeps the selected style and backdrop.
public static class AppearanceModes
{
    private static readonly ThemeVariant[] Light =
        [ThemeVariant.StandardLight, ThemeVariant.WarmLight, ThemeVariant.ColorfulLight];
    private static readonly ThemeVariant[] Dark =
        [ThemeVariant.StandardDark, ThemeVariant.OledDark, ThemeVariant.ColorfulDark];

    public static IReadOnlyList<ThemeVariant> LightThemes => Light;
    public static IReadOnlyList<ThemeVariant> DarkThemes => Dark;

    public static bool IsDark(ThemeVariant theme) => StyleIndex(theme).Dark;

    public static AppearanceSettings WithMode(AppearanceSettings settings, bool dark)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var (index, _) = StyleIndex(settings.Theme);
        return settings with { Theme = (dark ? Dark : Light)[index] };
    }

    private static (int Index, bool Dark) StyleIndex(ThemeVariant theme)
    {
        var index = Array.IndexOf(Light, theme);
        if (index >= 0)
        {
            return (index, false);
        }

        index = Array.IndexOf(Dark, theme);
        return index >= 0 ? (index, true) : throw new ArgumentOutOfRangeException(nameof(theme));
    }
}
