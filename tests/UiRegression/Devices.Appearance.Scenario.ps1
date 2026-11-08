foreach ($theme in $UiReviewAppearanceThemes) {
    Select-DevicePage Settings
    Set-UiReviewTheme -Root $root -Theme $theme
    Select-DevicePage DevicesNavItem
    Assert-DeviceStripes "devices-$theme"
    Assert-HeaderUnderline $theme
    $row = @(Get-DeviceRows)[0]
    Assert-HoverText $row $theme
    $vendorValue = "Example Devices with a deliberately long manufacturer name for hover inspection"
    $name = Get-VisibleDeviceChild $row Name $vendorValue
    $null = Assert-CellPreview $name $vendorValue "devices-preview-$theme"
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
}
