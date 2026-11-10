foreach ($case in @(
    @{ Id = 'InventoryStatusFilter'; Category = 'Status'; Missing = 'Unknown'; KnownCount = 80; MissingCount = 0 },
    @{ Id = 'TypeFilter'; Category = 'Device type'; Missing = 'Unknown'; KnownCount = 1; MissingCount = 79 },
    @{ Id = 'OperatingSystemFilter'; Category = 'Operating system'; Missing = 'Unknown'; KnownCount = 1; MissingCount = 79 },
    @{ Id = 'VendorFilter'; Category = 'Vendor'; Missing = 'Unknown'; KnownCount = 77; MissingCount = 3 },
    @{ Id = 'UsageCategoryFilter'; Category = 'Usage category'; Missing = 'Unclassified'; KnownCount = 0; MissingCount = 80 }
)) {
    $panel = Open-DeviceFilter $case.Id
    $checks = @($panel.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::CheckBox)))
    $labels = @($checks | ForEach-Object { $_.Current.Name })
    $missingIndex = [Array]::IndexOf($labels, $case.Missing)
    if ($missingIndex -lt 0 -or $labels[$missingIndex + 1] -ne 'Any') {
        throw "$($case.Id) must put Any immediately after $($case.Missing)."
    }
    if ($case.Id -eq 'VendorFilter' -and ('Private' -in $labels -or 'Randomized MAC' -notin $labels)) {
        throw 'Vendor choices must expose Unknown and Randomized MAC, not the raw Private registry value.'
    }
    $anyToggle = $checks[$missingIndex + 1].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $missingToggle = $checks[$missingIndex].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $anyToggle.Toggle()
    $expectedCount = if ($case.KnownCount -eq 80) { 'Showing 80 devices' } else { "Showing $($case.KnownCount) of 80 devices" }
    $null = Wait-UiRegressionState -Description "$($case.Id) Any known membership" -Condition {
        (Find-DeviceElement ResultCountText).Current.Name -eq $expectedCount
    }
    if ((Find-DeviceElement $case.Id).Current.Name -ne "$($case.Category): Any" -or
        $missingToggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw "$($case.Id) Any must replace individual and missing-value selections."
    }
    if ($case.Id -eq 'VendorFilter') { $null = Save-DeviceCapture 'devices-any-known-vendor' }
    $missingToggle.Toggle()
    $expectedCount = if ($case.MissingCount -eq 80) { 'Showing 80 devices' } else { "Showing $($case.MissingCount) of 80 devices" }
    $null = Wait-UiRegressionState -Description "$($case.Id) missing-value membership" -Condition {
        (Find-DeviceElement ResultCountText).Current.Name -eq $expectedCount
    }
    if ($anyToggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw "$($case.Id) an individual choice must replace Any."
    }
    if ($case.Id -eq 'VendorFilter') {
        $vendorText = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) AutomationId DeviceVendorText
        # Cell previews append their explanation to the automation name.
        if (-not $vendorText -or $vendorText.Current.Name -notmatch '^Unknown(?:\r?\n|$)' -or
            $vendorText.Current.HelpText -notlike '*Manufacturer not identified*') {
            throw 'Unknown vendor cells must retain an accessible explanation.'
        }
    }
    $missingToggle.Toggle()
    $null = Wait-UiRegressionState -Description "$($case.Id) unrestricted membership" -Condition {
        (Find-DeviceElement ResultCountText).Current.Name -eq 'Showing 80 devices'
    }
    [DevicesReviewInput]::Tap(0x1B)
}

foreach ($id in @('PersonFilter', 'RoomFilter')) {
    $panel = Open-DeviceFilter $id
    $checks = @($panel.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::CheckBox)))
    if (@($checks | Where-Object { $_.Current.Name -eq 'Any' }).Count -ne 0) {
        throw "$id must not offer Any with only one known assignment choice."
    }
    [DevicesReviewInput]::Tap(0x1B)
}
Assert-ClearFiltersVisible $false

Set-DeviceWidth 1880
$null = Wait-UiRegressionState -Description 'Usage category cell with completed empty evidence' -Condition {
    $firstRow = @(Get-DeviceRows)[0]
    $cell = Get-VisibleDeviceChild $firstRow AutomationId UsageCategoryCell
    $cell -and $cell.Current.Name -like 'Usage category: Unclassified.*' -and
        $cell.Current.HelpText -like '*No eligible scans*'
}
$firstRow = @(Get-DeviceRows)[0]
$categoryCell = Get-VisibleDeviceChild $firstRow AutomationId UsageCategoryCell
$categoryText = Get-VisibleDeviceChild $firstRow AutomationId DeviceUsageCategoryText
if (-not $categoryText -or $categoryCell.Current.BoundingRectangle.Height -gt 24 * $scale) {
    throw 'Usage category must occupy one line rather than a persistent second source line.'
}
$categoryCell.SetFocus()
[DevicesReviewInput]::Tap(0x0D)
$details = Find-DeviceElement UsageCategoryCellDetailsText
if ($details.Current.Name -notlike '*No eligible scans*' -or
    $details.Current.Name -notlike '*0 of 7 observed dates*' -or $details.Current.Name -match '%') {
    throw 'Keyboard-opened usage details must explain missing evidence without a fabricated percentage.'
}
$null = Save-DeviceCapture 'devices-usage-category-details'
[DevicesReviewInput]::Tap(0x1B)
$null = Find-DeviceElement ResultsList

Select-DevicePage Settings
foreach ($label in @('Vendor', 'Open ports', 'Status', 'Response', 'MAC address', 'OS', 'Device type', 'Usage category', 'Last seen')) {
    Set-ColumnOption $label $false
}
Set-ColumnOption 'Combine Person and Room' $true
Select-DevicePage DevicesNavItem
$grip = Get-VisibleDeviceChild $root Name 'Resize Person / room column'
if (-not $grip) { throw 'The last merged column must retain its resize handle.' }
$headerLeft = (Find-DeviceElement DeviceTableHeader).Current.BoundingRectangle.Left
$relativeRight = $grip.Current.BoundingRectangle.Right - $headerLeft
$capture = Save-DeviceCapture 'devices-last-column-boundary'
$windowBounds = Get-UiReviewWindowBounds $windowHandle
$gripBounds = $grip.Current.BoundingRectangle
$bitmap = [System.Drawing.Bitmap]::new($capture)
try {
    $centerX = [int]($gripBounds.Left + $gripBounds.Width / 2 - $windowBounds.Left)
    $centerY = [int]($gripBounds.Top + $gripBounds.Height / 2 - $windowBounds.Top)
    $background = $bitmap.GetPixel([int]($centerX + 6 * $scale), $centerY).ToArgb()
    $visibleBoundary = $false
    foreach ($x in ($centerX - 2)..($centerX + 2)) {
        $line = $bitmap.GetPixel($x, $centerY).ToArgb()
        if ($line -ne $background -and
            $bitmap.GetPixel($x, $centerY - 2).ToArgb() -eq $line -and
            $bitmap.GetPixel($x, $centerY + 2).ToArgb() -eq $line) {
            $visibleBoundary = $true
        }
    }
    if (-not $visibleBoundary) { throw 'The last column must have a visible right-edge separator, even with unused space beside it.' }
}
finally { $bitmap.Dispose() }
Set-DeviceWidth 1280
$grip = Get-VisibleDeviceChild $root Name 'Resize Person / room column'
$headerLeft = (Find-DeviceElement DeviceTableHeader).Current.BoundingRectangle.Left
if ([Math]::Abs($grip.Current.BoundingRectangle.Right - $headerLeft - $relativeRight) -gt $scale) {
    throw 'Changing the viewport must not expand the last column into unused space.'
}
$beforeResize = $grip.Current.BoundingRectangle.Left
$grip.SetFocus()
[DevicesReviewInput]::Tap(0x27)
$null = Wait-UiRegressionState -Description 'last-column keyboard resize' -Condition {
    [Math]::Abs((Get-VisibleDeviceChild $root Name 'Resize Person / room column').Current.BoundingRectangle.Left -
        $beforeResize - 8 * $scale) -le $scale
}
Select-DevicePage Settings
(Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Select-DevicePage DevicesNavItem
