function Test-SettingsCardHeaders {
    $previous = $null
    $textLeft = $null
    foreach ($card in @(
        @{ Id = 'AppearanceSection'; Title = 'AppearanceSettingsHeading'; Summary = 'AppearanceSummary' },
        @{ Id = 'DevicesSection'; Title = 'DevicesSettingsHeading'; Summary = 'DevicesSummary' },
        @{ Id = 'ScheduledScansSection'; Title = 'ScheduledScansHeading'; Summary = 'ScheduledScansSummary' },
        @{ Id = 'AboutSettingsButton'; Title = 'AboutSettingsHeading'; Summary = 'AboutSummary' }
    )) {
        $element = Find-SidebarElement AutomationId $card.Id
        $title = Find-SidebarElement AutomationId $card.Title
        $summary = Find-SidebarElement AutomationId $card.Summary
        $bounds = $element.Current.BoundingRectangle
        if ($bounds.Height / $scale -lt 66 -or
            -not (Test-UiRegressionElementWithin $title $element $root) -or
            -not (Test-UiRegressionElementWithin $summary $element $root)) {
            throw "$($card.Id) must have a 68-DIP minimum header with contained title and summary."
        }
        if ($null -eq $textLeft) { $textLeft = $title.Current.BoundingRectangle.Left }
        if ([Math]::Abs($title.Current.BoundingRectangle.Left - $textLeft) -gt 2 * $scale -or
            [Math]::Abs($summary.Current.BoundingRectangle.Left - $textLeft) -gt 2 * $scale -or
            $title.Current.BoundingRectangle.Bottom -gt $summary.Current.BoundingRectangle.Top) {
            throw "All Settings cards must align their title/summary columns without overlapping text."
        }
        if ($previous) {
            $gap = ($bounds.Top - $previous.Bottom) / $scale
            if ($gap -lt 4 -or $gap -gt 6 -or
                [Math]::Abs($bounds.Left - $previous.Left) -gt 2 * $scale -or
                [Math]::Abs($bounds.Right - $previous.Right) -gt 2 * $scale) {
                throw "Settings cards must share their edges with 4-6 DIP gaps; got $gap."
            }
        }
        $previous = $bounds
    }
}

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
    Test-SettingsCardHeaders
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
                foreach ($id in @("AppearanceSettingsHeading", "AppearanceSummary", "DevicesSettingsHeading", "DevicesSummary",
                    "ScheduledScansHeading", "ScheduledScansSummary", "AboutSettingsHeading", "AboutSummary")) {
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
            Expand-UiReviewSettingsSection -Root $root -Section AppearanceSection
            foreach ($id in @("ModePicker", "ThemePicker", "BackdropPicker", "AppearanceSaveStatus")) {
                $controlCondition = [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
                $null = Show-UiRegressionScrollTargets -Description "expanded scaled Settings $id" `
                    -GetViewport { Find-SidebarElement AutomationId SettingsPage } -GetWindow { $root } -GetTargets {
                        $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $controlCondition)
                    }
                $element = Find-SidebarElement AutomationId $id
                if (-not (Test-UiRegressionElementWithin $element (Find-SidebarElement AutomationId SettingsPage) $root)) {
                    throw "Expanded Settings '$id' is clipped at 480 DIPs with enlarged text."
                }
            }
            Save-SidebarAppearance "settings-expanded-text-200-high-contrast-480" -MinimumWidth 480
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

function Get-AppearanceShortcut { Find-SidebarElement AutomationId TitleBarAppearanceButton }

function Set-AppearanceShortcutMode([string] $Mode) {
    if ((Get-AppearanceShortcut).Current.Name -ne "Appearance mode: $Mode") {
        (Get-AppearanceShortcut).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    $null = Wait-UiRegressionState -Description "appearance shortcut $Mode mode" -Condition {
        (Get-AppearanceShortcut).Current.Name -eq "Appearance mode: $Mode"
    }
}

function Get-SidebarAppearanceChoices {
    Select-SidebarPage Settings "Window backdrop"
    $choices = @{}
    foreach ($picker in @('ModePicker', 'ThemePicker', 'BackdropPicker')) {
        $selected = (Find-SidebarElement AutomationId $picker).GetCurrentPattern(
            [System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
        if ($selected.Count -ne 1) { throw "Appearance picker '$picker' must have one selected choice." }
        $choices[$picker] = $selected[0].Current.Name
    }
    $choices
}

function Test-AppearanceShortcutPresentation {
    Select-SidebarPage "People & rooms" "Search people and rooms"
    $shortcut = Get-AppearanceShortcut
    if ($shortcut.Current.Name -ne 'Appearance mode: Dark' -or $shortcut.Current.HelpText -notlike 'Switch to Light mode.*') {
        throw "The appearance shortcut must name the current mode and its choices: '$($shortcut.Current.Name)'."
    }
    $bounds = $shortcut.Current.BoundingRectangle
    if ($bounds.Bottom -gt (Find-SidebarElement AutomationId MainNavigation).Current.BoundingRectangle.Top -or
        (Find-SidebarElement AutomationId AppearanceShortcutNavItem -Optional)) {
        throw 'The title-bar appearance shortcut must sit above navigation with no duplicate sidebar shortcut.'
    }
    Focus-SidebarWindow
    $shortcut.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x0D)
    $null = Wait-UiRegressionState -Description 'Enter switches appearance without moving focus' -Condition {
        (Get-AppearanceShortcut).Current.Name -eq 'Appearance mode: Light' -and
            (Get-AppearanceShortcut).Current.HasKeyboardFocus
    }
    if (Find-SidebarElement AutomationId AppearanceShortcutLight -Optional) {
        throw 'Switching appearance must not open a picker popup.'
    }
    Save-SidebarAppearance 'appearance-shortcut-open'
    [SidebarReviewKeyboard]::Tap(0x20)
    $null = Wait-UiRegressionState -Description 'Space restores appearance without moving focus' -Condition {
        (Get-AppearanceShortcut).Current.Name -eq 'Appearance mode: Dark' -and
            (Get-AppearanceShortcut).Current.HasKeyboardFocus
    }

    Switch-SidebarPane
    try {
        if ([Math]::Abs((Get-AppearanceShortcut).Current.BoundingRectangle.Width - $bounds.Width) -gt $scale) {
            throw 'The title-bar appearance shortcut must be independent of the collapsed sidebar.'
        }
        Set-AppearanceShortcutMode Light
        Save-SidebarAppearance 'appearance-shortcut-compact-light'
        Set-AppearanceShortcutMode Dark
    }
    finally { Switch-SidebarPane }

    $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
    try {
        [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
        if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) { throw 'High contrast did not activate.' }
        Start-Sleep -Seconds 2
        Set-AppearanceShortcutMode Light
        if ((Get-AppearanceShortcut).Current.HelpText -notlike '*Windows high contrast colors currently apply*') {
            throw 'The shortcut must announce that Windows high contrast colors currently apply.'
        }
        Save-SidebarAppearance 'appearance-shortcut-high-contrast'
        if ((Get-SidebarAppearanceChoices).ModePicker -ne 'Light') {
            throw 'A mode chosen in high contrast must still update the saved appearance preference.'
        }
        Select-SidebarPage "People & rooms" "Search people and rooms"
        Set-AppearanceShortcutMode Dark
    }
    finally {
        [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
        Start-Sleep -Seconds 2
    }
    Write-Host 'Title-bar shortcut placement, immediate Enter/Space switching, collapsed sidebar and high-contrast behavior passed.'
}

function Test-AppearanceShortcutPersistence {
    $appearancePath = Join-Path $fixtureDirectory 'appearance\appearance.json'
    $savedAppearance = $env:FINGVIBE_UI_REVIEW_APPEARANCE
    Stop-SidebarApp
    try {
        $env:FINGVIBE_UI_REVIEW_APPEARANCE = $appearancePath
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        Set-SidebarAppearance BackdropPicker Acrylic
        foreach ($pair in @(
            @{ Light = 'Standard Light'; Style = 'Standard'; DarkStyle = 'Standard'; LightFile = 'StandardLight'; DarkFile = 'StandardDark' },
            @{ Light = 'Warm Light'; Style = 'Warm'; DarkStyle = 'True Black (OLED)'; LightFile = 'WarmLight'; DarkFile = 'OledDark' },
            @{ Light = 'Colorful Light'; Style = 'Colorful'; DarkStyle = 'Colorful'; LightFile = 'ColorfulLight'; DarkFile = 'ColorfulDark' })) {
            Set-SidebarAppearance ThemePicker $pair.Light
            if ((Get-AppearanceShortcut).Current.Name -ne 'Appearance mode: Light') {
                throw "A Settings change to $($pair.Light) must update the shortcut."
            }
            foreach ($step in @(
                @{ Mode = 'Dark'; Style = $pair.DarkStyle; File = $pair.DarkFile },
                @{ Mode = 'Light'; Style = $pair.Style; File = $pair.LightFile })) {
                Select-SidebarPage "People & rooms" "Search people and rooms"
                Set-AppearanceShortcutMode $step.Mode
                $choices = Get-SidebarAppearanceChoices
                $saved = Get-Content -LiteralPath $appearancePath -Raw | ConvertFrom-Json
                if ($choices.ModePicker -ne $step.Mode -or $choices.ThemePicker -ne $step.Style -or
                    $choices.BackdropPicker -ne 'Acrylic' -or $saved.theme -ne $step.File -or $saved.backdrop -ne 'Acrylic') {
                    throw "Shortcut $($step.Mode) from $($pair.Light) must keep the paired theme and backdrop in Settings and storage."
                }
            }
        }
        Select-SidebarPage "People & rooms" "Search people and rooms"
        Set-AppearanceShortcutMode Dark
        Stop-SidebarApp
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        if ((Get-AppearanceShortcut).Current.Name -ne 'Appearance mode: Dark') { throw 'The shortcut mode must persist across restart.' }
        $choices = Get-SidebarAppearanceChoices
        if ($choices.ModePicker -ne 'Dark' -or $choices.ThemePicker -ne 'Colorful' -or $choices.BackdropPicker -ne 'Acrylic') {
            throw 'Settings must restore the shortcut-saved appearance after restart.'
        }

        $failure = 'Appearance applied, but could not be saved for the next launch.'
        Remove-Item -LiteralPath $appearancePath -Force
        $null = New-Item -ItemType Directory -Path $appearancePath
        Select-SidebarPage "People & rooms" "Search people and rooms"
        Set-AppearanceShortcutMode Light
        if ((Get-AppearanceShortcut).Current.HelpText -notlike "*$failure*") {
            throw 'A save failure must be reported at the shortcut while Settings is hidden.'
        }
        Save-SidebarAppearance 'appearance-shortcut-save-failure'
        if ((Get-AppearanceShortcut).Current.Name -ne 'Appearance mode: Light' -or
            -not (Test-Path -LiteralPath $appearancePath -PathType Container)) {
            throw 'An unsaved mode must still apply without being written.'
        }
        Select-SidebarPage Settings "Window backdrop"
        if ((Find-SidebarElement AutomationId AppearanceSaveStatus).Current.Name -notlike "*$failure*") {
            throw 'Settings must keep its existing appearance save-error feedback.'
        }
        Remove-Item -LiteralPath $appearancePath -Force
        Select-SidebarPage "People & rooms" "Search people and rooms"
        Set-AppearanceShortcutMode Dark
        if ((Get-AppearanceShortcut).Current.HelpText -like "*$failure*" -or
            (Get-Content -LiteralPath $appearancePath -Raw | ConvertFrom-Json).theme -ne 'ColorfulDark') {
            throw 'A later successful save must clear the shortcut save error.'
        }
        Write-Host 'Appearance shortcut synchronization, all theme pairs, backdrop, restart persistence and save failure passed.'
    }
    finally {
        Stop-SidebarApp
        $env:FINGVIBE_UI_REVIEW_APPEARANCE = $savedAppearance
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
    }
}