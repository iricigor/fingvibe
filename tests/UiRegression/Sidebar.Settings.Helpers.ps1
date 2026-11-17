function Test-SettingsDisclosure {
    Select-SidebarPage Settings "Appearance preferences"
    foreach ($id in @("AppearanceSection", "DevicesSection", "ScheduledScansSection")) {
        $element = Find-SidebarElement AutomationId $id
        $pattern = $element.GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        if ($pattern.Current.ExpandCollapseState -ne "Collapsed") { throw "$id must start collapsed." }
        $summaryId = $id.Replace("Section", "Summary")
        if (-not $element.Current.HelpText.Contains((Find-SidebarElement AutomationId $summaryId).Current.Name)) {
            throw "$id must expose its current summary to assistive technology while collapsed."
        }
    }
    Save-SidebarAppearance "settings-collapsed"
    Focus-SidebarWindow
    $section = Find-SidebarElement AutomationId DevicesSection
    $section.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x20)
    $null = Find-SidebarElement AutomationId CompactRowsSwitch
    $summaryBefore = (Find-SidebarElement AutomationId DevicesSummary).Current.Name
    $toggle = (Find-SidebarElement AutomationId CompactRowsSwitch).GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern)
    $toggle.Toggle()
    $null = Wait-UiRegressionState {
        (Find-SidebarElement AutomationId DevicesSummary).Current.Name -ne $summaryBefore
    } "live Devices preference summary"
    $summaryChanged = (Find-SidebarElement AutomationId DevicesSummary).Current.Name
    $aboutCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "AboutSettingsButton")
    $null = Show-UiRegressionScrollTargets -Description "Settings About row" -AlignBottom `
        -GetViewport { Find-SidebarElement AutomationId SettingsPage } -GetWindow { $root } -GetTargets {
            $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $aboutCondition)
        }
    $row = Find-SidebarElement AutomationId AboutSettingsButton
    $row.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Find-SidebarElement Name "Back to Settings"
    $settingsItem = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, "Settings"),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem)))
    if (-not $settingsItem.GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) {
        throw "About must keep Settings selected."
    }
    (Find-SidebarElement Name "Back to Settings").GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState {
        (Find-SidebarElement AutomationId AboutSettingsButton).Current.HasKeyboardFocus
    } "About row focus after Back"
    Select-SidebarPage "People & rooms" "Search people and rooms"
    Select-SidebarPage Settings "Appearance preferences"
    if ((Find-SidebarElement AutomationId DevicesSection).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne "Expanded" -or
        (Find-SidebarElement AutomationId DevicesSummary).Current.Name -ne $summaryChanged) {
        throw "Navigation must retain expansion state and the actual preference summary."
    }
    $pattern = (Find-SidebarElement AutomationId DevicesSection).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $pattern.Collapse()
    if ((Find-SidebarElement AutomationId DevicesSummary).Current.Name -ne $summaryChanged) {
        throw "Collapsing must preserve the edited preference."
    }
    $pattern.Expand()
    (Find-SidebarElement AutomationId CompactRowsSwitch).GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    $pattern.Collapse()
    $null = Wait-UiRegressionState {
        (Find-SidebarElement AutomationId DevicesSummary).Current.Name -eq $summaryBefore
    } "collapsing retains restored preferences"
    $header = (Find-SidebarElement AutomationId AppearanceSection).Current.BoundingRectangle
    [SidebarReviewKeyboard]::PressAt([int]($header.Left + 40 * $scale), [int]($header.Top + $header.Height / 2))
    [SidebarReviewKeyboard]::Release()
    $null = Find-SidebarElement AutomationId ModePicker
    Stop-SidebarApp
    Start-SidebarApp
    Set-SidebarWindowWidth $expandedWidth
    Select-SidebarPage Settings "Appearance preferences"
    foreach ($id in @("AppearanceSection", "DevicesSection", "ScheduledScansSection")) {
        if ((Find-SidebarElement AutomationId $id).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne "Collapsed") {
            throw "$id expansion must reset after restart."
        }
    }
    if ($env:CI -eq "true") {
        $settings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]::new()
        $originalScale = $settings.TextScaleFactor
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
        $originalValue = $key.GetValue('TextScaleFactor', $null)
        $originalKind = if ($null -ne $originalValue) { $key.GetValueKind('TextScaleFactor') } else { $null }
        $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
        $failed = $true
        try {
            Stop-SidebarApp
            $key.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
            [SidebarReviewKeyboard]::NotifyTextScaleChanged()
            $null = Wait-UiRegressionState {
                [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01
            } "Settings effective Windows text scale of 200 percent"
            [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
            if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) { throw "High contrast did not activate." }
            Start-SidebarApp
            Set-SidebarWindowWidth $expandedWidth
            Select-SidebarPage Settings "Appearance preferences"
            foreach ($width in @(640, 480)) {
                Set-SidebarWindowWidth $width
                foreach ($id in @("AppearanceSummary", "DevicesSummary", "ScheduledScansSummary", "AboutSettingsButton")) {
                    $summaryCondition = [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
                    $null = Show-UiRegressionScrollTargets -Description "scaled Settings $id" `
                        -GetViewport { Find-SidebarElement AutomationId SettingsPage } -GetWindow { $root } -GetTargets {
                            $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $summaryCondition)
                        }
                    $element = Find-SidebarElement AutomationId $id
                    if ([string]::IsNullOrWhiteSpace($element.Current.Name) -or
                        -not (Test-UiRegressionElementWithin $element (Find-SidebarElement AutomationId SettingsPage) $root)) {
                        throw "Settings summary '$id' is empty or clipped at $width with enlarged text."
                    }
                }
                Save-SidebarAppearance "settings-collapsed-text-200-high-contrast-$width" -MinimumWidth $width
            }
            $failed = $false
        }
        finally {
            Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
                { Stop-SidebarApp },
                {
                    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
                    if ($null -eq $originalValue) { $key.DeleteValue('TextScaleFactor', $false) }
                    else { $key.SetValue('TextScaleFactor', $originalValue, $originalKind) }
                    [SidebarReviewKeyboard]::NotifyTextScaleChanged()
                    $null = Wait-UiRegressionState { [Math]::Abs($settings.TextScaleFactor - $originalScale) -lt 0.01 } "restored Settings text scale"
                },
                { $key.Dispose() },
                { Start-SidebarApp; Set-SidebarWindowWidth $expandedWidth })
        }
    }
    Write-Host "Settings collapsed defaults, keyboard/pointer disclosure, live summary, retained navigation and restart reset passed."
}

function Test-SettingsLayout {
    Set-SidebarWindowWidth $expandedWidth
    Select-SidebarPage Settings "Window backdrop"
    $ribbon = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "BuildRibbon"))
    if ($ribbon -and -not $ribbon.Current.IsOffscreen) {
        $ribbon.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 250
    }
    Set-UiReviewAppearanceChoice -Root $root -Picker BackdropPicker -Choice Solid
    foreach ($style in @("Standard", "Warm", "Colorful")) {
        Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice Light
        Set-UiReviewAppearanceChoice -Root $root -Picker ThemePicker -Choice $style
        Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice Dark
        $expected = if ($style -eq "Warm") { "True Black (OLED)" } else { $style }
        $picker = Find-SidebarElement AutomationId ThemePicker
        $selection = $picker.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
        $actual = $selection.Current.GetSelection()[0].Current.Name
        Save-SidebarAppearance "settings-mode-$style"
        if ($actual -ne $expected) {
            throw "Mode switching did not preserve/map theme '$style' to '$expected'; got '$actual'."
        }
        Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice Light
        if ($selection.Current.GetSelection()[0].Current.Name -ne $style) {
            throw "Mode switching did not restore theme '$style'."
        }
    }
    foreach ($theme in $UiReviewAppearanceThemes) {
        Set-UiReviewTheme -Root $root -Theme $theme
        $mode = if ($theme -match 'Dark|OLED') { "Dark" } else { "Light" }
        if ((Find-SidebarElement AutomationId AppearanceSummary).Current.Name -notlike "$mode mode*Solid backdrop*") {
            throw "Appearance summary must reflect the selected mode and backdrop."
        }
        Show-SettingsSection DevicesSettingsHeading
        $footer = Find-SidebarElement AutomationId AppearanceSaveStatus
        if ($footer.Current.Name -ne "Appearance changes apply immediately and save automatically, with material effects depending on Windows transparency settings.") {
            throw "Normal Appearance feedback must be one consolidated sentence."
        }
        foreach ($id in @("CompactRowsSwitch", "EnlargedCellPreviews")) {
            $switch = Find-SidebarElement AutomationId $id
            $toggle = $switch.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            $original = $toggle.Current.ToggleState
            $switch.SetFocus()
            [SidebarReviewKeyboard]::Tap(0x20)
            Start-Sleep -Milliseconds 200
            if ($toggle.Current.ToggleState -eq $original) { throw "$id must toggle with Space." }
            if ($theme -eq "Standard Dark") { Save-SidebarAppearance "settings-$id-toggled" }
            $toggle.Toggle()
            if ($toggle.Current.ToggleState -ne $original) { throw "$id must restore through native TogglePattern." }
        }
        Save-SidebarAppearance "settings-$theme"
        $scroll = (Find-SidebarElement AutomationId SettingsPage).GetCurrentPattern(
            [System.Windows.Automation.ScrollPattern]::Pattern)
        Show-SettingsSection VisibleColumnsHeading
        Start-Sleep -Milliseconds 200
        $null = Find-SidebarElement AutomationId VisibleColumnsHeading
        $null = Find-SidebarElement AutomationId CombinedColumnsHeading
        Save-SidebarAppearance "settings-grouped-columns-$theme"
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    }
    foreach ($width in @($expandedWidth, 640, 480)) {
        Set-SidebarWindowWidth $width
        $scroll = (Find-SidebarElement AutomationId SettingsPage).GetCurrentPattern(
            [System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
        Start-Sleep -Milliseconds 200
        $pickers = @("ModePicker", "ThemePicker", "BackdropPicker") |
            ForEach-Object { (Find-SidebarElement AutomationId $_).Current.BoundingRectangle }
        $inline = $width -eq $expandedWidth
        if ($inline) {
            if ([Math]::Abs($pickers[0].Top - $pickers[2].Top) -gt 2 * $scale -or
                $pickers[0].Right -gt $pickers[1].Left -or $pickers[1].Right -gt $pickers[2].Left) {
                throw "Appearance selectors must share a non-overlapping row at $width."
            }
        }
        elseif ($pickers[0].Bottom -gt $pickers[1].Top -or $pickers[1].Bottom -gt $pickers[2].Top) {
            throw "Appearance selectors must stack without overlap at $width."
        }
        $reset = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "ResetColumnsButton"))
        if (-not $reset) { throw "Reset columns is missing." }
        Show-SettingsSection DevicesSettingsHeading
        $heading = (Find-SidebarElement AutomationId DevicesSettingsHeading).Current.BoundingRectangle
        $compact = (Find-SidebarElement AutomationId CompactRowsSwitch).Current.BoundingRectangle
        $hover = (Find-SidebarElement AutomationId EnlargedCellPreviews).Current.BoundingRectangle
        if ($heading.Bottom -gt $compact.Top) { throw "Preferences must follow the Devices page title." }
        if ($width -ge 640) {
            if ([Math]::Abs($compact.Top - $hover.Top) -gt 2 * $scale -or $compact.Right -gt $hover.Left) {
                throw "Devices switches must share a non-overlapping row at $width."
            }
        } elseif ($compact.Bottom -gt $hover.Top) {
            throw "Devices switches must stack at narrow widths."
        }
        if ($width -ge 640) { Save-SidebarAppearance "settings-switches-$width" }
        Show-SettingsSection VisibleColumnsHeading
        Start-Sleep -Milliseconds 200
        $choices = Find-SidebarElement AutomationId SettingsPage
        $headers = @("Name", "IP address", "Vendor", "Device type", "MAC address", "Open ports",
            "Status", "Response", "OS", "Usage category", "Person", "Room", "Last seen")
        $checkboxes = @($choices.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::CheckBox)) |
            Where-Object { $_.Current.Name -in $headers })
        if ($checkboxes.Count -ne $headers.Count) { throw "Expected all thirteen column choices at $width." }
        $columns = if ($inline) { 3 } elseif ($width -eq 640) { 2 } else { 1 }
        for ($index = 0; $index -lt $checkboxes.Count; $index++) {
            $box = $checkboxes[$index]
            if ($box.Current.Name -ne $headers[$index]) { throw "Column order changed at $width." }
            $bounds = $box.Current.BoundingRectangle
            $rowStart = $checkboxes[$index - $index % $columns].Current.BoundingRectangle
            if ([Math]::Abs($bounds.Top - $rowStart.Top) -gt 2 * $scale) {
                throw "Expected $columns columns at $width."
            }
            if ($index -ge $columns -and $bounds.Top -lt $checkboxes[$index - $columns].Current.BoundingRectangle.Bottom) {
                throw "Column choices overlap vertically at $width."
            }
            if ($index % $columns -gt 0 -and $bounds.Left -lt $checkboxes[$index - 1].Current.BoundingRectangle.Right) {
                throw "Column choices overlap horizontally at $width."
            }
        }
        foreach ($mandatory in @($checkboxes[0], $checkboxes[1])) {
            if ($mandatory.Current.IsEnabled -or $mandatory.GetCurrentPattern(
                    [System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
                    [System.Windows.Automation.ToggleState]::On) {
                throw "Name and IP address must remain checked and mandatory."
            }
            if ($inline) {
                $visibleHeading = (Find-SidebarElement AutomationId VisibleColumnsHeading).Current.BoundingRectangle
                $combinedHeading = (Find-SidebarElement AutomationId CombinedColumnsHeading).Current.BoundingRectangle
                $description = (Find-SidebarElement AutomationId CombinedColumnsDescription).Current.BoundingRectangle
                $combinations = @("CombineNameType", "CombineAddresses", "CombineStatusResponse", "CombinePersonRoom", "CombineVendorOs") |
                    ForEach-Object { (Find-SidebarElement AutomationId $_).Current.BoundingRectangle }
                if ($visibleHeading.Bottom -gt $checkboxes[0].Current.BoundingRectangle.Top -or
                    $checkboxes[-1].Current.BoundingRectangle.Bottom -ge $combinedHeading.Top -or
                    $combinedHeading.Bottom -gt $description.Top -or $description.Bottom -gt $combinations[0].Top) {
                    throw "Visibility and combination controls must have distinct, correctly ordered sections."
                }
                for ($index = 0; $index -lt $combinations.Count; $index++) {
                    $column = $index % 3
                    if ([Math]::Abs($combinations[$index].Left - $checkboxes[$column].Current.BoundingRectangle.Left) -gt 2 * $scale -or
                        [Math]::Abs($combinations[$index].Top - $combinations[$index - $column].Top) -gt 2 * $scale -or
                        ($column -gt 0 -and $combinations[$index - 1].Right -gt $combinations[$index].Left) -or
                        ($index -ge 3 -and $combinations[$index - 3].Bottom -gt $combinations[$index].Top)) {
                        throw "Combination choices must align with the visible three-column grid."
                    }
                }
            }
        }
        if ($width -ge 640) { Save-SidebarAppearance "settings-layout-$width" }
    }
    Set-SidebarWindowWidth $expandedWidth
    if ((Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle.Width / $scale -lt 80) {
        Switch-SidebarPane
    }
    $vendor = $checkboxes[2]
    $toggle = $vendor.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $toggle.Toggle()
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw "Column visibility did not update."
    }
    Show-SettingsSection DevicesSettingsHeading
    $density = (Find-SidebarElement AutomationId CompactRowsSwitch).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $hoverPreference = (Find-SidebarElement AutomationId EnlargedCellPreviews).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $densityBefore = $density.Current.ToggleState
    $hoverBefore = $hoverPreference.Current.ToggleState
    Show-SettingsSection ResetColumnsButton
    (Find-SidebarElement AutomationId ResetColumnsButton).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw "Reset columns did not restore visibility."
    }
    if ($density.Current.ToggleState -ne $densityBefore -or $hoverPreference.Current.ToggleState -ne $hoverBefore) {
        throw "Reset columns must preserve both Devices preferences."
    }
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Set-UiReviewTheme -Root $root -Theme "Standard Dark"
    Select-SidebarPage "People & rooms" "Search people and rooms"
    Write-Host "Settings mode/theme mapping, six palettes, responsive bounds, mandatory IP, and column reset passed."
}
