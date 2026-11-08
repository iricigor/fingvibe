function Set-SecondaryFiltersExpanded([bool] $Expanded) {
    $toggle = (Find-DeviceElement FilterExpander).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $Expanded) {
        $toggle.Toggle()
        Start-Sleep -Milliseconds 150
    }
    $expected = if ($Expanded) { "Expanded" } else { "Collapsed" }
    if ((Find-DeviceElement FilterExpander).Current.HelpText -ne $expected) {
        throw "The funnel must expose its $expected state."
    }
}

function Open-DeviceFilter([string] $Id) {
    if ($Id -ne "InventoryStatusFilter") { Set-SecondaryFiltersExpanded $true }
    (Find-DeviceElement $Id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 250
    return Find-DeviceElement "${Id}Choices"
}

function Set-DeviceFilterChecks([string] $Id, [string[]] $Labels) {
    $panel = Open-DeviceFilter $Id
    $checks = $panel.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::CheckBox))
    foreach ($label in $Labels) {
        if ($label -notin @($checks | ForEach-Object { $_.Current.Name })) {
            throw "Checkbox '$label' was not found in '$Id'."
        }
    }
    foreach ($check in $checks) {
        $toggle = $check.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne
            ($check.Current.Name -in $Labels)) { $toggle.Toggle() }
        if ($panel.Current.IsOffscreen) { throw "Checkbox selections must not close '$Id'." }
    }
    [DevicesReviewInput]::Tap(0x1B)
    Start-Sleep -Milliseconds 200
}

function Set-DeviceFilterChoice([string] $Id, [string] $Label) {
    if ($Id -eq "CompactRowsSwitch") {
        if ($Label -notin @("Standard", "Compact")) { throw "Unknown density '$Label'." }
        $toggle = (Find-DeviceElement $Id).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne ($Label -eq "Compact")) {
            $toggle.Toggle()
        }
        return
    }
    if ($Id -in @("InventoryStatusFilter", "TypeFilter", "OperatingSystemFilter", "VendorFilter",
        "PersonFilter", "RoomFilter", "PortsFilter", "UsageCategoryFilter")) {
        $labels = if ($Label -like "All *") { @() } else { @($Label) }
        Set-DeviceFilterChecks $Id $labels
        return
    }
    $picker = Find-DeviceElement $Id
    $expand = $picker.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    Start-Sleep -Milliseconds 150
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Label),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
    $choice = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $choice) { throw "Filter option '$Label' was not found in '$Id'." }
    $choice.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    if ($expand.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
        $expand.Collapse()
    }
    Start-Sleep -Milliseconds 200
}

function Assert-FilterPresentation([string] $Id, [string] $Category, [string] $Value = "") {
    $picker = Find-DeviceElement $Id
    $expected = if ($Value) { $Value } else { "All" }
    if ($picker.Current.Name -ne "${Category}: $expected") {
        throw "Native '$Id' must announce its category and selections; expected '${Category}: $expected'."
    }
    $null = Save-DeviceCapture "devices-filter-$Category-$expected"
}

function Assert-ClearFiltersVisible([bool] $Expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $link = Get-VisibleDeviceChild $root AutomationId ClearFiltersLink
        if ([bool]$link -eq $Expected) {
            if ($Expected) {
                $clearBounds = $link.Current.BoundingRectangle
                $funnelBounds = (Find-DeviceElement FilterExpander).Current.BoundingRectangle
                if ([Math]::Abs($clearBounds.Left - $funnelBounds.Right) -gt 2 * $scale -or
                    [Math]::Abs($clearBounds.Top - $funnelBounds.Top) -gt $scale) {
                    throw "Clear filters must be the connected right-hand segment of the funnel control."
                }
            }
            return
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Clear filters visibility must match active restrictions; expected visible=$Expected."
}

function Clear-DeviceFilters {
    $expanded = (Find-DeviceElement FilterExpander).Current.HelpText -eq "Expanded"
    (Find-DeviceElement ClearFiltersLink).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 200
    Assert-ClearFiltersVisible $false
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices") {
        throw "Clear filters must restore the full inventory."
    }
    foreach ($id in @("OnlineChip", "OfflineChip", "UnknownChip", "FingOnlyChip")) {
        if ((Find-DeviceElement $id).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::Off) { throw "Clear filters left '$id' active." }
    }
    if ((Find-DeviceElement FilterExpander).Current.Name -notlike "*0 active categories") {
        throw "Clear filters must clear hidden secondary categories."
    }
    if (((Find-DeviceElement FilterExpander).Current.HelpText -eq "Expanded") -ne $expanded) {
        throw "Clear filters must not change the secondary row's visibility."
    }
    Set-SecondaryFiltersExpanded $true
    foreach ($entry in @(@("TypeFilter", "Device type"), @("OperatingSystemFilter", "Operating system"),
        @("VendorFilter", "Vendor"), @("PersonFilter", "Person"), @("RoomFilter", "Room"), @("UsageCategoryFilter", "Usage category"))) {
        if ((Find-DeviceElement $entry[0]).Current.Name -ne "$($entry[1]): All") {
            throw "Clear filters left '$($entry[0])' restricted."
        }
    }
    if ((Find-DeviceElement PortsFilter).Current.Name -ne "Ports: All") { throw "Ports remained restricted." }
    Set-SecondaryFiltersExpanded $expanded
}

function Test-ExpandableDeviceFilters {
    if ((Find-DeviceElement FilterExpander).Current.HelpText -ne "Collapsed" -or
        (Get-VisibleDeviceChild $root AutomationId TypeFilter)) {
        throw "Secondary filters must start collapsed."
    }
    Set-DeviceFilterChecks InventoryStatusFilter @("Online", "Offline")
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices" -or
        (Find-DeviceElement FilterExpander).Current.Name -notlike "*0 active categories") {
        throw "Multiple statuses use OR and do not contribute to the secondary count."
    }
    Set-DeviceFilterChecks TypeFilter @("Computer", "Phone")
    Set-DeviceFilterChecks OperatingSystemFilter @("Android", "Unknown")
    Set-DeviceFilterChecks VendorFilter @("Example Devices",
        "Example Devices with a deliberately long manufacturer name for hover inspection")
    Set-DeviceFilterChecks PersonFilter @("Unassigned", "UI · UI review person")
    Set-DeviceFilterChecks RoomFilter @("Unassigned", "UI · UI review room")
    Set-DeviceFilterChoice PortsFilter "With open ports"
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 1 of 80 devices" -or
        (Find-DeviceElement FilterExpander).Current.Name -notlike "*6 active categories") {
        throw "Multi-select categories must combine with AND and count categories rather than selections."
    }
    Set-SecondaryFiltersExpanded $false
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 1 of 80 devices" -or
        (Find-DeviceElement FilterExpander).Current.Name -notlike "*6 active categories" -or
        (Get-VisibleDeviceChild $root AutomationId TypeFilter)) {
        throw "Collapsing filters must hide the row without clearing its restrictions or count."
    }
    $null = Save-DeviceCapture "devices-collapsed-active-filters"
    Clear-DeviceFilters
    Set-SecondaryFiltersExpanded $true
    Set-DeviceFilterChecks TypeFilter @("Unknown", "Computer")
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices") {
        throw "Unknown can combine with a concrete device type."
    }
    Set-DeviceFilterChecks TypeFilter @()
    Assert-ClearFiltersVisible $false
}

function Test-FilterChips {
    Assert-ClearFiltersVisible $false
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    foreach ($apply in @(
        { $search.SetValue("Kitchen") },
        { Set-DeviceFilterChoice InventoryStatusFilter Unknown },
        { Set-DeviceFilterChoice PersonFilter Unassigned },
        { Set-DeviceFilterChoice RoomFilter Unassigned },
        { Set-DeviceFilterChoice UsageCategoryFilter Unclassified },
        { Set-DeviceFilterChoice PortsFilter "With open ports" }
    )) {
        & $apply
        Assert-ClearFiltersVisible $true
        Clear-DeviceFilters
    }
    $search.SetValue("Kitchen")
    Set-DeviceFilterChoice PersonFilter Unassigned
    Set-DeviceFilterChoice RoomFilter Unassigned
    Set-DeviceFilterChoice PortsFilter "With open ports"
    foreach ($case in @(@("OnlineChip", "Online", "1"), @("OfflineChip", "Offline", "0"),
        @("UnknownChip", "Unknown", "0"), @("FingOnlyChip", "Fing Only", "0"))) {
        Set-DeviceFilterChoice InventoryStatusFilter "All statuses"
        $chip = Find-DeviceElement $case[0]
        if ($case[0] -in @("OnlineChip", "OfflineChip")) {
            $chip.SetFocus()
            [DevicesReviewInput]::Tap(0x20)
        }
        else { $chip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle() }
        Start-Sleep -Milliseconds 200
        if ((Find-DeviceElement InventoryStatusFilter).Current.Name -ne "Status: $($case[1])") {
            throw "Summary chip/dropdown synchronization failed."
        }
        if ($chip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::On) { throw "Summary chip must expose its selected state." }
        if ($search.Current.Value -ne "Kitchen" -or
            (Find-DeviceElement ResultCountText).Current.Name -ne "Showing $($case[2]) of 80 devices") {
            throw "Summary shortcuts must retain other restrictions, including zero-match results."
        }
        if ((Find-DeviceElement OnlineChip).Current.Name -ne "80 Online") {
            throw "Summary counts must retain their full-inventory meaning."
        }
    }
    Set-DeviceFilterChoice InventoryStatusFilter Online
    (Find-DeviceElement OfflineChip).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    if ((Find-DeviceElement InventoryStatusFilter).Current.Name -ne "Status: Online, Offline") {
        throw "Summary chips must add statuses without replacing other selections."
    }
    if ((Find-DeviceElement OnlineChip).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
        [System.Windows.Automation.ToggleState]::On) { throw "Dropdown must select the matching chip." }
    Clear-DeviceFilters
    $null = Save-DeviceCapture "devices-status-chips-cleared"
}
