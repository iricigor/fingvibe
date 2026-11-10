Set-DeviceFilterChoice InventoryStatusFilter "All statuses"
Set-DeviceFilterChoice RoomFilter "All rooms"
$scroll = (Find-DeviceElement ResultsList).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
$scroll.SetScrollPercent(-1, 100)
Start-Sleep -Milliseconds 250
Assert-DeviceStripes "devices-recycled-bottom"
$scroll.SetScrollPercent(-1, 0)
Start-Sleep -Milliseconds 250
Assert-DeviceStripes "devices-recycled-top"
$search.SetValue("Fixture device 1")
Start-Sleep -Milliseconds 250
Assert-DeviceStripes "devices-filtered"
$search.SetValue("")
Start-Sleep -Milliseconds 250
$rows = @(Get-DeviceRows)
$progressCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::ProgressBar)
$bar = $rows[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants, $progressCondition)
if (-not $bar) { throw "Response bar was not found." }
$labelCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text),
    [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, $bar.Current.Name))
$label = $rows[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants, $labelCondition)
if (-not $label -or $label.Current.BoundingRectangle.Bottom -gt $bar.Current.BoundingRectangle.Top -or
    $bar.Current.BoundingRectangle.Width / $scale -lt 150) {
    throw "Combined response must use a readable number above a shared full-width bar."
}
$rowBounds = $rows[1].Current.BoundingRectangle
Focus-DeviceWindow
[DevicesReviewInput]::MoveTo([int]($rowBounds.Left + 100 * $scale),
    [int]($rowBounds.Top + $rowBounds.Height / 2))
Start-Sleep -Milliseconds 250
$path = Save-DeviceCapture "devices-hover" -KeepPointer
$bitmap = [System.Drawing.Bitmap]::new($path)
try {
    if ((Get-RowColor $bitmap $rows[1]) -eq (Get-RowColor $bitmap $rows[3])) {
        throw "Hover must override the alternate background."
    }
}
finally { $bitmap.Dispose() }
$null = Save-DeviceCapture "devices-hover-cleared"
$selection = $rows[1].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
$selection.Select()
$path = Save-DeviceCapture "devices-selected"
$bitmap = [System.Drawing.Bitmap]::new($path)
try {
    $selectedColor = Get-RowColor $bitmap $rows[1]
    if ($selectedColor -eq (Get-RowColor $bitmap $rows[3])) {
        throw "Selection must override the alternate background."
    }
}
finally { $bitmap.Dispose() }
$sort = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent((Find-DeviceElement AddressSortGlyph))
while ($sort -and $sort.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) {
    $sort = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($sort)
}
if (-not $sort) { throw "Address sort button was not found." }
$sort.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 250
$listSelection = (Find-DeviceElement ResultsList).GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
$selected = @($listSelection.Current.GetSelection())
if ($selected.Count -ne 1) { throw "Sorting must preserve selection." }
$deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    $selected = @($listSelection.Current.GetSelection())
    if ($selected.Count -ne 1) { throw "Scrolling must preserve the selected device." }
    $selectedBounds = $selected[0].Current.BoundingRectangle
    $listBounds = (Find-DeviceElement ResultsList).Current.BoundingRectangle
    $visible = -not $selected[0].Current.IsOffscreen -and -not $selectedBounds.IsEmpty -and
        $selectedBounds.Top -ge $listBounds.Top -and $selectedBounds.Bottom -le $listBounds.Bottom
    if ($visible) { break }
    # Density changes alter virtualization estimates; reacquire selection until scrolling realizes it.
    $selected[0].GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()
    Start-Sleep -Milliseconds 150
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $visible) { throw "The selected device did not become fully visible after sorting." }
$nameCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Kitchen display")
if (-not $selected[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)) {
    throw "Sorting changed the selected device."
}
$path = Save-DeviceCapture "devices-selected-recycled"
$bitmap = [System.Drawing.Bitmap]::new($path)
try {
    if ((Get-RowColor $bitmap $selected[0]) -ne $selectedColor) {
        throw "A selected row's background must survive sorting and container recycling."
    }
}
finally { $bitmap.Dispose() }
$selected[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).RemoveFromSelection()
$scroll.SetScrollPercent(-1, 0)
Assert-DeviceStripes "devices-sorted"
$sort.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 250
$scroll.SetScrollPercent(-1, 0)
Start-Sleep -Milliseconds 250
$rows = @(Get-DeviceRows)
$rows[0].SetFocus()
[DevicesReviewInput]::Tap(0x28)
Start-Sleep -Milliseconds 250
$selected = @($listSelection.Current.GetSelection())
if ($selected.Count -ne 1 -or -not $selected[0].Current.HasKeyboardFocus) {
    throw "Keyboard navigation must focus and select a device row."
}
$keyboardPreview = Find-DeviceElement CellPreviewText
if ($keyboardPreview.Current.Name -ne $selected[0].Current.HelpText -or
    $keyboardPreview.Current.Name -notlike "*IP address: *MAC address: *Vendor: *Person: *Room: *") {
    throw "Keyboard focus must reveal the row's equivalent full values."
}
Assert-PreviewFont $keyboardPreview (Get-VisibleDeviceChild $selected[0] AutomationId DeviceNameText)
$null = Save-DeviceCapture "devices-keyboard-focus"
$area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
if ($area.Width / $scale -ge 1880) {
    Set-DeviceWidth 1880
    $grips = @("Resize Room column", "Resize Last seen column") | ForEach-Object {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $_)
        $grip = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if (-not $grip -or $grip.Current.IsOffscreen) { throw "Header grip '$_' was not visible." }
        $grip
    }
    $path = Save-DeviceCapture "devices-wide-header"
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        $windowBounds = Get-UiReviewWindowBounds $windowHandle
        for ($index = 0; $index -lt $grips.Count; $index++) {
            $bounds = $grips[$index].Current.BoundingRectangle
            $left = $bounds.Left - $windowBounds.Left
            $y = [int]($bounds.Top - $windowBounds.Top + $bounds.Height / 2)
            $background = $bitmap.GetPixel([int]($left - 1), $y).ToArgb()
            $center = $left + $bounds.Width / 2
            $hasLine = @([Math]::Floor($center), [Math]::Ceiling($center)) |
                Where-Object { $bitmap.GetPixel([int]$_, $y).ToArgb() -ne $background }
            if (-not $hasLine) {
                throw "Every visible header, including the final column, must retain its right-edge divider."
            }
        }
    }
    finally { $bitmap.Dispose() }
    $left = $grips[1].Current.BoundingRectangle.Left
    $grips[1].SetFocus()
    [DevicesReviewInput]::Tap(0x27)
    Start-Sleep -Milliseconds 200
    if ([Math]::Abs($grips[1].Current.BoundingRectangle.Left - $left - 8 * $scale) -gt 1) {
        throw "The final column must remain keyboard-resizable at its visible divider."
    }
    Write-Host "Full-header pixel check and final-column keyboard resizing passed."
}
else { Write-Host "Full-header pixel check not run: desktop is narrower than 1880 logical pixels." }
