function Get-ToolsLandingElement {
    param([Parameter(Mandatory)][string] $Id, [switch] $Optional)
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    Find-UiRegressionElement -Container { $script:root } -Condition $condition -Description "Tools '$Id'" -Optional:$Optional
}

function Get-ToolsLandingRowTargets([string[]] $Ids) {
    if (-not $script:root) { return $null }
    $textCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)
    foreach ($id in $Ids) {
        # Positioning must discover real offscreen peers before it can reveal them.
        $cardCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        $card = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cardCondition)
        if (-not $card) { return $null }
        $card
        foreach ($text in $card.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition)) {
            if ($text.Current.Name) { $text }
        }
    }
}

function Assert-ToolsLandingLayout {
    param(
        [Parameter(Mandatory)][int] $Width,
        [int] $Height = 720,
        [Parameter(Mandatory)][string] $Variant
    )
    $ids = @("SqlEditorCard", "FingImportCard", "SpeedTestCard", "RoomMapCard", "NetworkHealthCard", "DatabaseBackupsCard")
    # An active landing must not depend on sidebar peers being realized during resize.
    if (-not (Get-ToolsLandingElement "ToolsLanding" -Optional)) { Select-Page "Tools" }
    $bounds = Get-UiReviewWindowBounds -WindowHandle $process.MainWindowHandle
    if (-not [UiReviewNativeWindow]::SetWindowPos(
        $process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, $Width, $Height, 0x0044)) {
        throw "Could not resize the Tools window to ${Width}x$Height."
    }
    $landing = Wait-UiRegressionState -Description "$Variant Tools ${Width}x$Height layout" -Condition {
        $current = Get-UiReviewWindowBounds -WindowHandle $process.MainWindowHandle
        if ([Math]::Abs($current.Width - $Width) -gt 2 -or [Math]::Abs($current.Height - $Height) -gt 2) {
            return $null
        }
        $viewport = Get-ToolsLandingElement "ToolsLanding" -Optional
        if (Test-UiRegressionElementWithin $viewport $script:root $script:root) { return $viewport }
    }
    $scroll = $landing.GetCurrentPattern(
        [System.Windows.Automation.ScrollPattern]::Pattern)
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    $firstRow = $null
    $previousRowPlacement = $null
    for ($index = 0; $index -lt $ids.Count; $index += 2) {
        $rowIds = @($ids[$index])
        if ($index + 1 -lt $ids.Count) { $rowIds += $ids[$index + 1] }
        $null = Show-UiRegressionScrollTargets -Description "$Variant Tools row $($index / 2) [$($rowIds -join ', ')]" `
            -GetViewport { Get-ToolsLandingElement "ToolsLanding" } -GetWindow { $script:root } `
            -GetTargets { Get-ToolsLandingRowTargets $rowIds }
        $rectangles = @($rowIds | ForEach-Object { (Get-ToolsLandingElement $_).Current.BoundingRectangle })
        $scrollPercent = $scroll.Current.VerticalScrollPercent
        if ($previousRowPlacement -and (
            $scrollPercent -lt $previousRowPlacement.Scroll - 0.01 -or (
                [Math]::Abs($scrollPercent - $previousRowPlacement.Scroll) -le 0.01 -and
                $rectangles[0].Top -le $previousRowPlacement.Bottom))) {
            throw "$Variant Tools pairs must advance down consecutive rows at width $Width."
        }
        $previousRowPlacement = @{ Scroll = $scrollPercent; Bottom = $rectangles[0].Bottom }
        if ($index -eq 0) { $firstRow = $rectangles }
        for ($column = 0; $column -lt $rectangles.Count; $column++) {
            $rectangle = $rectangles[$column]
            if ([Math]::Abs($rectangle.Left - $firstRow[$column].Left) -gt 2 -or
                [Math]::Abs($rectangle.Width - $firstRow[0].Width) -gt 2) {
                throw "$Variant Tools card '$($rowIds[$column])' must keep its equal-width column at width $Width."
            }
            $card = Get-ToolsLandingElement $rowIds[$column]
            $textCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text)
            foreach ($text in $card.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition)) {
                if (-not $text.Current.Name) { continue }
                $textBounds = $text.Current.BoundingRectangle
                if ($text.Current.IsOffscreen -or $textBounds.IsEmpty -or
                    $textBounds.Left -lt $rectangle.Left - 2 -or $textBounds.Right -gt $rectangle.Right + 2 -or
                    $textBounds.Top -lt $rectangle.Top - 2 -or $textBounds.Bottom -gt $rectangle.Bottom + 2) {
                    throw "$Variant Tools text '$($text.Current.Name)' must be reachable inside its card at width $Width."
                }
            }
        }
        if ($rectangles.Count -eq 2 -and (
            [Math]::Abs($rectangles[0].Top - $rectangles[1].Top) -gt 2 -or
            [Math]::Abs($rectangles[0].Height - $rectangles[1].Height) -gt 2 -or
            $rectangles[1].Left -le $rectangles[0].Right)) {
            throw "$Variant Tools cards must form aligned, separated pairs at width $Width."
        }
        if ($ScreenshotDirectory -and $index -in @(0, 4)) {
            $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
            $edge = if ($index -eq 0) { "top" } else { "bottom" }
            Save-UiRegressionScreenshot -WindowHandle $process.MainWindowHandle -MinimumWidth 480 `
                -Path (Join-Path $ScreenshotDirectory "tools-$Variant-$Width-$edge.png")
        }
    }
    $null = Show-UiRegressionScrollTargets -Description "$Variant Tools keyboard entry [$($ids[0])]" `
        -GetViewport { Get-ToolsLandingElement "ToolsLanding" } -GetWindow { $script:root } `
        -GetTargets { Get-ToolsLandingRowTargets @($ids[0]) }
    (Get-ToolsLandingElement $ids[0]).SetFocus()
    for ($index = 0; $index -lt $ids.Count; $index++) {
        $expectedId = $ids[$index]
        $null = Wait-UiRegressionState -Description "Tools keyboard focus '$expectedId'" -Condition {
            (Get-ToolsLandingElement $expectedId).Current.HasKeyboardFocus
        }
        if ($index + 1 -lt $ids.Count) { [BuildIdentityReviewKeyboard]::Tap(0x09) }
    }
    Write-Host "Tools landing passed: $Variant ${Width}x$Height, equal columns, row order, text reachability and keyboard order."
}

function Test-ToolsLanding {
    $originalBounds = Get-UiReviewWindowBounds -WindowHandle $process.MainWindowHandle
    Select-Page "Settings"
    Expand-UiReviewSettingsSection -Root $root -Section AppearanceSection
    $original = @{}
    foreach ($id in @("ModePicker", "ThemePicker")) {
        $selection = (Get-ToolsLandingElement $id).GetCurrentPattern(
            [System.Windows.Automation.SelectionPattern]::Pattern).Current.GetSelection()
        if ($selection.Count -ne 1) { throw "Cannot preserve original appearance choice '$id'." }
        $original[$id] = $selection[0].Current.Name
    }
    $primaryFailed = $true
    $phase = Start-UiRegressionPhase -Name "Tools/landing"
    try {
        foreach ($theme in @("Standard Light", "Standard Dark")) {
            if (-not [UiReviewNativeWindow]::SetWindowPos(
                $process.MainWindowHandle, [IntPtr]::Zero, $originalBounds.X, $originalBounds.Y, 1280, 720, 0x0044)) {
                throw "Could not restore a wide window for Tools theme selection."
            }
            Select-Page "Settings"
            Set-UiReviewTheme -Root $root -Theme $theme
            foreach ($width in @(1280, 640, 480)) {
                Assert-ToolsLandingLayout -Width $width -Variant $theme.Replace(" ", "-").ToLowerInvariant()
            }
        }
        $primaryFailed = $false
    }
    finally {
        $succeeded = $false
        try {
            Invoke-UiRegressionCleanup -PrimaryFailed $primaryFailed -Steps @(
                {
                    if (-not [UiReviewNativeWindow]::SetWindowPos(
                        $process.MainWindowHandle, [IntPtr]::Zero, $originalBounds.X, $originalBounds.Y,
                        $originalBounds.Width, $originalBounds.Height, 0x0044)) {
                        throw "Could not restore the original window size after Tools layout checks."
                    }
                    Select-Page "Settings"
                    foreach ($id in @("ModePicker", "ThemePicker")) {
                        Set-UiReviewAppearanceChoice -Root $root -Picker $id -Choice $original[$id]
                    }
                },
                { Select-Page "Overview" }
            )
            $succeeded = -not $primaryFailed
        }
        finally {
            if ($ScreenshotDirectory) {
                Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $succeeded
            }
        }
    }
}
