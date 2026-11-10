function Test-ConditionalDeviceColumns {
    foreach ($case in @(
        @{ Status = $true; Response = $true; Type = $true; Grip = "Status / response" },
        @{ Status = $true; Response = $false; Type = $false; Grip = "Status" },
        @{ Status = $false; Response = $true; Type = $true; Grip = "Response" },
        @{ Status = $false; Response = $false; Type = $false; Grip = "" }
    )) {
        Select-DevicePage Settings
        $choices = (Find-DeviceElement SettingsPage).FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::CheckBox))
        foreach ($entry in @(@("Status", $case.Status), @("Response", $case.Response), @("Device type", $case.Type))) {
            $box = @($choices | Where-Object { $_.Current.Name -eq $entry[0] })[0]
            if (-not $box) { throw "Column choice '$($entry[0])' not found." }
            $toggle = $box.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $entry[1]) {
                $toggle.Toggle()
            }
        }
        Select-DevicePage DevicesNavItem
        $row = @(Get-DeviceRows)[0]
        $status = Get-VisibleDeviceChild $row Name "Online"
        $response = Get-VisibleDeviceChild $row AutomationId ResponseTimeText
        $type = Get-VisibleDeviceChild $row AutomationId DeviceTypeLabel
        if ([bool]$status -ne $case.Status -or [bool]$response -ne $case.Response -or [bool]$type -ne $case.Type) {
            throw "Conditional column content does not match Settings: $($case | ConvertTo-Json -Compress)."
        }
        $grip = Get-VisibleDeviceChild $root AutomationId ConnectionResizeGrip
        if ([bool]$grip -ne [bool]$case.Grip) { throw "Connection resize handle visibility is incorrect." }
        if ($grip) {
            if ($grip.Current.Name -ne "Resize $($case.Grip) column") { throw "Connection resize target is incorrect." }
            $left = $grip.Current.BoundingRectangle.Left
            $grip.SetFocus()
            [DevicesReviewInput]::Tap(0x27)
            Start-Sleep -Milliseconds 150
            if ([Math]::Abs($grip.Current.BoundingRectangle.Left - $left - 8 * $scale) -gt 1) {
                throw "Conditional connection column must resize by one keyboard step."
            }
        }
        if ($type) {
            $name = Get-VisibleDeviceChild $row AutomationId DeviceNameText
            if ($type.Current.BoundingRectangle.Top -lt $name.Current.BoundingRectangle.Bottom -or
                [Math]::Abs($type.Current.BoundingRectangle.Left - $name.Current.BoundingRectangle.Left) -gt $scale) {
                throw "Device type must be a secondary line within the Name column."
            }
            if ($case.Status -and $case.Response) {
                $bar = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::ProgressBar))
                $badgeBounds = $status.Current.BoundingRectangle
                $timeBounds = $response.Current.BoundingRectangle
                $barBounds = $bar.Current.BoundingRectangle
                if ($badgeBounds.Left -ge $timeBounds.Right -or
                    $badgeBounds.Bottom -gt $barBounds.Top -or $timeBounds.Bottom -gt $barBounds.Top -or
                    $barBounds.Left -gt $badgeBounds.Left -or $barBounds.Right -lt $timeBounds.Right -or
                    $barBounds.Width / $scale -lt 150) {
                    throw "Combined connection must place status upper-left, time upper-right, and a shared full-width bar below both."
                }
            }
        }
        $null = Save-DeviceCapture "devices-columns-$($case.Status)-$($case.Response)"
    }
    Select-DevicePage Settings
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Select-DevicePage DevicesNavItem
}

function Set-ColumnOption([string] $Name, [bool] $Enabled) {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::CheckBox))
    $box = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $box) { throw "Column option '$Name' is missing." }
    $toggle = $box.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $Enabled) {
        $toggle.Toggle()
    }
}

function Test-MergeOptions {
    Set-DeviceWidth 1880
    foreach ($merged in @($false, $true)) {
        Select-DevicePage Settings
        foreach ($label in @("Combine Name and Type", "Combine IP and MAC", "Combine Status and Response", "Combine Person and Room", "Combine Vendor and OS")) {
            Set-ColumnOption $label $merged
        }
        Select-DevicePage DevicesNavItem
        $row = @(Get-DeviceRows)[0]
        $ip = Get-VisibleDeviceChild $row Name "127.0.0.1"
        $mac = Get-VisibleDeviceChild $row Name "00-11-22-33-44-01"
        if (-not $ip -or -not $mac) { throw "IP and MAC must both remain accessible." }
        $stacked = $mac.Current.BoundingRectangle.Top -ge $ip.Current.BoundingRectangle.Bottom
        if ($stacked -ne $merged) { throw "IP/MAC placement does not match the merge setting." }
        $type = Get-VisibleDeviceChild $row AutomationId DeviceTypeLabel
        if ([bool]$type -ne $merged) { throw "Name/Type merge setting was not applied." }
        $responseGrip = Get-VisibleDeviceChild $root Name "Resize Response column"
        if ([bool]$responseGrip -eq $merged) { throw "Separate Response must have its own resize boundary." }
        $assignmentGrip = Get-VisibleDeviceChild $root Name "Resize Person / room column"
        if ([bool]$assignmentGrip -ne $merged) { throw "Person/Room merge setting was not applied." }
        $os = Get-VisibleDeviceChild $row AutomationId MergedOperatingSystemText
        if ([bool]$os -ne $merged) { throw "Vendor/OS merge setting was not applied." }
        if ($os -and $os.Current.Name -ne "Android (likely)") { throw "Merged OS must preserve inference qualifiers." }
        if ($merged) {
            $unknownOs = Get-VisibleDeviceChild (@(Get-DeviceRows)[1]) AutomationId MergedOperatingSystemText
            if ($unknownOs -and $unknownOs.Current.Name) { throw "Unknown merged OS must remain blank, not a dash." }
        }
        $osGrip = Get-VisibleDeviceChild $root Name "Resize OS column"
        if ([bool]$osGrip -eq $merged) { throw "Merged OS must not allocate a standalone column." }
        $null = Save-DeviceCapture "devices-all-merges-$merged"
        $height = $row.Current.BoundingRectangle.Height / $scale
        if ($height -gt 48) {
            throw "Denser two-line rows must not exceed 48 DIPs; got $height with merges=$merged."
        }
    }
    Select-DevicePage Settings
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Select-DevicePage DevicesNavItem
    Set-DeviceWidth 1280
    $unknownRow = @(Get-DeviceRows)[2]
    if (Get-VisibleDeviceChild $unknownRow AutomationId DeviceTypeLabel) {
        throw "An unknown type must not reserve a secondary Name line."
    }
}

function Test-RowDensity {
    Set-DeviceWidth 1880
    $measurements = @{}
    foreach ($layout in @("Stacked", "Separate", "ConnectionOnly", "UsageOnly")) {
        $measurements[$layout] = @{}
        foreach ($density in @("Standard", "Compact")) {
            Select-DevicePage Settings
            foreach ($label in @("Combine Name and Type", "Combine IP and MAC", "Combine Person and Room", "Combine Vendor and OS")) {
                Set-ColumnOption $label ($layout -eq "Stacked")
            }
            Set-ColumnOption "Combine Status and Response" ($layout -ne "Separate")
            Set-ColumnOption "Usage category" ($layout -in @("Stacked", "UsageOnly"))
            Set-DeviceFilterChoice CompactRowsSwitch $density
            Select-DevicePage DevicesNavItem
            $rows = @(Get-DeviceRows)
            if ($rows.Count -lt 4) { throw "Density measurement requires four representative rows." }
            $listBounds = (Find-DeviceElement ResultsList).Current.BoundingRectangle
            $heights = @($rows | Select-Object -First 4 | ForEach-Object { $_.Current.BoundingRectangle.Height / $scale })
            $fullyVisible = @($rows | Where-Object { $_.Current.BoundingRectangle.Bottom -le $listBounds.Bottom }).Count
            $headerHeight = (Find-DeviceElement DeviceTableHeader).Current.BoundingRectangle.Height / $scale
            $measurements[$layout][$density] = @{ heights = $heights; visibleRows = $fullyVisible; headerHeight = $headerHeight; scale = $scale }
            $minimum = if ($layout -eq "Stacked") {
                if ($density -eq "Compact") { 36 } else { 40 }
            } else {
                if ($density -eq "Compact") { 30 } else { 34 }
            }
            # Native two-line name/type metrics require 44 DIPs in Standard, above its 40-DIP minimum.
            $maximum = $minimum + $(if ($layout -eq "Stacked" -and $density -eq "Standard") { 4.5 } else { 0.5 })
            foreach ($height in $heights) {
                if ($height -lt $minimum - 0.5 -or $height -gt $maximum) {
                    throw "$layout/$density representative height must be $minimum-$maximum DIPs, got $height."
                }
            }
            foreach ($row in ($rows | Select-Object -First 4)) {
                $rowBounds = $row.Current.BoundingRectangle
                foreach ($child in $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition)) {
                    if ($child.Current.IsOffscreen) { continue }
                    $childBounds = $child.Current.BoundingRectangle
                    if ($childBounds.Height -gt 0 -and
                        ($childBounds.Top -lt $rowBounds.Top - 1 -or $childBounds.Bottom -gt $rowBounds.Bottom + 1)) {
                        throw "$layout/$density clips row content '$($child.Current.Name)'."
                    }
                }
            }
            $selected = $rows[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($density -eq "Compact" -and -not $selected.Current.IsSelected) {
                throw "Changing density must preserve the selected device."
            }
            $selected.Select()
            $null = Save-DeviceCapture "devices-density-$layout-$density"
        }
        if ($measurements[$layout].Compact.visibleRows -le $measurements[$layout].Standard.visibleRows) {
            throw "$layout Compact must display more complete rows at an identical viewport."
        }
        if ($measurements[$layout].Compact.headerHeight -ge $measurements[$layout].Standard.headerHeight) {
            throw "Column titles must retain the existing density distinction."
        }
    }
    $measurements | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $ScreenshotDirectory "devices-density-measurements.json")
    Select-DevicePage Settings
    Set-DeviceFilterChoice CompactRowsSwitch Standard
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Select-DevicePage DevicesNavItem
    Set-DeviceWidth 1280
}

function Test-MergedAssignments {
    Set-DeviceWidth 1880
    Select-DevicePage Settings
    Set-ColumnOption "Combine Person and Room" $true
    Select-DevicePage DevicesNavItem
    $initialRow = @(Get-DeviceRows)[0]
    $empty = Get-VisibleDeviceChild $initialRow AutomationId MergedAssignmentsEmpty
    if (-not $empty) { throw "Unassigned merged cell must show a single dash." }
    $emptyBounds = $empty.Current.BoundingRectangle
    $centerX = $emptyBounds.Left + $emptyBounds.Width / 2
    foreach ($case in @(
        @{ Person = $true; Room = $false },
        @{ Person = $false; Room = $true },
        @{ Person = $true; Room = $true },
        @{ Person = $false; Room = $false }
    )) {
        $row = @(Get-DeviceRows)[0]
        $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $row.SetFocus()
        [DevicesReviewInput]::Tap(0x0D)
        Start-Sleep -Milliseconds 250
        $scroll = (Find-DeviceElement DeviceDetailsScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
        Set-DeviceFilterChoice DevicePersonPicker $(if ($case.Person) { "UI · UI review person" } else { "Unassigned" })
        Set-DeviceFilterChoice DeviceRoomPicker $(if ($case.Room) { "UI · UI review room" } else { "Unassigned" })
        Select-DevicePage DevicesNavItem
        $row = @(Get-DeviceRows)[0]
        $person = Get-VisibleDeviceChild $row AutomationId MergedPersonValue
        $room = Get-VisibleDeviceChild $row AutomationId MergedRoomValue
        $empty = Get-VisibleDeviceChild $row AutomationId MergedAssignmentsEmpty
        if ([bool]$person -ne $case.Person -or [bool]$room -ne $case.Room -or
            [bool]$empty -ne (-not $case.Person -and -not $case.Room)) {
            throw "Merged assignments must omit missing lines and show one dash only when both are absent."
        }
        $bounds = @()
        foreach ($entry in @(@($person, "Person: UI review person"), @($room, "Room: UI review room"))) {
            if (-not $entry[0]) { continue }
            if ($entry[0].Current.Name -ne $entry[1]) { throw "Assignment must announce its category and full name." }
            $b = $entry[0].Current.BoundingRectangle
            $bounds += $b
            # The centered line includes a 12-DIP icon and a 4-DIP gap before the value.
            if ([Math]::Abs($b.Left + $b.Width / 2 - 8 * $scale - $centerX) -gt 2 * $scale) {
                throw "Each icon/value line must be horizontally centered."
            }
        }
        if ($empty) { $bounds += $empty.Current.BoundingRectangle }
        $top = ($bounds | Measure-Object Top -Minimum).Minimum
        $bottom = ($bounds | Measure-Object Bottom -Maximum).Maximum
        $rb = $row.Current.BoundingRectangle
        if ([Math]::Abs(($top + $bottom) / 2 - ($rb.Top + $rb.Bottom) / 2) -gt 2 * $scale) {
            throw "Merged assignment contents must be vertically centered."
        }
        if ($person -and $room -and $person.Current.BoundingRectangle.Bottom -gt $room.Current.BoundingRectangle.Top) {
            throw "Two assignments must occupy separate stacked lines."
        }
        if ($rb.Height / $scale -gt 48) { throw "Merged assignments must not increase the row envelope." }
        foreach ($entry in @(@($person, "Person: UI review person"), @($room, "Room: UI review room"))) {
            if ($entry[0]) {
                Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
                $null = Assert-CellPreview $entry[0] $entry[1] ""
            }
        }
        $null = Save-DeviceCapture "devices-assignments-$($case.Person)-$($case.Room)"
    }
    Select-DevicePage Settings
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Select-DevicePage DevicesNavItem
    Set-DeviceWidth 1280
}
