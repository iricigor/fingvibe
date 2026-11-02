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
    OledDark,
    ColorfulLight,
    ColorfulDark,
    VividLight,
    VividDark
}

public enum VisualStyle
{
    Standard,
    Glass,
    Clay,
    Neumorphic
}

public sealed record AppearanceSettings(
    WindowBackdrop Backdrop = WindowBackdrop.Solid,
    ThemeVariant Theme = ThemeVariant.StandardLight,
    VisualStyle Style = VisualStyle.Standard);
