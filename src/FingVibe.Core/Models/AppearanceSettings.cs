namespace FingVibe.Core.Models;

public enum WindowBackdrop
{
    Solid,
    Mica,
    MicaAlt,
    Acrylic
}

public enum ThemeVariant
{
    StandardLight,
    WarmLight,
    StandardDark,
    OledDark
}

public sealed record AppearanceSettings(
    WindowBackdrop Backdrop = WindowBackdrop.Solid,
    ThemeVariant Theme = ThemeVariant.StandardLight);
