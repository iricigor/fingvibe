Set-DeviceWidth 1280
Focus-DeviceWindow
Select-DevicePage DevicesNavItem
$null = Wait-UiRegressionState -Description 'the Devices page to list the 80-device fixture' -Condition {
    (Find-DeviceElement ResultCountText).Current.Name -eq 'Showing 80 devices'
}
