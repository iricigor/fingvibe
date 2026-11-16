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
    $displayCategory = switch ($Category) {
        "Device type" { "Type" }
        "Operating system" { "OS" }
        "Usage category" { "Usage" }
        default { $Category }
    }
    $text = (Find-DeviceElement "${Id}Label").GetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1).Trim()
    $expectedText = if ($Value) { "$displayCategory | $Value" } else { $displayCategory }
    if ($text -ne $expectedText -or -not $picker.Current.IsEnabled) {
        throw "'$Id' must render '$expectedText' without disabling the filter."
    }
    $null = Save-DeviceCapture "devices-filter-$Category-$expected"
}

function Get-FilterLabelColor([string] $Id) {
    $range = (Find-DeviceElement "${Id}Label").GetCurrentPattern(
        [System.Windows.Automation.TextPattern]::Pattern).DocumentRange
    $color = $range.GetAttributeValue([System.Windows.Automation.TextPattern]::ForegroundColorAttribute)
    if ($color -isnot [int]) { throw "'$Id' must expose its rendered label foreground." }
    return $color
}

function Assert-StatusChoiceIndicators([string] $Theme, [switch] $HighContrast) {
    $picker = Find-DeviceElement InventoryStatusFilter
    $picker.SetFocus()
    [DevicesReviewInput]::Tap(0x20)
    $panel = Find-DeviceElement InventoryStatusFilterChoices
    $capture = Save-DeviceCapture "devices-status-choices-$Theme"
    $window = Get-UiReviewWindowBounds $windowHandle
    $bitmap = [System.Drawing.Bitmap]::new($capture)
    try {
        $colors = if ($Theme -eq "Standard Light") {
            @("#16803D", "#C42B1C", "#6B7280", "#2563EB")
        } else { @("#4ADE80", "#FF8080", "#A6ABB3", "#70ADFF") }
        $names = @("Online", "Offline", "Unknown", "Fing Only")
        foreach ($name in @($names + "Any")) {
            $check = $panel.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.AndCondition]::new(
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::NameProperty, $name),
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::CheckBox)))
            if (-not $check -or $check.Current.IsOffscreen -or -not $check.Current.IsEnabled) {
                throw "Status choice '$name' must remain a visible, enabled checkbox in $Theme."
            }
            $null = $check.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            $text = $check.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text))
            if (-not $text) { throw "Status choice '$name' lost its readable label in $Theme." }
            $bounds = $text.Current.BoundingRectangle
            if (-not $check.Current.BoundingRectangle.Contains($bounds)) {
                throw "Status choice '$name' clips its label in $Theme."
            }
            if ($HighContrast) { continue }
            $centerX = $bounds.Left - $window.Left - 14 * $scale
            $centerY = $bounds.Top - $window.Top + $bounds.Height / 2
            $samples = @(@(2, -2, 0), @(2, 2, 1), @(-2, 2, 2), @(-2, -2, 3))
            if ($name -ne "Any") { $samples = ,@(0, 0, [Array]::IndexOf($names, $name)) }
            foreach ($sample in $samples) {
                $actual = $bitmap.GetPixel([int]($centerX + $sample[0] * $scale),
                    [int]($centerY + $sample[1] * $scale))
                $expected = [System.Drawing.ColorTranslator]::FromHtml($colors[$sample[2]])
                if ($actual.ToArgb() -ne $expected.ToArgb()) {
                    throw "Status '$name' indicator has incorrect rendered color in $Theme; expected $expected, got $actual."
                }
            }
        }
    }
    finally {
        $bitmap.Dispose()
        [DevicesReviewInput]::Tap(0x1B)
    }
}

function Test-DeviceFilterVisualStates {
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        Select-DevicePage Settings
        Set-UiReviewTheme -Root $root -Theme $theme
        Select-DevicePage DevicesNavItem
        Set-SecondaryFiltersExpanded $true
        foreach ($entry in @(@("TypeFilter", "Device type"), @("OperatingSystemFilter", "Operating system"),
            @("UsageCategoryFilter", "Usage category"), @("PortsFilter", "Ports"))) {
            Assert-FilterPresentation $entry[0] $entry[1]
        }
        Assert-StatusChoiceIndicators $theme
        $inactive = Get-FilterLabelColor InventoryStatusFilter
        Set-DeviceFilterChoice InventoryStatusFilter Online
        $active = Get-FilterLabelColor InventoryStatusFilter
        if ($active -eq $inactive) { throw "Active and inactive filter text must differ in $theme." }
        Assert-FilterPresentation InventoryStatusFilter Status Online
        Set-DeviceFilterChoice InventoryStatusFilter Any
        if ((Get-FilterLabelColor InventoryStatusFilter) -ne $active) {
            throw "Restrictive Status Any must use active text, even when it matches the whole fixture."
        }
        Assert-FilterPresentation InventoryStatusFilter Status Any
        Clear-DeviceFilters
        if ((Get-FilterLabelColor InventoryStatusFilter) -ne $inactive) {
            throw "Clear filters must restore quiet Status text in $theme."
        }
        $portsInactive = Get-FilterLabelColor PortsFilter
        Set-DeviceFilterChoice PortsFilter "With open ports"
        if ((Get-FilterLabelColor PortsFilter) -eq $portsInactive) { throw "Ports must also emphasize active text." }
        Clear-DeviceFilters
        if ((Get-FilterLabelColor PortsFilter) -ne $portsInactive) { throw "Clearing Ports must restore inactive text." }
        $picker = Find-DeviceElement InventoryStatusFilter
        $picker.SetFocus()
        if (-not $picker.Current.HasKeyboardFocus) { throw "Inactive Status must retain keyboard focus in $theme." }
        $null = Save-DeviceCapture "devices-filter-focus-$theme"
        Move-ToDeviceElement $picker
        $null = Save-DeviceCapture "devices-filter-hover-$theme" -KeepPointer
    }
    if ($env:GITHUB_ACTIONS -eq "true" -and $env:RUNNER_OS -eq "Windows") {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DeviceFilterReviewContrast {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct HIGHCONTRAST { public uint Size; public uint Flags; public IntPtr Scheme; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint size, ref HIGHCONTRAST value, uint flags);
    public static uint Get() {
        var value = new HIGHCONTRAST { Size = (uint)Marshal.SizeOf<HIGHCONTRAST>() };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }
    public static void Set(uint flags) {
        var value = new HIGHCONTRAST { Size = (uint)Marshal.SizeOf<HIGHCONTRAST>(), Flags = flags };
        if (!SystemParametersInfo(0x0043, value.Size, ref value, 2))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
        $originalColor = Get-FilterLabelColor InventoryStatusFilter
        $flags = [DeviceFilterReviewContrast]::Get()
        $contrastFailed = $true
        try {
            [DeviceFilterReviewContrast]::Set($flags -bor 1)
            $null = Wait-UiRegressionState -Description "filter high contrast enabled" -Condition {
                ([DeviceFilterReviewContrast]::Get() -band 1) -ne 0
            }
            $systemText = [System.Drawing.SystemColors]::WindowText
            $expectedColor = [int]$systemText.R -bor ([int]$systemText.G -shl 8) -bor ([int]$systemText.B -shl 16)
            $null = Wait-UiRegressionState -Description "filter high-contrast foreground rendered" -Condition {
                (Get-FilterLabelColor InventoryStatusFilter) -eq $expectedColor
            }
            Assert-StatusChoiceIndicators HighContrast -HighContrast
            Set-DeviceFilterChoice InventoryStatusFilter Any
            Assert-FilterPresentation InventoryStatusFilter Status Any
            Clear-DeviceFilters
            $contrastFailed = $false
        }
        finally {
            Invoke-UiRegressionCleanup -PrimaryFailed $contrastFailed -Steps @(
                { [DeviceFilterReviewContrast]::Set($flags) },
                {
                    $null = Wait-UiRegressionState -Description "filter foreground restored after high contrast" -Condition {
                        (Get-FilterLabelColor InventoryStatusFilter) -eq $originalColor
                    }
                })
        }
    }
    else { Write-Host "High-contrast filter evidence requires a disposable GitHub Windows runner; not exercised." }
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
