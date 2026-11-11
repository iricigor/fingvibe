Select-DevicePage OverviewNavItem
$scanButton = Find-DeviceElement ScanButton
if (-not $scanButton.Current.IsEnabled -or $scanButton.Current.Name -ne "Scan LAN") {
    throw "The shared Scan LAN action must be available on Overview."
}
Set-DeviceWidth 1280
Focus-DeviceWindow
Select-DevicePage DevicesNavItem
$null = Find-DeviceElement ScanButton
$networkLabelCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, "Network:"),
    [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text))
if (-not $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $networkLabelCondition)) {
    throw "The shared network selector must be labeled 'Network:'."
}
$heading = (Find-DeviceElement DevicesHeading).Current.BoundingRectangle
$inventory = (Find-DeviceElement InventoryCountsText).Current.BoundingRectangle
$deviceCount = (Find-DeviceElement ResultCountText).Current.BoundingRectangle
$scanSummary = (Find-DeviceElement LastScanText).Current.BoundingRectangle
foreach ($id in @("OnlineChip", "OfflineChip", "UnknownChip", "FingOnlyChip")) {
    $chip = (Find-DeviceElement $id).Current.BoundingRectangle
    if ([Math]::Abs($chip.Top - $inventory.Top) -gt $scale -or $chip.Height -gt 28 * $scale) {
        throw "Wide status totals must be compact, content-sized toggles in one horizontal row."
    }
}
if ($heading.Bottom -ge $inventory.Top -or
    [Math]::Abs($inventory.Left - $heading.Left - 16 * $scale) -gt 2 * $scale) {
    throw "Devices title must sit above the card contents, outside their 16-DIP inset."
}
if ($heading.Bottom -ge $deviceCount.Top -or $heading.Bottom -ge $scanSummary.Top -or
    [Math]::Abs(($inventory.Top + $inventory.Bottom - $deviceCount.Top - $deviceCount.Bottom) / 2) -gt 2 * $scale -or
    [Math]::Abs(($inventory.Top + $inventory.Bottom - $scanSummary.Top - $scanSummary.Bottom) / 2) -gt 2 * $scale) {
    throw "Inventory totals, Showing count, and Scan duration must share the summary row at wide widths."
}
if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices") { throw "Multi-device fixture did not load." }
if ((Find-DeviceElement LastScanText).Current.Name -ne "Scan duration 2.5s") {
    throw "The Devices summary must show duration without duplicating header freshness."
}
if (-not $root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, "Private 00-11-22"))) {
    throw "The screenshot fixture must include a virtual device."
}
$virtualRow = @(Get-DeviceRows)[4]
$virtualIcon = Get-VisibleDeviceChild $virtualRow AutomationId DeviceIcon
$normalIcon = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) AutomationId DeviceIcon
$virtualName = Get-VisibleDeviceChild $virtualRow AutomationId DeviceNameText
if ($virtualRow.Current.HelpText -notlike "*Virtual device - inferred identity across changing MAC addresses.*" -or
    -not $virtualIcon -or $virtualIcon.Current.Name -ne "Virtual device - inferred identity across changing MAC addresses." -or
    -not $normalIcon -or $normalIcon.Current.Name -like "*Virtual device*" -or
    -not $virtualName -or $virtualName.Current.Name -ne "Private 00-11-22" -or
    (Get-VisibleDeviceChild $root AutomationId VirtualIdentityBadge)) {
    throw "Virtual identities must use the main device icon without a separate badge or name decoration."
}
if ([Math]::Abs($virtualIcon.Current.BoundingRectangle.Left - $normalIcon.Current.BoundingRectangle.Left) -gt $scale -or
    [Math]::Abs($virtualIcon.Current.BoundingRectangle.Width - $normalIcon.Current.BoundingRectangle.Width) -gt $scale) {
    throw "The virtual-device icon must occupy the same position and width as the normal device icon."
}
$virtualRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
$virtualRow.SetFocus()
[DevicesReviewInput]::Tap(0x0D)
$null = Find-DeviceElement DeviceDetailsScroll
$null = Find-DeviceElement ScanButton
if ((Find-DeviceElement DeviceTypeIcon).Current.Name -ne "Virtual device - inferred identity across changing MAC addresses.") {
    throw "Device details must use the same accessible virtual-device icon as the list."
}
$null = Save-DeviceCapture "devices-virtual-device-details"
Select-DevicePage DevicesNavItem
