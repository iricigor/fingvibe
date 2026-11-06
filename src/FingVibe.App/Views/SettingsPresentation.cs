namespace FingVibe.App.Views;

public static class SettingsPresentation
{
    public static int ColumnCount(double width) =>
        Math.Clamp((int)((width + 16) / (200 + 16)), 1, 3);

    public static string AppearanceStatus(string? saveError, string? materialStatus)
    {
        var status = saveError ?? (materialStatus is null
            ? "Appearance changes apply immediately and save automatically, with material effects depending on Windows transparency settings."
            : "Appearance changes apply immediately and save automatically.");
        return materialStatus is null ? status : $"{status} {materialStatus}";
    }
}
