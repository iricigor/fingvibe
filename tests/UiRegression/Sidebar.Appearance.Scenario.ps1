Test-TitleBarInteractions
foreach ($theme in $UiReviewAppearanceThemes) {
    Set-SidebarAppearance ThemePicker $theme
    Save-SidebarAppearance "sidebar-$theme" -AssertMatchingSolid
    if ($theme -in @("Standard Light", "Standard Dark")) {
        Test-TitleBarLayout
        Save-SidebarAppearance "title-bar-$theme-restored"
        $windowPattern = $root.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        try {
            $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Maximized)
            $null = Wait-UiRegressionState -Description 'maximized title-bar layout' -Condition {
                $windowPattern.Current.WindowVisualState -eq [System.Windows.Automation.WindowVisualState]::Maximized
            }
            Test-TitleBarLayout
            Save-SidebarAppearance "title-bar-$theme-maximized"
        }
        finally {
            $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
            Set-SidebarWindowWidth $expandedWidth
        }
        $maximum = if ($theme -eq "Standard Light") { 12 } else { 16 }
        Test-SidebarDividerAppearance -Name "sidebar-divider-$theme" -MaximumContrast $maximum
        Assert-SidebarFamilyIcons "sidebar-$theme"
    }
}
try {
    $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
    if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) {
        throw "High contrast did not activate."
    }
    Start-Sleep -Seconds 2
    Test-TitleBarLayout
    Save-SidebarAppearance "title-bar-high-contrast"
    Test-SidebarDividerAppearance -Name "sidebar-divider-high-contrast" -MaximumContrast 255
    Assert-SidebarFamilyIcons "sidebar-divider-high-contrast-hidden"
    (Find-SidebarElement AutomationId NavigationResizeGrip).SetFocus()
    Save-SidebarAppearance "sidebar-divider-high-contrast-focus"
}
finally {
    if ($null -ne $highContrast) {
        [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
        Start-Sleep -Seconds 2
    }
}
Set-SidebarAppearance ThemePicker "Standard Dark"
foreach ($backdrop in @("Mica", "Mica Alt", "Acrylic", "Solid")) {
    Set-SidebarAppearance BackdropPicker $backdrop
    Save-SidebarAppearance "sidebar-$backdrop"
}
Set-SidebarAppearance BackdropPicker Mica
