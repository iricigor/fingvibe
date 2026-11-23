function Test-TitleBarCaptionHover([string] $Name) {
    foreach ($id in @('TitleBarMinimizeButton', 'TitleBarMaximizeButton', 'TitleBarCloseButton')) {
        $nameBounds = (Find-SidebarElement AutomationId TitleBarAppName).Current.BoundingRectangle
        [SidebarReviewKeyboard]::MoveTo([int]($nameBounds.Left + $nameBounds.Width / 2), [int]($nameBounds.Top + $nameBounds.Height / 2))
        Save-SidebarAppearance "$Name-$id-normal"
        $bounds = (Find-SidebarElement AutomationId $id).Current.BoundingRectangle
        [SidebarReviewKeyboard]::MoveTo([int]($bounds.Left + $bounds.Width / 2), [int]($bounds.Top + $bounds.Height / 2))
        Save-SidebarAppearance "$Name-$id-hover"
        $window = Get-UiReviewWindowBounds $windowHandle
        $normal = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "$Name-$id-normal.png"))
        $hover = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "$Name-$id-hover.png"))
        try {
            # The arc one DIP inward is antialiased; the outer corner remains transparent.
            $cornerX = [int][Math]::Floor($bounds.Left - $window.Left)
            $cornerY = [int][Math]::Floor($bounds.Top - $window.Top)
            $fillX = [int]($bounds.Left - $window.Left + $bounds.Width / 2)
            $fillY = [int]($bounds.Bottom - $window.Top - 2 * $scale)
            if ($hover.GetPixel($cornerX, $cornerY).ToArgb() -ne $normal.GetPixel($cornerX, $cornerY).ToArgb() -or
                $hover.GetPixel($fillX, $fillY).ToArgb() -eq $normal.GetPixel($fillX, $fillY).ToArgb()) {
                throw "$id hover must leave a rounded transparent corner while shading the full header height."
            }
        }
        finally { $normal.Dispose(); $hover.Dispose() }
    }
    $nameBounds = (Find-SidebarElement AutomationId TitleBarAppName).Current.BoundingRectangle
    [SidebarReviewKeyboard]::MoveTo([int]($nameBounds.Left + $nameBounds.Width / 2), [int]($nameBounds.Top + $nameBounds.Height / 2))
}

function Test-TitleBarLayout {
    $name = Find-SidebarElement AutomationId TitleBarAppName
    $build = Find-SidebarElement AutomationId TitleBarBuildText
    $shortcut = Find-SidebarElement AutomationId TitleBarAppearanceButton
    $nameBounds = $name.Current.BoundingRectangle
    $buildBounds = $build.Current.BoundingRectangle
    $buttonBounds = $shortcut.Current.BoundingRectangle
    $windowBounds = $root.Current.BoundingRectangle
    if ($name.Current.Name -ne 'FingVibe' -or [string]::IsNullOrWhiteSpace($build.Current.Name) -or
        -not $windowBounds.Contains($nameBounds) -or -not $windowBounds.Contains($buildBounds) -or
        -not $windowBounds.Contains($buttonBounds) -or $nameBounds.Right -gt $buildBounds.Left -or
        $buildBounds.Right -gt $buttonBounds.Left -or
        $buttonBounds.Bottom -gt (Find-SidebarElement AutomationId MainNavigation).Current.BoundingRectangle.Top -or
        -not $shortcut.Current.IsKeyboardFocusable -or $shortcut.Current.Name -notlike 'Appearance mode: *') {
        throw "Title-bar identity and its accessible shortcut must fit above navigation without overlapping."
    }
    $minimize = (Find-SidebarElement AutomationId TitleBarMinimizeButton).Current.BoundingRectangle
    $maximize = (Find-SidebarElement AutomationId TitleBarMaximizeButton).Current.BoundingRectangle
    $close = (Find-SidebarElement AutomationId TitleBarCloseButton).Current.BoundingRectangle
    $navigationTop = (Find-SidebarElement AutomationId MainNavigation).Current.BoundingRectangle.Top
    $previous = $buttonBounds
    foreach ($id in @('TitleBarMinimizeButton', 'TitleBarMaximizeButton', 'TitleBarCloseButton')) {
        $caption = Find-SidebarElement AutomationId $id
        $captionBounds = $caption.Current.BoundingRectangle
        if (-not $caption.Current.IsKeyboardFocusable -or -not $windowBounds.Contains($captionBounds) -or
            $captionBounds.Left -lt $previous.Right -or [Math]::Abs($captionBounds.Bottom - $navigationTop) -gt $scale) {
            throw 'Custom caption controls must be keyboard-accessible, contained, nonoverlapping and fill the header height.'
        }
        $previous = $captionBounds
    }
    $y = [int]($buttonBounds.Top + $buttonBounds.Height / 2)
    foreach ($target in @(
        @{ X = [int]($nameBounds.Left + $nameBounds.Width / 2); Expected = 2; Name = 'drag area' },
        @{ X = [int]($buttonBounds.Left + $buttonBounds.Width / 2); Expected = 1; Name = 'appearance button' },
        @{ X = [int]($close.Left + $close.Width / 2); Expected = 1; Name = 'custom Close' },
        @{ X = [int]($maximize.Left + $maximize.Width / 2); Expected = 9; Name = 'Maximize/Restore Snap region' },
        @{ X = [int]($minimize.Left + $minimize.Width / 2); Expected = 1; Name = 'custom Minimize' }
    )) {
        $hit = [SidebarReviewKeyboard]::HitTest($windowHandle, $target.X, $y)
        if ($hit -ne $target.Expected) {
            throw "Title-bar $($target.Name) must retain its native hit target; expected $($target.Expected), got $hit."
        }
    }
    if ([SidebarReviewKeyboard]::HitTest($windowHandle, [int]($maximize.Left + $maximize.Width / 2),
            [int]($navigationTop - 2 * $scale)) -ne 9) {
        throw "The custom maximize hit area must fill the header height without leaving a gap below its hover surface."
    }
}

function Test-TitleBarInteractions {
    Test-TitleBarLayout
    Focus-SidebarWindow
    $shortcut = Find-SidebarElement AutomationId TitleBarAppearanceButton
    $originalMode = if ($shortcut.Current.Name -eq 'Appearance mode: Dark') { 'Dark' } else { 'Light' }
    $otherMode = if ($originalMode -eq 'Dark') { 'Light' } else { 'Dark' }
    $bounds = $shortcut.Current.BoundingRectangle
    [SidebarReviewKeyboard]::PressAt([int]($bounds.Left + $bounds.Width / 2), [int]($bounds.Top + $bounds.Height / 2))
    [SidebarReviewKeyboard]::Release()
    $null = Wait-UiRegressionState -Description 'one title-bar click switches appearance immediately' -Condition {
        (Find-SidebarElement AutomationId TitleBarAppearanceButton).Current.Name -eq "Appearance mode: $otherMode"
    }
    if (Find-SidebarElement AutomationId AppearanceShortcutLight -Optional) {
        throw "The title-bar appearance button must switch modes without opening a picker popup."
    }
    (Find-SidebarElement AutomationId TitleBarAppearanceButton).SetFocus()
    [SidebarReviewKeyboard]::Tap(0x0D)
    $null = Wait-UiRegressionState -Description 'keyboard title-bar choice restores shared mode' -Condition {
        (Find-SidebarElement AutomationId TitleBarAppearanceButton).Current.Name -eq "Appearance mode: $originalMode" -and
            (Find-SidebarElement AutomationId TitleBarAppearanceButton).Current.HasKeyboardFocus
    }

    $before = $root.Current.BoundingRectangle
    $name = (Find-SidebarElement AutomationId TitleBarAppName).Current.BoundingRectangle
    $x = [int]($name.Left + $name.Width / 2); $y = [int]($name.Top + $name.Height / 2)
    [SidebarReviewKeyboard]::PressAt($x, $y)
    try {
        [SidebarReviewKeyboard]::MoveTo($x + [int](64 * $scale), $y + [int](40 * $scale))
        Start-Sleep -Milliseconds 200
    }
    finally { [SidebarReviewKeyboard]::Release() }
    $null = Wait-UiRegressionState -Description 'noninteractive title bar moves the window' -Condition {
        [Math]::Abs($root.Current.BoundingRectangle.Left - $before.Left - 64 * $scale) -lt 4 * $scale -and
            [Math]::Abs($root.Current.BoundingRectangle.Top - $before.Top - 40 * $scale) -lt 4 * $scale
    }
    $pattern = $root.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
    foreach ($state in @(
        [System.Windows.Automation.WindowVisualState]::Maximized,
        [System.Windows.Automation.WindowVisualState]::Normal
    )) {
        $name = (Find-SidebarElement AutomationId TitleBarAppName).Current.BoundingRectangle
        $x = [int]($name.Left + $name.Width / 2); $y = [int]($name.Top + $name.Height / 2)
        [SidebarReviewKeyboard]::PressAt($x, $y)
        [SidebarReviewKeyboard]::Release()
        [SidebarReviewKeyboard]::PressAt($x, $y)
        [SidebarReviewKeyboard]::Release()
        $null = Wait-UiRegressionState -Description "title-bar double-click switches to $state" -Condition {
            $pattern.Current.WindowVisualState -eq $state
        }
        Test-TitleBarLayout
    }
    $maximize = (Find-SidebarElement AutomationId TitleBarMaximizeButton).Current.BoundingRectangle
    $x = [int]($maximize.Left + $maximize.Width / 2); $y = [int]($maximize.Top + $maximize.Height / 2)
    [SidebarReviewKeyboard]::PressAt($x, $y)
    [SidebarReviewKeyboard]::Release()
    $null = Wait-UiRegressionState -Description 'pointer custom maximize action' -Condition {
        $pattern.Current.WindowVisualState -eq [System.Windows.Automation.WindowVisualState]::Maximized -and
            (Find-SidebarElement AutomationId TitleBarMaximizeButton).Current.Name -eq 'Restore'
    }
    Test-TitleBarLayout
    (Find-SidebarElement AutomationId TitleBarMaximizeButton).SetFocus()
    [SidebarReviewKeyboard]::Tap(0x20)
    $null = Wait-UiRegressionState -Description 'keyboard custom restore action' -Condition {
        $pattern.Current.WindowVisualState -eq [System.Windows.Automation.WindowVisualState]::Normal -and
            (Find-SidebarElement AutomationId TitleBarMaximizeButton).Current.Name -eq 'Maximize'
    }
    $maximize = (Find-SidebarElement AutomationId TitleBarMaximizeButton).Current.BoundingRectangle
    $x = [int]($maximize.Left + $maximize.Width / 2); $y = [int]($maximize.Top + $maximize.Height / 2)
    [SidebarReviewKeyboard]::PressAt($x, $y)
    try {
        [SidebarReviewKeyboard]::MoveTo($x - [int](60 * $scale), $y + [int](60 * $scale))
        Start-Sleep -Milliseconds 200
    }
    finally { [SidebarReviewKeyboard]::Release() }
    if ($pattern.Current.WindowVisualState -ne [System.Windows.Automation.WindowVisualState]::Normal) {
        throw 'Releasing a custom maximize press outside the button must cancel, not toggle the window state.'
    }
    (Find-SidebarElement AutomationId TitleBarMinimizeButton).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState -Description 'native minimize' -Condition {
        $pattern.Current.WindowVisualState -eq [System.Windows.Automation.WindowVisualState]::Minimized
    }
    $pattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
    Focus-SidebarWindow
    Set-SidebarWindowWidth $expandedWidth
    Test-TitleBarLayout
}

function Test-SidebarContentInset([string] $Page) {
    $grip = (Find-SidebarElement AutomationId NavigationResizeGrip).Current.BoundingRectangle
    $edge = $grip.Left + $grip.Width / 2
    $header = (Find-SidebarElement AutomationId DetectedNetworkLabel).Current.BoundingRectangle
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Page),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text))
    $heading = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) |
        Where-Object { -not $_.Current.IsOffscreen -and $_.Current.BoundingRectangle.Left -gt $edge })
    if ($heading.Count -ne 1) { throw "Expected one visible content heading for '$Page'; got $($heading.Count)." }
    # Every main page's shared header (#657) places a 48-DIP icon and 12-DIP gap before the title; the row still starts at 12.
    $headingInset = 12 + 48 + 12
    foreach ($check in @(@{ Bounds = $header; Inset = 12 }, @{ Bounds = $heading[0].Current.BoundingRectangle; Inset = $headingInset })) {
        $bounds = $check.Bounds
        $inset = ($bounds.Left - $edge) / $scale
        if ([Math]::Abs($inset - $check.Inset) -gt 2) {
            throw "'$Page' heading and shared header must align 12 DIPs from navigation (heading after its icon at $($check.Inset)); got $inset."
        }
        if (-not $root.Current.BoundingRectangle.Contains($bounds)) {
            throw "'$Page' heading or shared header is clipped."
        }
    }
}

function Test-SidebarDividerAppearance([string] $Name = "sidebar-divider", [int] $MaximumContrast = 16) {
    Focus-SidebarWindow
    (Find-SidebarElement AutomationId NetworkNavItem).SetFocus()
    $grip = (Find-SidebarElement AutomationId NavigationResizeGrip).Current.BoundingRectangle
    $x = [int]($grip.Left + $grip.Width / 2)
    $y = [int]($grip.Top + $grip.Height / 2)
    [SidebarReviewKeyboard]::MoveTo($x + [int](100 * $scale), $y)
    Save-SidebarAppearance "$Name-hidden"
    [SidebarReviewKeyboard]::MoveTo($x + [int](5 * $scale), $y)
    Save-SidebarAppearance "$Name-hover"
    [SidebarReviewKeyboard]::MoveTo($x + [int](100 * $scale), $y)
    Save-SidebarAppearance "$Name-hidden-again"
    $window = Get-UiReviewWindowBounds $windowHandle
    $hidden = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "$Name-hidden.png"))
    $hover = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "$Name-hover.png"))
    $again = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "$Name-hidden-again.png"))
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
            if ($contrast -gt $MaximumContrast) { throw "Divider contrast $contrast exceeds $MaximumContrast in '$Name'." }
        }
        if ($changed -eq 0) { throw "The divider must appear when the pointer is within five DIPs of its edge." }
    }
    finally {
        $hidden.Dispose()
        $hover.Dispose()
        $again.Dispose()
    }
}

# BitmapIcon point-samples its monochrome mask, so oversized art leaves only scattered stroke pixels.
# 24-DIP family icons ink about 145-180 pixels at 100% scale and span about 21 DIPs (87.5%); 16-DIP icons inked 45-55.
function Assert-SidebarFamilyIcons([string] $Name) {
    $window = Get-UiReviewWindowBounds $windowHandle
    $bitmap = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "$Name.png"))
    try {
        foreach ($id in @("OverviewNavItem", "NetworkNavItem", "DevicesNavItem", "PeopleRoomsNavItem", "ToolsNavItem")) {
            $item = (Find-SidebarElement AutomationId $id).Current.BoundingRectangle
            # Skip the selection pill at the item's left edge, any focus border around it and the label.
            $left = [int]($item.Left - $window.Left + 8 * $scale)
            $right = [int]([Math]::Min($item.Left + 44 * $scale, $item.Right) - $window.Left)
            $middle = $item.Top - $window.Top + $item.Height / 2
            $top = [int]($middle - 14 * $scale)
            $bottom = [int]($middle + 14 * $scale)
            $counts = @{}
            for ($y = $top; $y -lt $bottom; $y++) {
                for ($x = $left; $x -lt $right; $x++) { $counts[$bitmap.GetPixel($x, $y).ToArgb()]++ }
            }
            $background = [System.Drawing.Color]::FromArgb(
                ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key)
            $ink = 0
            $inkLeft = $right; $inkTop = $bottom; $inkRight = $left - 1; $inkBottom = $top - 1
            for ($y = $top; $y -lt $bottom; $y++) {
                for ($x = $left; $x -lt $right; $x++) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    if ([Math]::Abs([int]$pixel.R - $background.R) + [Math]::Abs([int]$pixel.G - $background.G) +
                        [Math]::Abs([int]$pixel.B - $background.B) -gt 96) {
                        $ink++
                        $inkLeft = [Math]::Min($inkLeft, $x); $inkRight = [Math]::Max($inkRight, $x)
                        $inkTop = [Math]::Min($inkTop, $y); $inkBottom = [Math]::Max($inkBottom, $y)
                    }
                }
            }
            if ($ink -lt 90 * $scale * $scale) {
                throw "$id family icon is not recognizable in '$Name': $ink inked pixels (expected at least $([int](90 * $scale * $scale)))."
            }
            $span = [Math]::Max($inkRight - $inkLeft + 1, $inkBottom - $inkTop + 1) / $scale
            if ($span -lt 18 -or $span -gt 24) {
                throw "$id family icon must render at 24 DIPs in '$Name': its artwork spans $([Math]::Round($span, 1)) DIPs (expected about 21)."
            }
        }
    }
    finally { $bitmap.Dispose() }
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
        @("Devices", "Search devices"), @("People & rooms", "Search people and rooms"),
        @("Tools", "Speed test"), @("Settings", "Window backdrop")
    )) {
        Select-SidebarPage $page[0] $page[1]
        Assert-SidebarPaneWidth 48
        Test-SidebarContentInset $page[0]
    }
    Save-SidebarAppearance "sidebar-resize-icons"
    Assert-SidebarFamilyIcons "sidebar-resize-icons"
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
