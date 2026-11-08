foreach ($theme in $UiReviewAppearanceThemes) {
    Set-SidebarAppearance ThemePicker $theme
    Save-SidebarAppearance "sidebar-$theme" -AssertMatchingSolid
}
Set-SidebarAppearance ThemePicker "Standard Dark"
foreach ($backdrop in @("Mica", "Mica Alt", "Acrylic", "Solid")) {
    Set-SidebarAppearance BackdropPicker $backdrop
    Save-SidebarAppearance "sidebar-$backdrop"
}
Set-SidebarAppearance BackdropPicker Mica
