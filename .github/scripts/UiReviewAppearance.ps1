$UiReviewAppearanceThemes = @(
    "Standard Light", "Warm Light", "Colorful Light",
    "Standard Dark", "True Black (OLED)", "Colorful Dark"
)

function Expand-UiReviewSettingsSection {
    param([Parameter(Mandatory)] $Root,
        [Parameter(Mandatory)][ValidateSet("AppearanceSection", "DevicesSection", "ScheduledScansSection")][string] $Section)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Section)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $element = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $element) { throw "Settings section '$Section' is unavailable." }
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($pattern.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Expanded) {
        $pattern.Expand()
    }
}

function Set-UiReviewAppearanceChoice {
    param(
        [Parameter(Mandatory)] $Root,
        [Parameter(Mandatory)][string] $Picker,
        [Parameter(Mandatory)][string] $Choice
    )
    $section = if ($Picker -eq "ScanIntervalPicker") { "ScheduledScansSection" } else { "AppearanceSection" }
    Expand-UiReviewSettingsSection -Root $Root -Section $section
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Picker)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $combo = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($combo -and -not $combo.Current.IsOffscreen) { break }
        if ($combo -and $combo.Current.IsKeyboardFocusable) { $combo.SetFocus() }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $combo -or $combo.Current.IsOffscreen) { throw "Appearance picker '$Picker' is not visible." }
    $expand = $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    try {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, $Choice),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $item = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($item -and -not $item.Current.IsOffscreen) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $item -or $item.Current.IsOffscreen) { throw "Appearance choice '$Choice' is not visible in '$Picker'." }
        $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
    finally { $expand.Collapse() }
    $selected = $combo.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
    if ($selected.Count -ne 1 -or $selected[0].Current.Name -ne $Choice) {
        throw "Appearance picker '$Picker' did not select '$Choice'."
    }
    Start-Sleep -Milliseconds 150
}

function Set-UiReviewTheme {
    param(
        [Parameter(Mandatory)] $Root,
        [Parameter(Mandatory)]
        [ValidateSet("Standard Light", "Warm Light", "Colorful Light", "Standard Dark", "True Black (OLED)", "Colorful Dark")]
        [string] $Theme
    )
    $mode, $style = switch ($Theme) {
        "Standard Light" { "Light"; "Standard" }
        "Warm Light" { "Light"; "Warm" }
        "Colorful Light" { "Light"; "Colorful" }
        "Standard Dark" { "Dark"; "Standard" }
        "True Black (OLED)" { "Dark"; "True Black (OLED)" }
        "Colorful Dark" { "Dark"; "Colorful" }
    }
    Set-UiReviewAppearanceChoice -Root $Root -Picker ModePicker -Choice $mode
    Set-UiReviewAppearanceChoice -Root $Root -Picker ThemePicker -Choice $style
}
