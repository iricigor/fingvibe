function Test-SidebarDividerAppearance {
    Focus-SidebarWindow
    (Find-SidebarElement AutomationId NetworkNavItem).SetFocus()
    $grip = (Find-SidebarElement AutomationId NavigationResizeGrip).Current.BoundingRectangle
    $x = [int]($grip.Left + $grip.Width / 2)
    $y = [int]($grip.Top + $grip.Height / 2)
    [SidebarReviewKeyboard]::MoveTo($x + [int](100 * $scale), $y)
    Save-SidebarAppearance "sidebar-divider-hidden"
    [SidebarReviewKeyboard]::MoveTo($x + [int](5 * $scale), $y)
    Save-SidebarAppearance "sidebar-divider-hover"
    [SidebarReviewKeyboard]::MoveTo($x + [int](100 * $scale), $y)
    Save-SidebarAppearance "sidebar-divider-hidden-again"
    $window = Get-UiReviewWindowBounds $windowHandle
    $hidden = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "sidebar-divider-hidden.png"))
    $hover = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "sidebar-divider-hover.png"))
    $again = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "sidebar-divider-hidden-again.png"))
    try {
        $changed = 0
        $sampleY = [int]($grip.Top - $window.Top + 16 * $scale)
        foreach ($sampleX in ([int]($x - $window.Left - 2 * $scale))..([int]($x - $window.Left + 2 * $scale))) {
            $background = $hidden.GetPixel($sampleX, $sampleY)
            $line = $hover.GetPixel($sampleX, $sampleY)
            if ($background.ToArgb() -ne $again.GetPixel($sampleX, $sampleY).ToArgb()) {
                throw "The divider must disappear when the pointer leaves its hit area."
            }
            $contrast = [Math]::Max([Math]::Abs([int]$line.R - $background.R),
                [Math]::Max([Math]::Abs([int]$line.G - $background.G), [Math]::Abs([int]$line.B - $background.B)))
            if ($contrast -ge 3) { $changed++ }
            if ($contrast -gt 40) { throw "The normal-theme divider must use a subtle color, not a strong border." }
        }
        if ($changed -eq 0) { throw "The divider must appear when the pointer is within five DIPs of its edge." }
    }
    finally {
        $hidden.Dispose()
        $hover.Dispose()
        $again.Dispose()
    }
}

function Test-SidebarIconDragGuide {
    Focus-SidebarWindow
    $grip = (Find-SidebarElement AutomationId NavigationResizeGrip).Current.BoundingRectangle
    $navigation = (Find-SidebarElement AutomationId MainNavigation).Current.BoundingRectangle
    $y = [int]($grip.Top + $grip.Height / 2)
    [SidebarReviewKeyboard]::PressAt([int]($grip.Left + $grip.Width / 2), $y)
    try {
        foreach ($width in @(96, 140, 120)) {
            [SidebarReviewKeyboard]::MoveTo([int]($navigation.Left + $width * $scale), $y)
            Start-Sleep -Milliseconds 300
            Assert-SidebarPaneWidth $width
            if ((Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle.Width / $scale -ge 80) {
                throw "Following the pointer below 160 DIPs must not expand the icon rail."
            }
        }
        Save-SidebarAppearance "sidebar-resize-icon-guide"
    }
    finally {
        [SidebarReviewKeyboard]::Release()
    }
    Start-Sleep -Milliseconds 300
    Assert-SidebarPaneWidth 48
}

function Test-SidebarResizing {
    Select-SidebarPage Network "Public IP address"
    Assert-SidebarPaneWidth 216
    Test-SidebarDividerAppearance
    Resize-SidebarPane @(320)
    Assert-SidebarPaneWidth 320
    Resize-SidebarPane @(500)
    Assert-SidebarPaneWidth 320
    Resize-SidebarPane @(160)
    Assert-SidebarPaneWidth 160
    $brand = Find-SidebarElement AutomationId NavigationBrandName
    if ($brand.Current.Name -ne "FingVibe" -or $brand.Current.BoundingRectangle.Height / $scale -gt 30) {
        throw "FingVibe must stay on one line at the minimum expanded width."
    }
    $selection = (Find-SidebarElement AutomationId NetworkNavItem).GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern)
    if (-not $selection.Current.IsSelected) { throw "Resizing must retain the selected navigation destination." }
    Resize-SidebarPane @(159)
    Assert-SidebarPaneWidth 48
    Resize-SidebarPane @(1)
    Assert-SidebarPaneWidth 48
    Test-SidebarIconDragGuide
    foreach ($page in @(
        @("Overview", "Online devices"), @("Network", "Public IP address"),
        @("Devices", "Search devices"), @("People", "Search people"),
        @("Rooms", "Search rooms"), @("Tools", "Speed test"), @("Settings", "Window backdrop")
    )) {
        Select-SidebarPage $page[0] $page[1]
        Assert-SidebarPaneWidth 48
    }
    Save-SidebarAppearance "sidebar-resize-icons"
    Switch-SidebarPane
    Assert-SidebarPaneWidth 160
    Resize-SidebarPane @(280)
    Switch-SidebarPane
    Assert-SidebarPaneWidth 48
    Switch-SidebarPane
    Assert-SidebarPaneWidth 280
    # Cross the snap boundary in both directions without releasing pointer capture.
    Resize-SidebarPane @(100, 240)
    Assert-SidebarPaneWidth 240
    Resize-SidebarPane @(159)
    Assert-SidebarPaneWidth 48
    Resize-SidebarPane @(160)
    Assert-SidebarPaneWidth 160
    $grip = Find-SidebarElement AutomationId NavigationResizeGrip
    $grip.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x25)
    Start-Sleep -Milliseconds 250
    Assert-SidebarPaneWidth 48
    [SidebarReviewKeyboard]::Tap(0x27)
    Start-Sleep -Milliseconds 250
    Assert-SidebarPaneWidth 160
    Save-SidebarAppearance "sidebar-resize-threshold"
    Resize-SidebarPane @(216)
    Assert-SidebarPaneWidth 216
    Save-SidebarAppearance "sidebar-resize-expanded"
    Write-Host "Navigation drag bounds, exact snap threshold, continuous drag, all compact destinations, toggle restoration and keyboard resizing passed."
}

function Assert-SidebarNavigationPreference([double] $Width, [bool] $IsCollapsed) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $saved = $null
        try { $saved = Get-Content -LiteralPath $navigationPreferencePath -Raw | ConvertFrom-Json }
        catch [System.IO.IOException], [System.Management.Automation.ItemNotFoundException] { }
        if ($saved -and [Math]::Abs($saved.expandedWidth - $Width) -le 1 -and $saved.isCollapsed -eq $IsCollapsed) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected saved navigation of $Width DIPs with collapsed=$IsCollapsed; got $($saved | ConvertTo-Json -Compress)."
}

function Test-SidebarPersistence {
    Stop-SidebarApp
    Set-Content -LiteralPath $navigationPreferencePath -Value '{"expandedWidth":280,"isCollapsed":false}' -Encoding ASCII
    $env:FINGVIBE_UI_REVIEW_NAVIGATION = $navigationPreferencePath
    Start-SidebarApp
    Set-SidebarWindowWidth $expandedWidth
    Assert-SidebarPaneWidth 280
    Switch-SidebarPane
    Assert-SidebarPaneWidth 48
    Assert-SidebarNavigationPreference 280 $true

    Stop-SidebarApp
    Start-SidebarApp
    Set-SidebarWindowWidth $expandedWidth
    Assert-SidebarPaneWidth 48
    Switch-SidebarPane
    Assert-SidebarPaneWidth 280
    Assert-SidebarNavigationPreference 280 $false
    Resize-SidebarPane @(240)
    Assert-SidebarPaneWidth 240
    Assert-SidebarNavigationPreference 240 $false
    Set-SidebarWindowWidth 800
    if ((Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle.Width / $scale -ge 80) {
        throw "A small window must collapse navigation automatically."
    }
    Assert-SidebarNavigationPreference 240 $false

    Stop-SidebarApp
    Start-SidebarApp
    Set-SidebarWindowWidth $expandedWidth
    Assert-SidebarPaneWidth 240
    Write-Host "Navigation width and icon-only choice were restored after restart; automatic small-window collapse was not saved."
}
