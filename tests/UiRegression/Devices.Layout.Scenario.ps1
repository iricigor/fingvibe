Set-DeviceFilterChoice PersonFilter "UI · UI review person"
Set-DeviceFilterChoice RoomFilter "UI · UI review room"
Assert-FilterPresentation PersonFilter Person "UI · UI review person"
Assert-FilterPresentation RoomFilter Room "UI · UI review room"
$widths = @{}
foreach ($width in @(1360, 1280, 1200, 1000, 640, 480)) {
    Set-DeviceWidth $width
    if ($width -ge 640) { $null = Save-DeviceCapture "devices-width-$width" }
    $chipBounds = @("OnlineChip", "OfflineChip", "UnknownChip", "FingOnlyChip") |
        ForEach-Object { (Find-DeviceElement $_).Current.BoundingRectangle }
    foreach ($bounds in $chipBounds) {
        if ($bounds.Left -lt $root.Current.BoundingRectangle.Left -or
            $bounds.Right -gt $root.Current.BoundingRectangle.Right) {
            throw "Summary chips must wrap inside the viewport at $width."
        }
    }
    $filters = @("ResultSearchBox", "InventoryStatusFilter", "FilterExpander", "TypeFilter",
        "OperatingSystemFilter", "VendorFilter", "PersonFilter", "RoomFilter", "PortsFilter", "UsageCategoryFilter") |
        ForEach-Object { Find-DeviceElement $_ }
    $widths[$width] = $filters[0].Current.BoundingRectangle.Width
    if ($widths[$width] -lt 180 * $scale) { throw "Search must remain usable before filters wrap at $width." }
    for ($index = 0; $index -lt $filters.Count; $index++) {
        $bounds = Get-FilterBounds $filters[$index]
        if ($bounds.Width -le 0) { throw "Filter has no width at $width." }
        $expectedWidth = if ($index -le 2) { @(0, 210, 64)[$index] } else { $filters[3].Current.BoundingRectangle.Width / $scale }
        if ($index -gt 0 -and [Math]::Abs($bounds.Width / $scale - $expectedWidth) -gt 1) {
            throw "Filter $index must remain ${expectedWidth}px wide at $width; got $($bounds.Width / $scale)px."
        }
        if ($index -ge 3 -and ([Math]::Abs($bounds.Top - $filters[3].Current.BoundingRectangle.Top) -gt $scale -or
            -not $root.Current.BoundingRectangle.Contains($bounds))) {
            throw "Secondary dropdowns must shrink in one row, without wrapping or leaving the viewport at $width."
        }
        foreach ($other in 0..($index - 1)) {
            if ($index -eq 0) { break }
            $intersection = [System.Windows.Rect]::Intersect($bounds, (Get-FilterBounds $filters[$other]))
            if (-not $intersection.IsEmpty -and $intersection.Width -gt 0 -and $intersection.Height -gt 0) {
                throw "Filters overlap at $width."
            }
        }
    }
}
# Compare widths within the inline layout, not across its wrapping breakpoint.
if ([Math]::Abs($widths[1360] - $widths[1280] - 80 * $scale) -gt 1) {
    throw "Search must absorb the full 80-DIP window expansion."
}
Set-DeviceWidth 1280
Set-DeviceFilterChoice PersonFilter "All people"
Set-DeviceFilterChoice RoomFilter "All rooms"
$null = Open-DeviceFilter PortsFilter
$checkbox = Find-DeviceElement OpenPortsFilter
$bounds = $checkbox.Current.BoundingRectangle
$null = [DevicesReviewInput]::SetCursorPos([int]($bounds.Left + 10 * $scale), [int]($bounds.Top + $bounds.Height / 2))
[DevicesReviewInput]::Click()
Start-Sleep -Milliseconds 200
$toggle = $checkbox.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
    throw "Clicking the open-ports checkbox glyph must toggle it."
}
if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 40 of 80 devices") { throw "Open-ports filter did not apply." }
$component = Get-FilterBounds $checkbox
$null = [DevicesReviewInput]::SetCursorPos([int]($component.Left + 60 * $scale), [int]($component.Top + $component.Height / 2))
[DevicesReviewInput]::Click()
Start-Sleep -Milliseconds 200
if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
    throw "Clicking the open-ports checkbox label must also toggle it."
}
$checkbox.SetFocus()
[DevicesReviewInput]::Tap(0x20)
Start-Sleep -Milliseconds 200
if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { throw "Keyboard checkbox toggle regressed." }
$toggle.Toggle()
[DevicesReviewInput]::Tap(0x1B)
$search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
$search.SetValue("no-matching-fixture")
Start-Sleep -Milliseconds 200
if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 0 of 80 devices") { throw "Search count regressed." }
$search.SetValue("")
Start-Sleep -Milliseconds 200
Set-DeviceFilterChoice InventoryStatusFilter Online
Set-DeviceFilterChoice RoomFilter Unassigned
